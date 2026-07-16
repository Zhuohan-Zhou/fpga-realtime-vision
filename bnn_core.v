// bnn_core.v -- ultra-tiny binarized CNN for MNIST digit classification.
//
// Standalone proof-of-concept requested by the user's advisor ("CNN should
// be achievable on this chip"): EP4CE10 only has 10,320 LE / 645 LAB, 46
// M9K (~424Kbit), and 15 hardware multipliers -- nowhere near what typical
// "CNN on Cyclone IV" reference designs assume (those almost always target
// much bigger Cyclone IV parts, e.g. EP4CE115 with 11x the LEs). The only
// way to fit real CNN inference in this budget is a Binarized Neural
// Network (BNN): every weight AND every activation (including the input
// image itself) is +-1, so the entire forward pass reduces to XNOR +
// popcount + integer compare -- no multiplier anywhere, which is exactly
// the same "avoid multipliers, use cheap bit tricks" philosophy already
// used throughout this project (Sobel's |Gx|+|Gy|, EAN-13's shift-based
// x3/x5/x7, the Kalman filter's shift-based gains).
//
// Architecture (matches the tiny 2-conv-layer shape the user asked for,
// inspired by the "smallNet" reference paper, but binarized and using
// 'valid' convolution throughout for unambiguous shapes -- our own design,
// not a literal port of that paper's numbers):
//
//   28x28 image (+-1 per pixel)
//     -> conv1: 1 filter, 2x2, valid conv, XNOR+popcount, threshold
//     -> 27x27 binary feature map (only top-left 26x26 used, see below)
//     -> maxpool 2x2 (OR of the 4 bits, since max over +-1 == OR of the
//        "is +1" bit) -> 13x13
//     -> conv2: 1 filter, 2x2, valid conv, XNOR+popcount, threshold
//     -> 12x12 binary feature map
//     -> maxpool 2x2 -> 6x6 = 36 bits, flattened
//     -> dense: 10 output neurons, each XNOR+popcount over the 36 bits
//     -> argmax over the 10 popcounts -> predicted digit
//
// Trained in Python (numpy, hand-rolled BinaryConnect-style STE training,
// see train_bnn.py) on the real MNIST dataset (50000 train / 10000 test,
// from the standard mnielsen/neural-networks-and-deep-learning mnist.pkl.gz
// -- not made up). ~380 total parameters. Test accuracy: 58.44% (float
// reference model) / 58.30% (this exact pure-integer XNOR+popcount
// hardware model, checked on 1000 test images -- see verify_and_export.py)
// -- modest compared to a full-precision network, but a real, honestly
// measured number for a network this deliberately tiny, and the point of
// this V1 is proving the whole binarized pipeline works in hardware, not
// chasing state-of-the-art accuracy. Well above the 10% chance baseline.
//
// Both layers' trained batchnorm folds out to a clean integer popcount
// threshold (verified in verify_and_export.py): conv1 fires on
// popcount4>=2, conv2 fires on popcount4>=3. The dense layer's trained
// biases were all under 0.16 in magnitude -- since adjacent popcount values
// differ by an even step of 2 in the equivalent real-valued score, a bias
// that small can never flip an argmax decision, so it's dropped entirely:
// the classifier is just "which of the 10 neurons has the highest raw
// popcount against the flattened 36-bit feature map".
//
// This module processes ONE image at a time from a start pulse, using a
// simple state machine with a position counter per stage. Input image
// source is a flattened 784-bit port (bit[y*28+x] = pixel(y,x),
// 1=stroke/+1, 0=background/-1).  It is exercised directly by
// tb_bnn_core.v and, in the integrated camera build, is fed by
// roi_binarize_28x28.v in camera_display_top.v.  Camera focus affects
// real-world recognition quality, but not this hardware interface.
//
// ---- LE-count rewrite (2026-07-16) ----
// The first version stored img/a1/p1/a2 as flat vector registers
// (`reg [783:0] img;` etc.) and indexed them with a runtime-computed BIT
// offset (`img[(cy+0)*28+(cx+0)]`). A real Analysis & Synthesis run on the
// EP4CE10 came back with Total logic elements = 5,776 (56% of the WHOLE
// chip's 10,320 LE budget) for this module ALONE, even though Total
// registers = 1,898 matched the raw storage-bit estimate almost exactly
// and Total memory bits = 0 / Embedded Multipliers = 0 confirmed no M9K
// or multiplier was used either way. The LE blowup was the runtime bit
// index itself: a flat vector with a variable bit-select isn't "an array
// of words" to Quartus at all, just one giant register with a big
// hand-built mux/decoder wrapped around it -- LE cost roughly proportional
// to the FULL vector width (784) times the number of dynamically-indexed
// reads/writes. This is the exact same root cause already diagnosed and
// fixed once before in this project for sobel_edge.v/motion_detector.v's
// LAB overflow (see CLAUDE.md's "LAB 超限问题" section) -- combinational
// or flat-vector "fake memory" builds out of LEs, real word-addressed
// arrays with synchronous read can map onto M9K instead.
//
// Fix: img/a1/p1/a2 are now real word-addressed arrays (`reg [W-1:0]
// mem [0:D-1]`, one image/feature-map ROW per word), read through a
// registered (synchronous) two-row fetch matching the 2x2 conv/pool
// window's actual access pattern -- exactly the same "line buffer,
// synchronous read" shape already used in sobel_edge.v/gaussian_blur3x3.v/
// nms_thresh.v. The only remaining dynamic bit-indexing left in the
// design is (a) indexing a COLUMN within a single already-fetched row
// (28 bits wide at most, vs. 784 before -- about a 28x smaller mux per
// access) and (b) building each output row in a narrow (<=26-bit)
// accumulator register before writing the whole word out in one shot.
// image_in itself is loaded into img_mem via a 784-bit shift register
// (`img_shift >> 28` each cycle, always reading the fixed low 28 bits) so
// even the one-time image load needs zero dynamic bit-selects at all.
// This rewrite was re-synthesized on the real EP4CE10: 2,860 LE (about
// 28% of the device), down from the original 5,776 LE implementation.
module bnn_core (
    input             clk,
    input             rst_n,
    input             start,          // 1-cycle pulse: begin classifying image_in
    input   [783:0]   image_in,       // bit[y*28+x] = pixel(y,x), 1=stroke(+1), 0=bg(-1)

    output reg        done,           // 1-cycle pulse when digit_out is valid
    output reg [3:0]  digit_out       // predicted digit 0-9
);

