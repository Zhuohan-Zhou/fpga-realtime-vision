// bnn_demo_top.v -- standalone real-hardware validation demo for bnn_core.v.
//
// Why this exists: bnn_core.v was verified in simulation (7/7 real MNIST
// test images correctly reproduced, including the one deliberate
// misclassification) and its resource footprint was confirmed via a real
// Analysis & Synthesis run (2,860 LE / ~28% of the EP4CE10's 10,320 LE
// budget, after the M9K-friendly row-memory rewrite -- down from the first
// version's 5,776 LE). Neither of those actually proves the real silicon
// computes the right answer: simulation is a model of the RTL, and
// Analysis & Synthesis alone doesn't even run Fitter/place-and-route. This
// module is a minimal, self-contained top-level (its own TOP_LEVEL_ENTITY,
// separate from camera_display_top) whose only job is: press a button on
// the real board, watch the 4 onboard LEDs show a real predicted digit
// computed by real bnn_core hardware, and check it against the known
// expected answer.
//
// Cycles through the same 7 real MNIST test images used in tb_bnn_core.v
// (see bnn_test_images.txt / verify_and_export.py for provenance) --
// KEY1 advances to the next image and re-triggers classification. Chosen
// deliberately over a single fixed hardcoded image: with only one constant
// input, Quartus's synthesis optimizer could in principle constant-fold
// the entire bnn_core computation down to a hardwired answer, which would
// make both the earlier LE count and this demo meaningless (not exercising
// the real datapath at all). Driving image_in from a runtime-selected
// index (KEY1, a real physical button) means the classification logic
// can't be optimized away like that.
//
// True MNIST labels / expected hardware predictions for the 7 images
// (index -> true_label -> expected pred), matching tb_bnn_core.v exactly:
//   0: true=7 pred=7   1: true=1 pred=1   2: true=0 pred=0
//   3: true=4 pred=4   4: true=9 pred=9   5: true=3 pred=3
//   6: true=2 pred=6  <-- deliberate misclassification, reproduced on
//                          purpose: pressing through to this one and
//                          seeing LEDs show 6 (not 2) confirms real
//                          hardware matches simulation bit-for-bit, not
//                          just on the "easy" cases.
//
// LED encoding: led[3:0] = digit_out in plain binary (0-9 fits in 4 bits).
// Boots straight into classifying image 0 (no button press needed to see
// the first result); each KEY1 press advances to the next image (wraps
// after 6) and reclassifies.
//
// Port names (clk/rst_n/key1_n/led) deliberately match the existing
// GLOBAL (non -entity-scoped) pin assignments already in CameraCapture.qsf
// (PIN_E1/PIN_N13/PIN_M15/PIN_E10,F9,C9,D9 -- see sd_test_top.v for the
// same convention: 50MHz clk on E1, active-low rst_n on N13, led driven
// directly with no inversion). No new location/IO_STANDARD assignments
// needed in the qsf for this module -- it inherits them by port name.
//
// ---- Real-hardware debug note (2026-07-16) ----
// First real-board test: compiled clean (Top-level Entity Name confirmed
// bnn_demo_top, 1,507 LE / 15%, 7 pins), but LEDs stayed dark and neither
// KEY1 nor the board reset button changed anything -- while
// camera_display_top (same clk/rst_n/KEY1 pins) is confirmed working fine
// on this exact board, ruling out a programming/board/pin problem.
// Prime suspect: `test_img`/`true_label` were originally `reg` arrays
// populated by an `initial` block. That pattern is simulator-only-reliable
// in the general case -- whether Quartus faithfully turns an `initial`
// block into real power-up ROM/RAM content on the actual silicon isn't
// guaranteed the way a pure `localparam` is, and if that load silently
// didn't take, EVERY img_idx would read back the same (probably
// all-zero) image, which would explain "identical, unchanging output no
// matter what you press" exactly. Fixed by switching to the same
// case-of-localparam pattern bnn_core.v's own `wsel` weight lookup already
// uses successfully (see IMG0..IMG6 below) -- pure combinational constant
// selection, no dependency on initial-block-to-hardware RAM loading at
// all, still driven by a runtime register (img_idx) so the "avoid
// constant folding the whole computation away" property from the previous
// paragraph is preserved.
module bnn_demo_top (
    input        clk,       // 50MHz board clock, PIN_E1
    input        rst_n,     // board reset button, PIN_N13
    input        key1_n,    // PIN_M15, active-low, "next image" button
    output [3:0] led        // PIN_E10/F9/C9/D9
);

