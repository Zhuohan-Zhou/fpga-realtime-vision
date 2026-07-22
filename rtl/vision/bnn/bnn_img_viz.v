// bnn_img_viz.v -- debug view: draw roi_binarize_28x28.v's 28x28 binary
// image on the LCD, blown up SCALE x SCALE per cell, so you can see
// exactly what bnn_core.v is actually classifying instead of guessing
// from the digital-tube result alone.
module bnn_img_viz #(
    parameter [10:0] VIZ_X0 = 11'd360,
    parameter [10:0] VIZ_Y0 = 11'd80,
    parameter integer SCALE = 4          // 28*4 = 112x112 screen pixels
)(
    input              clk,        // clk_9m
    input              rst_n,      // sys_rst_n
    input              img_valid,  // roi_binarize_28x28.img_valid, pulses once/frame
    input      [783:0] img_in,     // roi_binarize_28x28.img_out, sampled at img_valid
    input      [10:0]  pixel_x,    // pixel_x_w
    input      [10:0]  pixel_y,    // pixel_y_w

    output             viz_pixel,  // 1 = this screen pixel is inside the 28x28 grid area
    output             viz_bit     // 1 = ink (draw black), 0 = background (draw white)
);

localparam integer VIZ_SIZE = 28 * SCALE;

// Latch one frame's image into a row-addressed array using static
// (compile-time-constant) slice indices -- not a dynamic bit-select into
// the flat 784-bit img_in. Same lesson as bnn_core.v/roi_binarize_28x28.v:
// a flat vector + runtime bit-select is what blew bnn_core.v's original
// version up to 5776 LE; a word-addressed array avoids that.
reg [27:0] viz_mem [0:27];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        viz_mem[0]  <= 28'd0;  viz_mem[1]  <= 28'd0;  viz_mem[2]  <= 28'd0;  viz_mem[3]  <= 28'd0;
        viz_mem[4]  <= 28'd0;  viz_mem[5]  <= 28'd0;  viz_mem[6]  <= 28'd0;  viz_mem[7]  <= 28'd0;
        viz_mem[8]  <= 28'd0;  viz_mem[9]  <= 28'd0;  viz_mem[10] <= 28'd0;  viz_mem[11] <= 28'd0;
        viz_mem[12] <= 28'd0;  viz_mem[13] <= 28'd0;  viz_mem[14] <= 28'd0;  viz_mem[15] <= 28'd0;
        viz_mem[16] <= 28'd0;  viz_mem[17] <= 28'd0;  viz_mem[18] <= 28'd0;  viz_mem[19] <= 28'd0;
        viz_mem[20] <= 28'd0;  viz_mem[21] <= 28'd0;  viz_mem[22] <= 28'd0;  viz_mem[23] <= 28'd0;
        viz_mem[24] <= 28'd0;  viz_mem[25] <= 28'd0;  viz_mem[26] <= 28'd0;  viz_mem[27] <= 28'd0;
    end
    else if (img_valid) begin
        // img_in[y*28+x] = pixel(y,x) (same convention as bnn_core.v's
        // image_in) -- row y occupies bits [y*28+27 : y*28].
        viz_mem[0]  <= img_in[27:0];     viz_mem[1]  <= img_in[55:28];
        viz_mem[2]  <= img_in[83:56];    viz_mem[3]  <= img_in[111:84];
        viz_mem[4]  <= img_in[139:112];  viz_mem[5]  <= img_in[167:140];
        viz_mem[6]  <= img_in[195:168];  viz_mem[7]  <= img_in[223:196];
        viz_mem[8]  <= img_in[251:224];  viz_mem[9]  <= img_in[279:252];
        viz_mem[10] <= img_in[307:280];  viz_mem[11] <= img_in[335:308];
        viz_mem[12] <= img_in[363:336];  viz_mem[13] <= img_in[391:364];
        viz_mem[14] <= img_in[419:392];  viz_mem[15] <= img_in[447:420];
        viz_mem[16] <= img_in[475:448];  viz_mem[17] <= img_in[503:476];
        viz_mem[18] <= img_in[531:504];  viz_mem[19] <= img_in[559:532];
        viz_mem[20] <= img_in[587:560];  viz_mem[21] <= img_in[615:588];
        viz_mem[22] <= img_in[643:616];  viz_mem[23] <= img_in[671:644];
        viz_mem[24] <= img_in[699:672];  viz_mem[25] <= img_in[727:700];
        viz_mem[26] <= img_in[755:728];  viz_mem[27] <= img_in[783:756];
    end
end

wire in_viz_x = (pixel_x >= VIZ_X0) && (pixel_x < VIZ_X0 + VIZ_SIZE);
wire in_viz_y = (pixel_y >= VIZ_Y0) && (pixel_y < VIZ_Y0 + VIZ_SIZE);
assign viz_pixel = in_viz_x && in_viz_y;

// SCALE=4 -> fixed >>2, pure wiring, not a real divider (same idiom as
// roi_binarize_28x28.v's bx/by).
wire [4:0] viz_col = (pixel_x - VIZ_X0) >> 2;   // 0-27
wire [4:0] viz_row = (pixel_y - VIZ_Y0) >> 2;   // 0-27

// Two small combinational selects (28-way row pick, then 1-bit pick from
// that already-narrow 28-bit row) -- nowhere near the flat-784-bit,
// single-dynamic-index case that caused bnn_core.v's original blowup.
// viz_mem itself is only 784 bits total, far below what Quartus would
// ever consider mapping to M9K, so there's no synchronous-read-only
// constraint being violated here either.
assign viz_bit = viz_mem[viz_row][viz_col];

endmodule