// ---- trained weights (bit i == flat weight index i; see
// verify_and_export.py for how these were derived and bit-order-checked) ----
// P1_cut=2  P2_cut=3
localparam [3:0] W1 = 4'b1101;
localparam [3:0] W2 = 4'b1110;
localparam [35:0] WD0 = 36'b111100010110110011110111110100011000;
localparam [35:0] WD1 = 36'b110011100000001100000100000000011010;
localparam [35:0] WD2 = 36'b010001110111101110010000010011011110;
localparam [35:0] WD3 = 36'b111111011011010000011100011101001110;
localparam [35:0] WD4 = 36'b111000000000111111111110110001110000;
localparam [35:0] WD5 = 36'b010100010011000000000111110100110100;
localparam [35:0] WD6 = 36'b010001010100101110101101000101111010;
localparam [35:0] WD7 = 36'b011111000000101001110001011111000010;
localparam [35:0] WD8 = 36'b111000010110001100111101110111111100;
localparam [35:0] WD9 = 36'b110100000000101110010011011101101000;
localparam [2:0] P1_CUT = 3'd2;
localparam [2:0] P2_CUT = 3'd3;

// ---- word-addressed row memories (Quartus RAM-inference friendly: fixed
// word width, single dynamic ADDRESS selecting a whole word, registered
// read -- NOT a flat vector with a runtime BIT-select like v1 used, which
// cannot infer M9K regardless of clocking style because it isn't "an
// array of words" to the tool at all). ----
reg [27:0] img_mem [0:27];   // 28 rows x 28px, img_mem[y][x] = pixel(y,x)
reg [25:0] a1_mem  [0:25];   // 26 rows x 26px (top-left 26x26 of 27x27 conv1 out)
reg [12:0] p1_mem  [0:12];   // 13 rows x 13px
reg [11:0] a2_mem  [0:11];   // 12 rows x 12px
reg [35:0] p2;                // 6x6=36px flattened dense input -- small enough
                               // to stay a flat register; every index used to
                               // read it below is a compile-time constant
                               // after for-loop unrolling, so no dynamic-index
                               // cost there (see dense_pc)

