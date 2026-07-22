module bnn_core (
    input             clk,
    input             rst_n,
    input             start,          // 1-cycle pulse: begin classifying image_in
    input   [783:0]   image_in,       // bit[y*28+x] = pixel(y,x), 1=stroke(+1), 0=bg(-1)

    output reg        done,           // 1-cycle pulse when digit_out is valid
    output reg [3:0]  digit_out       // predicted digit 0-9
);

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


reg [27:0] img_mem [0:27];   // 28 rows x 28px, img_mem[y][x] = pixel(y,x)
reg [25:0] a1_mem  [0:25];   // 26 rows x 26px (top-left 26x26 of 27x27 conv1 out)
reg [12:0] p1_mem  [0:12];   // 13 rows x 13px
reg [11:0] a2_mem  [0:11];   // 12 rows x 12px
reg [35:0] p2;                // 6x6=36px flattened dense input

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

wire i00 = rd_rowA[cx];
wire i01 = rd_rowA[cx + 5'd1];
wire i10 = rd_rowB[cx];
wire i11 = rd_rowB[cx + 5'd1];
wire [2:0] c1_pc = (i00 == W1[0]) + (i01 == W1[1]) + (i10 == W1[2]) + (i11 == W1[3]);
wire a1_bit_now = (c1_pc >= P1_CUT);

reg [25:0] c1_acc;
reg [25:0] c1_acc_next;
always @* begin
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


wire pool2_now = rd_rowA[cx<<1] | rd_rowA[(cx<<1) + 5'd1] |
                  rd_rowB[cx<<1] | rd_rowB[(cx<<1) + 5'd1];


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
