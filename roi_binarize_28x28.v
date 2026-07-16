// roi_binarize_28x28.v -- live camera -> 28x28 binarized image for bnn_core.v
//
// Purpose: bridge the 480x272 live camera frame (pixel_x_w/pixel_y_w/disp_y/
// lcd_de_w/lcd_frame_pulse, the same interface every other pixel-level module
// in camera_display_top.v already taps) down to the 28x28/784-bit binary
// image bnn_core.v expects, with NO camera-position-detection logic -- the
// user explicitly chose a fixed capture region over auto-locating the digit
// ("固定取景框(推荐)"), so this module just always reads the same 224x224
// square out of the middle of the frame.
//
// ROI: 224x224 centered in 480x272 -> X0=128 (480-224=256, /2=128),
// Y0=24 (272-224=248, /2=24). 224 = 28*8 exactly, so each 8x8 block of raw
// pixels maps to exactly one of the 28x28 output pixels with no remainder/
// scaling error.
//
// Downsample rule per 8x8 block: OR of "any pixel in the block is dark"
// (y8 < THRESH), not an average -- averaging would wash out thin pen
// strokes that only cover a few pixels out of the 64 in a block; OR keeps
// any stroke that touches the block at all.
//
// Polarity: real paper is dark ink on a bright background -- the OPPOSITE
// of MNIST's convention (bright stroke on dark background, bit=1=stroke)
// that bnn_core.v was trained on. So this module maps dark pixels to bit=1
// ("stroke", +1 in training) to match what the network actually learned,
// same "dark=1" convention threshold_binarize.v/barcode_decoder.v already
// used elsewhere in this project.
//
// Architecture note (same lesson as bnn_core.v's rewrite and CLAUDE.md's
// "踩坑记录"): the 28x28 output is stored as a word-addressed row array
// (img_mem[0:27], 28 bits/row) with a narrow (28-bit) accumulator register
// for the row currently being built, updated via a fixed 3-bit shift+
// constant-offset subtract (cheap, not a real divider) and a dynamic bit
// index only into that narrow 28-bit accumulator -- NOT a flat 784-bit
// vector with a runtime bit-select, which is exactly the pattern that blew
// bnn_core.v's original v1 up to 5,776 LE. Reading the finished image back
// out (img_out) is a STATIC (compile-time-constant-indexed) concatenation
// of all 28 words, same as bnn_core.v's img loading.
//
// Timing: img_valid pulses one cycle after frame_pulse, once the very last
// block-row has been flushed into img_mem -- by which point the NEXT
// frame's live pixel stream hasn't reached the ROI yet (ROI starts at
// pixel_y=24, i.e. 24 full lines of vertical blanking + active-but-outside-
// ROI margin away), so a consumer that latches img_out the cycle img_valid
// is high always gets a fully-flushed, non-torn frame.
module roi_binarize_28x28 #(
    parameter [10:0] ROI_X0  = 11'd128,
    parameter [10:0] ROI_Y0  = 11'd24,
    parameter [7:0]  THRESH  = 8'd100   // y8 < THRESH => "dark" (ink stroke)
)(
    input             clk,          // clk_9m
    input             rst_n,        // sys_rst_n
    input             de,           // lcd_de_w
    input             frame_pulse,  // lcd_frame_pulse
    input      [7:0]  y8,           // disp_y
    input      [10:0] pixel_x,      // pixel_x_w
    input      [10:0] pixel_y,      // pixel_y_w

    output reg         img_valid,   // 1-cycle pulse: img_out is a fresh, complete frame
    output     [783:0] img_out      // bit[y*28+x] = pixel(y,x), 1=stroke, 0=bg -- same
                                     // convention bnn_core.v's image_in expects
);

wire in_roi_x = (pixel_x >= ROI_X0) && (pixel_x < ROI_X0 + 11'd224);
wire in_roi_y = (pixel_y >= ROI_Y0) && (pixel_y < ROI_Y0 + 11'd224);
wire hit      = de && in_roi_x && in_roi_y;

// Constant-offset subtract + fixed >>3 -- pure wiring, not a real divider.
wire [4:0] bx = (pixel_x - ROI_X0) >> 3;   // 0-27
wire [4:0] by = (pixel_y - ROI_Y0) >> 3;   // 0-27
wire       dark = (y8 < THRESH);

reg [27:0] img_mem [0:27];
reg [27:0] accum_row;
reg [4:0]  by_reg;
reg        row_active;

// Combinational "what accum_row becomes" helpers, same next-value idiom
// used in bnn_core.v's c1_acc_next/etc to avoid same-cycle stale reads.
reg [27:0] new_row_seed;
always @* begin
    new_row_seed = 28'd0;
    new_row_seed[bx] = dark;
end

reg [27:0] cont_row_next;
always @* begin
    cont_row_next = accum_row;
    cont_row_next[bx] = accum_row[bx] | dark;
end

integer k;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_row  <= 28'd0;
        by_reg     <= 5'd0;
        row_active <= 1'b0;
        img_valid  <= 1'b0;
        for (k = 0; k < 28; k = k + 1)
            img_mem[k] <= 28'd0;
    end
    else begin
        img_valid <= 1'b0;

        if (hit) begin
            if (!row_active) begin
                // first ROI pixel of this frame
                by_reg     <= by;
                row_active <= 1'b1;
                accum_row  <= new_row_seed;
            end
            else if (by != by_reg) begin
                // crossed into a new block-row: flush the row that just
                // finished (accum_row, NOT including this pixel -- this
                // pixel belongs to the new row), then start the new one
                img_mem[by_reg] <= accum_row;
                by_reg          <= by;
                accum_row       <= new_row_seed;
            end
            else begin
                accum_row <= cont_row_next;
            end
        end

        if (frame_pulse) begin
            if (row_active)
                img_mem[by_reg] <= accum_row;   // flush the last row
            row_active <= 1'b0;
            img_valid  <= 1'b1;
        end
    end
end

// Static, compile-time-constant-indexed readout -- cheap, matches
// bnn_core.v's own img_mem packing (row 0 = low bits, row 27 = high bits).
assign img_out = {img_mem[27], img_mem[26], img_mem[25], img_mem[24],
                   img_mem[23], img_mem[22], img_mem[21], img_mem[20],
                   img_mem[19], img_mem[18], img_mem[17], img_mem[16],
                   img_mem[15], img_mem[14], img_mem[13], img_mem[12],
                   img_mem[11], img_mem[10], img_mem[9],  img_mem[8],
                   img_mem[7],  img_mem[6],  img_mem[5],  img_mem[4],
                   img_mem[3],  img_mem[2],  img_mem[1],  img_mem[0]};

endmodule