localparam [3:0]
    S_IDLE    = 4'd0,  S_LOAD    = 4'd1,
    S_C1_ADDR = 4'd2,  S_C1_WAIT = 4'd3,  S_C1_SCAN = 4'd4,
    S_P1_ADDR = 4'd5,  S_P1_WAIT = 4'd6,  S_P1_SCAN = 4'd7,
    S_C2_ADDR = 4'd8,  S_C2_WAIT = 4'd9,  S_C2_SCAN = 4'd10,
    S_P2_ADDR = 4'd11, S_P2_WAIT = 4'd12, S_P2_SCAN = 4'd13,
    S_DENSE   = 4'd14, S_DONE    = 4'd15;

reg [3:0]   state;
reg [4:0]   cy, cx;             // position counters, wide enough for the largest stage (0..27)
reg [4:0]   raddr0, raddr1;     // row addresses currently being fetched
reg [783:0] img_shift;          // load-phase shift register (working copy of image_in)
reg [3:0]   dk;                 // dense neuron index 0..9
reg [5:0]   best_pc;            // best popcount seen so far in S_DENSE
reg [3:0]   best_k;

reg [27:0]  rd_rowA, rd_rowB;   // shared registered row-read outputs (widest
                                 // case = img rows; narrower stages just use
                                 // the low bits)

