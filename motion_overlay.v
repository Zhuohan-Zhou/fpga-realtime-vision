// motion_overlay.v -- tints pixels inside a "changed" motion cell with a
// ~50% yellow wash (average with solid yellow) so the moving region shows
// without hiding the image underneath. Combinational, just shifts + add.
module motion_overlay (
    input             highlight,

    input      [7:0]  in_r,
    input      [7:0]  in_g,
    input      [7:0]  in_b,

    output     [7:0]  out_r,
    output     [7:0]  out_g,
    output     [7:0]  out_b
);

// yellow = (255, 255, 0); blended = (in + yellow) / 2
wire [7:0] blend_r = {1'b0, in_r[7:1]} + 8'd128;
wire [7:0] blend_g = {1'b0, in_g[7:1]} + 8'd128;
wire [7:0] blend_b = {1'b0, in_b[7:1]};

assign out_r = highlight ? blend_r : in_r;
assign out_g = highlight ? blend_g : in_g;
assign out_b = highlight ? blend_b : in_b;

endmodule
