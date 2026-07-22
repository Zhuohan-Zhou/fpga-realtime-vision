`timescale 1ns/1ps
// tb_bnn_img_viz.v -- verifies bnn_img_viz.v's bit ordering (row/col
// mapping must match bnn_core.v's image_in[y*28+x] = pixel(y,x)
// convention) and the on-screen box geometry, before trusting it on
// real hardware.
module tb_bnn_img_viz;

reg         clk = 0;
reg         rst_n;
reg         img_valid;
reg [783:0] img_in;
reg [10:0]  pixel_x, pixel_y;
wire        viz_pixel, viz_bit;

integer errors = 0;

bnn_img_viz #(.VIZ_X0(11'd360), .VIZ_Y0(11'd80), .SCALE(4)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .img_valid (img_valid),
    .img_in    (img_in),
    .pixel_x   (pixel_x),
    .pixel_y   (pixel_y),
    .viz_pixel (viz_pixel),
    .viz_bit   (viz_bit)
);

always #5 clk = ~clk;

task check_cell(input [4:0] row, input [4:0] col, input expected);
    begin
        pixel_x = 11'd360 + col * 4 + 1;   // land inside the 4x4 cell, not on its edge
        pixel_y = 11'd80  + row * 4 + 1;
        #1;
        if (viz_pixel !== 1'b1) begin
            $display("FAIL: cell (row=%0d,col=%0d) expected viz_pixel=1, got %b", row, col, viz_pixel);
            errors = errors + 1;
        end
        else if (viz_bit !== expected) begin
            $display("FAIL: cell (row=%0d,col=%0d) expected viz_bit=%b, got %b", row, col, expected, viz_bit);
            errors = errors + 1;
        end
    end
endtask

task check_outside(input [10:0] x, input [10:0] y, input [255:0] label);
    begin
        pixel_x = x; pixel_y = y;
        #1;
        if (viz_pixel !== 1'b0) begin
            $display("FAIL: %0s (x=%0d,y=%0d) expected viz_pixel=0, got %b", label, x, y, viz_pixel);
            errors = errors + 1;
        end
    end
endtask

initial begin
    rst_n = 0; img_valid = 0; img_in = 784'd0; pixel_x = 0; pixel_y = 0;
    #12 rst_n = 1;
    #10;

    // -------------------------------------------------------------
    // Test 1: bit-order sanity -- set 4 distinct known bits (corners +
    // one interior point of the 28x28 grid) and confirm each shows up
    // at the *matching* screen cell, not transposed/mirrored/reversed.
    // image_in[y*28+x] = pixel(y,x) convention, same as bnn_core.v.
    // -------------------------------------------------------------
    img_in = 784'd0;
    img_in[0*28 + 0]   = 1'b1;   // (row=0,  col=0)  top-left
    img_in[0*28 + 27]  = 1'b1;   // (row=0,  col=27) top-right
    img_in[27*28 + 0]  = 1'b1;   // (row=27, col=0)  bottom-left
    img_in[27*28 + 27] = 1'b1;   // (row=27, col=27) bottom-right
    img_in[5*28 + 12]  = 1'b1;   // (row=5,  col=12) interior, no symmetry to hide a swap bug
    // Drive img_valid on negedge (same idiom as tb_bnn_core.v's `start`
    // pulse) so it's stable well before the posedge the DUT samples it
    // on -- toggling it right at the same posedge the DUT reacts to is a
    // same-edge race (simulator-order-dependent whether the DUT's always
    // block sees the old or new value), which is what the first version
    // of this testbench hit.
    @(negedge clk); img_valid = 1'b1;
    @(negedge clk); img_valid = 1'b0;
    #5;

    check_cell(5'd0,  5'd0,  1'b1);
    check_cell(5'd0,  5'd27, 1'b1);
    check_cell(5'd27, 5'd0,  1'b1);
    check_cell(5'd27, 5'd27, 1'b1);
    check_cell(5'd5,  5'd12, 1'b1);
    // a neighbor of the interior point that should be 0 -- catches an
    // off-by-one in the row/col -> bit-index arithmetic
    check_cell(5'd5,  5'd13, 1'b0);
    check_cell(5'd6,  5'd12, 1'b0);
    // a cell nowhere near any set bit
    check_cell(5'd14, 5'd14, 1'b0);

    // -------------------------------------------------------------
    // Test 2: geometry -- box should be exactly 112x112 at (360,80),
    // nothing outside that should read viz_pixel=1.
    // -------------------------------------------------------------
    check_outside(11'd359, 11'd100, "just left of box");
    check_outside(11'd472, 11'd100, "just right of box (360+112)");
    check_outside(11'd400, 11'd79,  "just above box");
    check_outside(11'd400, 11'd192, "just below box (80+112)");
    check_outside(11'd128, 11'd24,  "inside the ROI green-box area, unrelated to viz box");

    // -------------------------------------------------------------
    // Test 3: a second img_valid pulse with a different pattern should
    // fully replace the previous frame (no stale bits left over).
    // -------------------------------------------------------------
    img_in = 784'd0;
    img_in[10*28 + 20] = 1'b1;
    @(negedge clk); img_valid = 1'b1;
    @(negedge clk); img_valid = 1'b0;
    #5;
    check_cell(5'd0, 5'd0, 1'b0);     // previously-set corner must be cleared now
    check_cell(5'd10, 5'd20, 1'b1);   // new bit present

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

endmodule