// ---- the 7 real MNIST test images, bit-identical to tb_bnn_core.v /
// bnn_test_images.txt (bit[y*28+x] = pixel(y,x)). localparam constants --
// not a reg array + initial block, see debug note above. ----
localparam [783:0] IMG0 = 784'b0000000000000000000000000000000000000000000110000000000000000000000000111000000000000000000000000011100000000000000000000000001110000000000000000000000000110000000000000000000000000110000000000000000000000000111000000000000000000000000111000000000000000000000000011000000000000000000000000011000000000000000000000000001100000000000000000000000001110000000000000000000000000110000000000000000000000000111000000000000000000000000011000000000000000000000000011000000000000000000000000001100000000000000000000000001111111111110000000000000000011111111111111100000000000000000000000011100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG1 = 784'b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000110000000000000000000000000011000000000000000000000000011100000000000000000000000001100000000000000000000000000110000000000000000000000000111000000000000000000000000011000000000000000000000000001100000000000000000000000000110000000000000000000000000110000000000000000000000000011000000000000000000000000001100000000000000000000000001100000000000000000000000000110000000000000000000000000011000000000000000000000000001000000000000000000000000001100000000000000000000000000110000000000000000000000000010000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG2 = 784'b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001110000000000000000000000011111110000000000000000000111111111100000000000000001111111111110000000000000000111111110011100000000000000111111000001110000000000000011111000000111000000000000011110000000011100000000000001110000000001110000000000001111000000000110000000000000011100000000111000000000000001110000000111100000000000000011100001111110000000000000000110001111110000000000000000011111111111000000000000000000111111111000000000000000000000111111000000000000000000000001111000000000000000000000000111000000000000000000000000011100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG3 = 784'b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000011000000000000000000000000011100000000000000000000000001100000000000000000000000000110000000000000000000000000011000000000000000000000000001110000000000000000000000000111111111110000000000000000011111000011100000000000000001100000000110000000000000001110000000011000000000000000111000000001100000000000000011000000000110000000000000011100000000110000000000000001100000000011000000000000000110000000011000000000000000010000000011000000000000000001000000001100000000000000000110000000100000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG4 = 784'b0000000000000000000000000000000000000000010000000000000000000000000001100000000000000000000000000110000000000000000000000000110000000000000000000000000011000000000000000000000000001100000000000000000000000001110000000000000000000000000110000000000000000000000000111000000000000000000000000011100000000000000000000000001101111110000000000000000001111111111100000000000000000111100001110000000000000000011100000111000000000000000011100000011100000000000000001100000011100000000000000001110000011100000000000000000110000011100000000000000000011111111100000000000000000000001111100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG5 = 784'b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000011111111100000000000000000111111111111100000000000000111110000001111000000000000011100000000001100000000000001110000000000111000000000000011100000000001100000000000001111000000000000000000000000011111000000000000000000000000111111111111000000000000000000111111111110000000000000000000111111111001000000000000000001110001000110000000000000000111000000011000000000000000011110000001100000000000000000111100001110000000000000000000111001110000000000000000000001111111100000000000000000000011111100000000000000000000000011000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
localparam [783:0] IMG6 = 784'b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001111100000000000000000111111111111111100000000001111111111111111110000000000111100000000000111000000000000000000000000011100000000000000000000000011110000000000000000000000011110000000000000000000000001110000000000000000000000001111000000000000000000000000111000000000000000000000000111100000000000000000000000111000000000000000000000000011100000000000000000000000011100000000000000000000000001110000000000000000000000000110000011000000000000000000111000011100000000000000000001111111110000000000000000000111111110000000000000000000001111000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;

// pure combinational constant select -- same pattern as bnn_core.v's own
// wsel dense-weight lookup, driven by a runtime register (img_idx), so
// the "don't let Quartus constant-fold the whole computation away" intent
// from the module header still holds
reg [783:0] cur_image;
always @* begin
    case (img_idx)
        3'd0: cur_image = IMG0;
        3'd1: cur_image = IMG1;
        3'd2: cur_image = IMG2;
        3'd3: cur_image = IMG3;
        3'd4: cur_image = IMG4;
        3'd5: cur_image = IMG5;
        default: cur_image = IMG6;
    endcase
end

// ---- KEY1 debounce + single-pulse falling-edge detect (button is
// active-low, so a press is a 1->0 transition). Simple 2-flop
// synchronizer + majority-hold debounce counter -- ~1.3ms at 50MHz
// (16-bit counter must saturate before the stable value is allowed to
// change), well above typical mechanical bounce time. ----
reg [15:0] db_cnt;
reg key1_sync0, key1_sync1, key1_stable, key1_stable_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key1_sync0    <= 1'b1;
        key1_sync1    <= 1'b1;
        key1_stable   <= 1'b1;
        key1_stable_d <= 1'b1;
        db_cnt        <= 16'd0;
    end
    else begin
        key1_sync0 <= key1_n;
        key1_sync1 <= key1_sync0;
        if (key1_sync1 != key1_stable) begin
            db_cnt <= db_cnt + 16'd1;
            if (db_cnt == 16'hFFFF)
                key1_stable <= key1_sync1;
        end
        else begin
            db_cnt <= 16'd0;
        end
        key1_stable_d <= key1_stable;
    end
end
wire key1_pressed = key1_stable_d && !key1_stable;   // falling edge only

// ---- image index + bnn_core driver FSM ----
localparam [1:0] F_BOOT  = 2'd0,
                  F_IDLE  = 2'd1,
                  F_START = 2'd2,
                  F_WAIT  = 2'd3;

reg [1:0] fsm;
reg [3:0] boot_cnt;
reg [2:0] img_idx;
reg       start;
reg [3:0] result;

wire        done;
wire [3:0]  digit_out;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fsm      <= F_BOOT;
        boot_cnt <= 4'd0;
        img_idx  <= 3'd0;
        start    <= 1'b0;
        result   <= 4'd0;
    end
    else begin
        start <= 1'b0;

        case (fsm)
            // wait a few cycles after reset release before the very
            // first auto classification -- avoids racing bnn_core's own
            // reset release on the same edge
            F_BOOT: begin
                if (boot_cnt == 4'd8) fsm <= F_START;
                else boot_cnt <= boot_cnt + 4'd1;
            end

            F_IDLE: begin
                if (key1_pressed) begin
                    img_idx <= (img_idx == 3'd6) ? 3'd0 : img_idx + 3'd1;
                    fsm     <= F_START;
                end
            end

            F_START: begin
                start <= 1'b1;
                fsm   <= F_WAIT;
            end

            F_WAIT: begin
                if (done) begin
                    result <= digit_out;
                    fsm    <= F_IDLE;
                end
            end

            default: fsm <= F_IDLE;
        endcase
    end
end

bnn_core u_bnn (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (start),
    .image_in  (cur_image),
    .done      (done),
    .digit_out (digit_out)
);

assign led = result;

endmodule
