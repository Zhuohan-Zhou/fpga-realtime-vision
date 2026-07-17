`timescale 1ns/1ps
// Functional testbench for roi_binarize_28x28.v. Drives a synthetic
// 480x272 raster (matching the real camera_display_top.v pixel_x_w/
// pixel_y_w/lcd_de_w/lcd_frame_pulse timing convention: de high for every
// active pixel in raster order, frame_pulse for one cycle between frames)
// with a single known dark 8x8 block placed at a chosen ROI block position,
// and checks img_out comes back with exactly one bit set at the expected
// (by*28+bx) position. A second, fully-bright frame checks img_out goes
// back to all-zero (no stuck bits carried over from the previous frame).
module tb_roi_binarize_28x28;

localparam [10:0] ROI_X0 = 11'd128;
localparam [10:0] ROI_Y0 = 11'd24;
localparam [7:0]  THRESH = 8'd100;

reg clk = 0;
reg rst_n;
reg de;
reg frame_pulse;
reg [7:0] y8;
reg [10:0] pixel_x, pixel_y;

wire img_valid;
wire [783:0] img_out;
wire [15:0] ink_count;

roi_binarize_28x28 #(
    .ROI_X0 (ROI_X0),
    .ROI_Y0 (ROI_Y0),
    .THRESH (THRESH)
) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .de          (de),
    .frame_pulse (frame_pulse),
    .y8          (y8),
    .pixel_x     (pixel_x),
    .pixel_y     (pixel_y),
    .img_valid   (img_valid),
    .img_out     (img_out),
    .ink_count   (ink_count)
);

always #10 clk = ~clk;

integer errors = 0;

// dark 8x8 block target: block (bx=10, by=5) -> pixel range
// x = 128+80..128+87 (208..215), y = 24+40..24+47 (64..71)
localparam integer DARK_BX = 10;
localparam integer DARK_BY = 5;
localparam integer DARK_X0 = 128 + DARK_BX*8;
localparam integer DARK_Y0 = 24  + DARK_BY*8;

task send_frame(input have_dark_block);
    integer x, y;
    begin
        for (y = 0; y < 272; y = y + 1) begin
            for (x = 0; x < 480; x = x + 1) begin
                @(negedge clk);
                pixel_x = x[10:0];
                pixel_y = y[10:0];
                de      = 1'b1;
                if (have_dark_block &&
                    x >= DARK_X0 && x < DARK_X0+8 &&
                    y >= DARK_Y0 && y < DARK_Y0+8)
                    y8 = 8'd50;    // dark
                else
                    y8 = 8'd200;   // bright
            end
        end
        @(negedge clk);
        de = 1'b0;
        frame_pulse = 1'b1;
        @(negedge clk);
        frame_pulse = 1'b0;
    end
endtask

integer i;
reg found_bit;
reg other_bits_clear;

initial begin
    rst_n = 0;
    de = 0;
    frame_pulse = 0;
    y8 = 8'd200;
    pixel_x = 0;
    pixel_y = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- Test 1: one dark block ----
    send_frame(1);
    // img_valid pulses the cycle after frame_pulse's flush lands
    wait (img_valid == 1'b1);
    #1;

    found_bit = img_out[DARK_BY*28 + DARK_BX];
    if (!found_bit) begin
        $display("FAIL Test1: expected bit at (bx=%0d,by=%0d) [flat idx %0d] to be 1, got 0",
                  DARK_BX, DARK_BY, DARK_BY*28+DARK_BX);
        errors = errors + 1;
    end
    else
        $display("Test1: dark block bit set correctly at flat idx %0d", DARK_BY*28+DARK_BX);

    other_bits_clear = 1'b1;
    for (i = 0; i < 784; i = i + 1) begin
        if (i != DARK_BY*28+DARK_BX && img_out[i] !== 1'b0)
            other_bits_clear = 1'b0;
    end
    if (!other_bits_clear) begin
        $display("FAIL Test1: unexpected extra bit(s) set outside the dark block");
        errors = errors + 1;
    end
    else
        $display("Test1: no unexpected bits set elsewhere");

    // dark 8x8 block = 64 raw dark pixels -> ink_count should read exactly 64
    if (ink_count !== 16'd64) begin
        $display("FAIL Test1: expected ink_count=64, got %0d", ink_count);
        errors = errors + 1;
    end
    else
        $display("Test1: ink_count correctly reads 64 (8x8 dark block)");

    // ---- Test 2: fully bright frame -> all zero, no leftover bits ----
    send_frame(0);
    wait (img_valid == 1'b1);
    #1;

    if (img_out !== 784'd0) begin
        $display("FAIL Test2: expected all-zero image, got nonzero (img_out != 0)");
        errors = errors + 1;
    end
    else
        $display("Test2: all-bright frame correctly produced all-zero image");

    if (ink_count !== 16'd0) begin
        $display("FAIL Test2: expected ink_count=0 for blank frame, got %0d", ink_count);
        errors = errors + 1;
    end
    else
        $display("Test2: ink_count correctly reads 0 (no dark pixels, no stale carryover)");

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

initial begin
    #500000000;   // generous timeout for two full 480x272 raster sweeps
    $display("TIMEOUT");
    $finish;
end

endmodule
