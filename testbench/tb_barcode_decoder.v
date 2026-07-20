`timescale 1ns/1ps
// Functional testbench for barcode_decoder.v.
// Streams a synthetic Code 39 barcode encoding "*42*" on the fixed scan
// row, built from the verified narrow/wide run-length sequence (see
// CLAUDE.md / session notes -- widths cross-checked against python-barcode's
// reference table). Checks a clean decode of digits [4, 2], then checks a
// second, barcode-free frame never asserts barcode_valid.
module tb_barcode_decoder;

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

wire barcode_valid;
wire [3:0] digit_count;
wire [31:0] decoded_digits;
wire scan_active;

barcode_decoder #(
    .SCAN_ROW    (SCAN_ROW),
    .THRESH      (8'd128),
    .WIDE_THRESH (11'd12),
    .MAX_DIGITS  (4'd8)
) dut (
    .clk (clk), .rst_n (rst_n),
    .de (de), .frame_pulse (frame_pulse),
    .y8 (y8),
    .pixel_x (pixel_x), .pixel_y (pixel_y),
    .barcode_valid (barcode_valid),
    .digit_count (digit_count),
    .decoded_digits (decoded_digits),
    .scan_active (scan_active)
);

always #5 clk = ~clk;

integer errors = 0;
integer px;

// latch whatever the decoder reports during a frame. Cleared explicitly via
// clear_seen (pulsed by the testbench right before each new frame starts,
// not by the DUT's frame_pulse -- frame_pulse fires as an END-of-frame
// marker in this harness, i.e. AFTER the scan row that produced the pulse
// we want to check, so clearing on frame_pulse would wipe out the very
// result we're trying to observe).
reg        clear_seen;
reg        seen_valid;
reg [3:0]  seen_count;
reg [31:0] seen_digits;

always @(posedge clk) begin
    if (clear_seen) begin
        seen_valid <= 1'b0;
    end
    else if (barcode_valid) begin
        seen_valid  <= 1'b1;
        seen_count  <= digit_count;
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

// the exact run sequence for "*42*": (color, width_px) pairs, generated
// from the verified Code 39 patterns at NARROW_PX=6 / WIDE_PX=18 /
// GAP_PX=6, with 40px quiet zones front and back. Total 458px.
task draw_barcode_row;
begin
    px = 0;
    draw_run(1'b0, 11'd40);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd18);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd18);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd18);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd18);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd18);
    draw_run(1'b0, 11'd6);
    draw_run(1'b1, 11'd6);
    draw_run(1'b0, 11'd40);
    // pad the rest of the row with background (real frames are 480 wide;
    // total drawn so far is 458px)
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

// one full frame; draw_barcode selects whether the scan row carries the
// barcode pattern or is just plain background (negative-case test)
task feed_frame(input draw_barcode);
    integer y;
begin
    @(negedge clk); clear_seen = 1'b1;
    @(negedge clk); clear_seen = 1'b0;
    for (y = 0; y < HEIGHT; y = y + 1) begin
        if (y == SCAN_ROW && draw_barcode)
            draw_barcode_row;
        else
            bg_row(y);
    end
    @(negedge clk); de = 0;
    @(negedge clk); frame_pulse = 1;
    @(negedge clk); frame_pulse = 0;
    repeat (20) @(posedge clk);
end
endtask

initial begin
    do_reset;

    // ---------------- Test 1: clean decode of "*42*" ----------------
    feed_frame(1'b1);

    $display("Test 1: seen_valid=%0d seen_count=%0d seen_digits=%0h",
              seen_valid, seen_count, seen_digits);
    if (!seen_valid) begin
        $display("FAIL: expected barcode_valid to pulse during the scan");
        errors = errors + 1;
    end
    else begin
        if (seen_count !== 4'd2) begin
            $display("FAIL: expected digit_count=2, got %0d", seen_count);
            errors = errors + 1;
        end
        if (seen_digits[3:0] !== 4'd4) begin
            $display("FAIL: expected first digit=4, got %0d", seen_digits[3:0]);
            errors = errors + 1;
        end
        if (seen_digits[7:4] !== 4'd2) begin
            $display("FAIL: expected second digit=2, got %0d", seen_digits[7:4]);
            errors = errors + 1;
        end
    end

    // ---------------- Test 2: no barcode present -> never valid ----------------
    feed_frame(1'b0);
    $display("Test 2: after a plain background frame, seen_valid=%0d", seen_valid);
    if (seen_valid) begin
        $display("FAIL: barcode_valid asserted with no barcode in the frame");
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
