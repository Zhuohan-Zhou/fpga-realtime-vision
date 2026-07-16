`timescale 1ns/1ps
// Functional testbench for ean13_decoder.v.
// Streams a real EAN-13 barcode (ean=4006381333931, built + verified via
// python-barcode's own encoder) on the fixed scan row at 4px/module, and
// checks all 13 digits decode correctly with the checksum gate passing.
// Second test: a barcode-free frame must never assert ean_valid.
module tb_ean13_decoder;

localparam WIDTH  = 480;
localparam HEIGHT = 145;

localparam [10:0] SCAN_ROW = 11'd136;
localparam [7:0]  DARK_Y8  = 8'd50;    // bar
localparam [7:0]  LIGHT_Y8 = 8'd200;   // space / background

reg clk = 0;
reg rst_n;
reg de, frame_pulse;
reg [7:0] y8;
reg [10:0] pixel_x, pixel_y;

wire ean_valid;
wire [51:0] decoded_digits;
wire scan_active;

ean13_decoder #(
    .SCAN_ROW      (SCAN_ROW),
    .THRESH        (8'd128),
    .MIN_MODULE_PX (11'd3)
) dut (
    .clk (clk), .rst_n (rst_n),
    .de (de), .frame_pulse (frame_pulse),
    .y8 (y8),
    .pixel_x (pixel_x), .pixel_y (pixel_y),
    .ean_valid (ean_valid),
    .decoded_digits (decoded_digits),
    .scan_active (scan_active)
);

always #5 clk = ~clk;

integer errors = 0;
integer px;

reg        clear_seen;
reg        seen_valid;
reg [51:0] seen_digits;

always @(posedge clk) begin
    if (clear_seen) begin
        seen_valid <= 1'b0;
    end
    else if (ean_valid) begin
        seen_valid  <= 1'b1;
        seen_digits <= decoded_digits;
    end
end

task do_reset;
begin
    rst_n = 0;
    de = 0; frame_pulse = 0;
    clear_seen = 0;
    y8 = LIGHT_Y8;
    pixel_x = 0; pixel_y = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
end
endtask

task scan_px(input color);
begin
    @(negedge clk);
    de      = 1'b1;
    pixel_y = SCAN_ROW;
    pixel_x = px[10:0];
    y8      = color ? DARK_Y8 : LIGHT_Y8;
    px      = px + 1;
end
endtask

task draw_run(input color, input integer width);
    integer k;
begin
    for (k = 0; k < width; k = k + 1)
        scan_px(color);
end
endtask

// EAN-13 "4006381333931" at 4px/module -- generated from python-barcode's
// own encoder (barcode/ean.py EuropeanArticleNumber13.build()), converted
// to a pixel run-length sequence with a small script. 460px total.
task draw_ean_row;
begin
    px = 0;
    draw_run(1'b0, 11'd40);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd12);
    draw_run(1'b1, 11'd8);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd8);
    draw_run(1'b1, 11'd12);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd16);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd16);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd12);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd8);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd8);
    draw_run(1'b0, 11'd8);
    draw_run(1'b1, 11'd8);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd16);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd16);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd16);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd12);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd8);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd16);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd8);
    draw_run(1'b0, 11'd8);
    draw_run(1'b1, 11'd8);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd4);
    draw_run(1'b1, 11'd4);
    draw_run(1'b0, 11'd40);
    // pad the rest of the row with background (real frames are 480 wide;
    // total drawn so far is 460px)
    while (px < WIDTH)
        scan_px(1'b0);
end
endtask

task bg_row(input integer y);
    integer x;
begin
    for (x = 0; x < WIDTH; x = x + 1) begin
        @(negedge clk);
        de      = 1'b1;
        pixel_x = x[10:0];
        pixel_y = y[10:0];
        y8      = LIGHT_Y8;
    end
end
endtask

task feed_frame(input draw_barcode);
    integer y;
begin
    @(negedge clk); clear_seen = 1'b1;
    @(negedge clk); clear_seen = 1'b0;
    for (y = 0; y < HEIGHT; y = y + 1) begin
        if (y == SCAN_ROW && draw_barcode)
            draw_ean_row;
        else
            bg_row(y);
    end
    @(negedge clk); de = 0;
    @(negedge clk); frame_pulse = 1;
    @(negedge clk); frame_pulse = 0;
    repeat (20) @(posedge clk);
end
endtask

// expected digits (low nibble first): 4 0 0 6 3 8 1 3 3 3 9 3 1
// (leading=4, left=006381, right=333931 where the last '1' is the check digit)
localparam [51:0] EXPECTED =
    {4'd1, 4'd3, 4'd9, 4'd3, 4'd3, 4'd3, 4'd1, 4'd8, 4'd3, 4'd6, 4'd0, 4'd0, 4'd4};

initial begin
    do_reset;

    // ---------------- Test 1: clean decode of 4006381333931 ----------------
    feed_frame(1'b1);

    $display("Test 1: seen_valid=%0d seen_digits=%013h expected=%013h",
              seen_valid, seen_digits, EXPECTED);
    if (!seen_valid) begin
        $display("FAIL: expected ean_valid to pulse during the scan");
        errors = errors + 1;
    end
    else if (seen_digits !== EXPECTED) begin
        $display("FAIL: decoded digits mismatch");
        errors = errors + 1;
    end

    // ---------------- Test 2: no barcode present -> never valid ----------------
    feed_frame(1'b0);
    $display("Test 2: after a plain background frame, seen_valid=%0d", seen_valid);
    if (seen_valid) begin
        $display("FAIL: ean_valid asserted with no barcode in the frame");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

initial begin
    #500000000;
    $display("TIMEOUT");
    $finish;
end

endmodule
