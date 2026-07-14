// overlay_marker.v -- draws a bright green crosshair over the live video at
// (cx, cy). Purely combinational, slots between yuv422_to_rgb888's output
// and lcd_driver's input, same pixel_x/pixel_y sweep as the rest of the path.
module overlay_marker #(
    parameter CROSS_HALF_LEN = 10,  // arm length in pixels
    parameter LINE_THICK     = 1    // half-thickness in pixels
)(
    input      [10:0] pixel_x,
    input      [10:0] pixel_y,
    input      [10:0] cx,
    input      [10:0] cy,
    input              blob_found,

    input      [7:0]  in_r,
    input      [7:0]  in_g,
    input      [7:0]  in_b,

    output     [7:0]  out_r,
    output     [7:0]  out_g,
    output     [7:0]  out_b
);

// signed deltas so we don't wrap around near the screen edges
wire signed [11:0] dx = $signed({1'b0, pixel_x}) - $signed({1'b0, cx});
wire signed [11:0] dy = $signed({1'b0, pixel_y}) - $signed({1'b0, cy});

wire on_h_arm = (dy >= -LINE_THICK) && (dy <= LINE_THICK) &&
                (dx >= -CROSS_HALF_LEN) && (dx <= CROSS_HALF_LEN);
wire on_v_arm = (dx >= -LINE_THICK) && (dx <= LINE_THICK) &&
                (dy >= -CROSS_HALF_LEN) && (dy <= CROSS_HALF_LEN);

wire draw = blob_found && (on_h_arm || on_v_arm);

assign out_r = draw ? 8'd0   : in_r;
assign out_g = draw ? 8'd255 : in_g;
assign out_b = draw ? 8'd0   : in_b;

endmodule