// synchronous (registered) row reads -- only one of the four arrays is
// "live" at a time depending on `state`, but describing each array's read
// as its own simple `mem[addr]` -> register statement is what lets Quartus
// recognize and infer real RAM for it
always @(posedge clk) begin
    case (state)
        S_C1_ADDR, S_C1_WAIT, S_C1_SCAN: begin
            rd_rowA <= img_mem[raddr0];
            rd_rowB <= img_mem[raddr1];
        end
        S_P1_ADDR, S_P1_WAIT, S_P1_SCAN: begin
            rd_rowA <= {2'b0, a1_mem[raddr0]};
            rd_rowB <= {2'b0, a1_mem[raddr1]};
        end
        S_C2_ADDR, S_C2_WAIT, S_C2_SCAN: begin
            rd_rowA <= {15'b0, p1_mem[raddr0]};
            rd_rowB <= {15'b0, p1_mem[raddr1]};
        end
        S_P2_ADDR, S_P2_WAIT, S_P2_SCAN: begin
            rd_rowA <= {16'b0, a2_mem[raddr0]};
            rd_rowB <= {16'b0, a2_mem[raddr1]};
        end
        default: ; // hold last value, unused outside the stages above
    endcase
end

// ---- conv1: 2x2 window read from the two currently-fetched img rows
// (dynamic index is now only into a 28-bit-wide row register, ~28x
// cheaper per access than v1's 784-bit-wide index) ----
wire i00 = rd_rowA[cx];
wire i01 = rd_rowA[cx + 5'd1];
wire i10 = rd_rowB[cx];
wire i11 = rd_rowB[cx + 5'd1];
wire [2:0] c1_pc = (i00 == W1[0]) + (i01 == W1[1]) + (i10 == W1[2]) + (i11 == W1[3]);
wire a1_bit_now = (c1_pc >= P1_CUT);

reg [25:0] c1_acc;
reg [25:0] c1_acc_next;
always @* begin
    // combinational "next value with this cycle's bit already applied" --
    // same idiom as barcode_decoder.v's hist_nw_next, used here so the
    // end-of-row write below doesn't read a stale (pre-update) c1_acc
    c1_acc_next = c1_acc;
    c1_acc_next[cx] = a1_bit_now;
end

// ---- pool1: OR of the 2x2 block of a1 at (2*cy,2*cx), read from the two
// currently-fetched a1 rows ----
wire pool1_now = rd_rowA[cx<<1] | rd_rowA[(cx<<1) + 5'd1] |
                  rd_rowB[cx<<1] | rd_rowB[(cx<<1) + 5'd1];

reg [12:0] p1_acc;
reg [12:0] p1_acc_next;
always @* begin
    p1_acc_next = p1_acc;
    p1_acc_next[cx] = pool1_now;
end

// ---- conv2: 2x2 window read from the two currently-fetched p1 rows ----
wire c2_00 = rd_rowA[cx];
wire c2_01 = rd_rowA[cx + 5'd1];
wire c2_10 = rd_rowB[cx];
wire c2_11 = rd_rowB[cx + 5'd1];
wire [2:0] c2_pc = (c2_00 == W2[0]) + (c2_01 == W2[1]) + (c2_10 == W2[2]) + (c2_11 == W2[3]);
wire a2_bit_now = (c2_pc >= P2_CUT);

reg [11:0] c2_acc;
reg [11:0] c2_acc_next;
always @* begin
    c2_acc_next = c2_acc;
    c2_acc_next[cx] = a2_bit_now;
end

// ---- pool2: OR of the 2x2 block of a2 at (2*cy,2*cx), read from the two
// currently-fetched a2 rows -- writes straight into the flat p2 (36 bits
// total, cheap to index dynamically even at v1's style, so no memory-array
// treatment needed here) ----
wire pool2_now = rd_rowA[cx<<1] | rd_rowA[(cx<<1) + 5'd1] |
                  rd_rowB[cx<<1] | rd_rowB[(cx<<1) + 5'd1];

// ---- dense: select the whole 36-bit weight vector for neuron dk in one
// step (one 10:1 mux of 36-bit words), then XNOR+popcount against p2 --
// cheaper for the tool to share resources on than v1's per-bit 10-way
// select repeated 36 times ----
reg [35:0] wsel;
always @* begin
    case (dk)
        4'd0: wsel = WD0;  4'd1: wsel = WD1;  4'd2: wsel = WD2;  4'd3: wsel = WD3;
        4'd4: wsel = WD4;  4'd5: wsel = WD5;  4'd6: wsel = WD6;  4'd7: wsel = WD7;
        4'd8: wsel = WD8;  default: wsel = WD9;
    endcase
end
wire [35:0] xnor_bits = ~(p2 ^ wsel);
reg [5:0] dense_pc;
integer di;
always @* begin
    dense_pc = 6'd0;
    for (di = 0; di < 36; di = di + 1)
        if (xnor_bits[di])
            dense_pc = dense_pc + 6'd1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        done      <= 1'b0;
        digit_out <= 4'd0;
        cy <= 5'd0; cx <= 5'd0; dk <= 4'd0;
        raddr0 <= 5'd0; raddr1 <= 5'd0;
        best_pc <= 6'd0; best_k <= 4'd0;
        c1_acc <= 26'd0; p1_acc <= 13'd0; c2_acc <= 12'd0;
        p2 <= 36'd0;
    end
    else begin
        done <= 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    img_shift <= image_in;
                    cy    <= 5'd0;
                    state <= S_LOAD;
                end
            end

            // write image_in into img_mem one 28-bit row per cycle, via a
            // shift register so every row write is a FIXED [27:0] slice
            // (zero dynamic bit-select cost -- only a constant shift-by-28
            // each cycle, which is free rewiring, not a mux)
            S_LOAD: begin
                img_mem[cy] <= img_shift[27:0];
                img_shift   <= img_shift >> 28;
                if (cy == 5'd27) begin
                    cy     <= 5'd0;
                    raddr0 <= 5'd0; raddr1 <= 5'd1;
                    state  <= S_C1_ADDR;
                end
                else cy <= cy + 5'd1;
            end

            S_C1_ADDR: state <= S_C1_WAIT;
            S_C1_WAIT: begin
                cx    <= 5'd0;
                state <= S_C1_SCAN;
            end
            S_C1_SCAN: begin
                c1_acc <= c1_acc_next;
                if (cx == 5'd25) begin
                    a1_mem[cy] <= c1_acc_next;
                    cx <= 5'd0;
                    if (cy == 5'd25) begin
                        cy     <= 5'd0;
                        raddr0 <= 5'd0; raddr1 <= 5'd1;
                        state  <= S_P1_ADDR;
                    end
                    else begin
                        cy     <= cy + 5'd1;
                        raddr0 <= cy + 5'd1;
                        raddr1 <= cy + 5'd2;
                        state  <= S_C1_ADDR;
                    end
                end
                else cx <= cx + 5'd1;
            end

            S_P1_ADDR: state <= S_P1_WAIT;
            S_P1_WAIT: begin
                cx    <= 5'd0;
                state <= S_P1_SCAN;
            end
            S_P1_SCAN: begin
                p1_acc <= p1_acc_next;
                if (cx == 5'd12) begin
                    p1_mem[cy] <= p1_acc_next;
                    cx <= 5'd0;
                    if (cy == 5'd12) begin
                        cy     <= 5'd0;
                        raddr0 <= 5'd0; raddr1 <= 5'd1;
                        state  <= S_C2_ADDR;
                    end
                    else begin
                        cy     <= cy + 5'd1;
                        raddr0 <= (cy + 5'd1) << 1;
                        raddr1 <= ((cy + 5'd1) << 1) + 5'd1;
                        state  <= S_P1_ADDR;
                    end
                end
                else cx <= cx + 5'd1;
            end

            S_C2_ADDR: state <= S_C2_WAIT;
            S_C2_WAIT: begin
                cx    <= 5'd0;
                state <= S_C2_SCAN;
            end
            S_C2_SCAN: begin
                c2_acc <= c2_acc_next;
                if (cx == 5'd11) begin
                    a2_mem[cy] <= c2_acc_next;
                    cx <= 5'd0;
                    if (cy == 5'd11) begin
                        cy     <= 5'd0;
                        raddr0 <= 5'd0; raddr1 <= 5'd1;
                        state  <= S_P2_ADDR;
                    end
                    else begin
                        cy     <= cy + 5'd1;
                        raddr0 <= cy + 5'd1;
                        raddr1 <= cy + 5'd2;
                        state  <= S_C2_ADDR;
                    end
                end
                else cx <= cx + 5'd1;
            end

            S_P2_ADDR: state <= S_P2_WAIT;
            S_P2_WAIT: begin
                cx    <= 5'd0;
                state <= S_P2_SCAN;
            end
            S_P2_SCAN: begin
                p2[cy*6 + cx] <= pool2_now;
                if (cx == 5'd5) begin
                    cx <= 5'd0;
                    if (cy == 5'd5) begin
                        cy      <= 5'd0;
                        dk      <= 4'd0;
                        best_pc <= 6'd0;
                        best_k  <= 4'd0;
                        state   <= S_DENSE;
                    end
                    else begin
                        cy     <= cy + 5'd1;
                        raddr0 <= (cy + 5'd1) << 1;
                        raddr1 <= ((cy + 5'd1) << 1) + 5'd1;
                        state  <= S_P2_ADDR;
                    end
                end
                else cx <= cx + 5'd1;
            end

            S_DENSE: begin
                // dense_pc is combinational off the CURRENT dk -- read it
                // this same cycle (matches the "combinational next-value"
                // pattern used elsewhere in this project to avoid one-cycle
                // register staleness, e.g. barcode_decoder.v's hist_nw_next)
                if (dense_pc > best_pc) begin
                    best_pc <= dense_pc;
                    best_k  <= dk;
                end
                if (dk == 4'd9) begin
                    state <= S_DONE;
                end
                else begin
                    dk <= dk + 4'd1;
                end
            end

            S_DONE: begin
                digit_out <= best_k;   // best_k already holds the final argmax
                done      <= 1'b1;
                state     <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
