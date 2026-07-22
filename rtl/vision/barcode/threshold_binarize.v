module threshold_binarize #(
    parameter [7:0] THRESH = 8'd128
)(
    input      [7:0] y8,
    output     [7:0] bin_r,
    output     [7:0] bin_g,
    output     [7:0] bin_b
);

wire white = (y8 >= THRESH);

assign bin_r = white ? 8'd255 : 8'd0;
assign bin_g = white ? 8'd255 : 8'd0;
assign bin_b = white ? 8'd255 : 8'd0;

endmodule
