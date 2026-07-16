`timescale 1ns/1ps
// Functional testbench for seg7_decoder.v. Checks all 10 digit patterns
// against the standard 7-seg table (active-HIGH reference, a..g), then
// verifies the ACTIVE_LOW=1 instance (the real LG3661BH config: common
// anode, segment=0 lights) inverts correctly, and that digit_valid=0
// blanks the display (all segments off) regardless of digit.
module tb_seg7_decoder;

reg [3:0] digit;
reg       digit_valid;
wire [6:0] seg_active_low;
wire       dp_active_low;
wire [6:0] seg_active_high;
wire       dp_active_high;

seg7_decoder #(.ACTIVE_LOW(1)) dut_low (
    .digit       (digit),
    .digit_valid (digit_valid),
    .seg         (seg_active_low),
    .dp          (dp_active_low)
);

seg7_decoder #(.ACTIVE_LOW(0)) dut_high (
    .digit       (digit),
    .digit_valid (digit_valid),
    .seg         (seg_active_high),
    .dp          (dp_active_high)
);

// reference table, active-HIGH convention {a,b,c,d,e,f,g}
reg [6:0] expected [0:9];
integer errors = 0;
integer i;

initial begin
    expected[0] = 7'b1111110;
    expected[1] = 7'b0110000;
    expected[2] = 7'b1101101;
    expected[3] = 7'b1111001;
    expected[4] = 7'b0110011;
    expected[5] = 7'b1011011;
    expected[6] = 7'b1011111;
    expected[7] = 7'b1110000;
    expected[8] = 7'b1111111;
    expected[9] = 7'b1111011;
end

initial begin
    digit_valid = 1'b1;

    for (i = 0; i < 10; i = i + 1) begin
        digit = i[3:0];
        #10;
        if (seg_active_high !== expected[i]) begin
            $display("FAIL digit=%0d active-high: expected %b got %b", i, expected[i], seg_active_high);
            errors = errors + 1;
        end
        if (seg_active_low !== ~expected[i]) begin
            $display("FAIL digit=%0d active-low: expected %b got %b", i, ~expected[i], seg_active_low);
            errors = errors + 1;
        end
        if (dp_active_low !== 1'b1) begin
            $display("FAIL digit=%0d: dp_active_low expected 1 (off) got %b", i, dp_active_low);
            errors = errors + 1;
        end
        if (dp_active_high !== 1'b0) begin
            $display("FAIL digit=%0d: dp_active_high expected 0 (off) got %b", i, dp_active_high);
            errors = errors + 1;
        end
    end
    $display("Digit patterns 0-9: checked against standard table (active-high and active-low)");

    // digit_valid=0 -> blank regardless of digit
    digit = 4'd7;
    digit_valid = 1'b0;
    #10;
    if (seg_active_high !== 7'b0000000) begin
        $display("FAIL blank active-high: expected 0000000 got %b", seg_active_high);
        errors = errors + 1;
    end
    if (seg_active_low !== 7'b1111111) begin
        $display("FAIL blank active-low: expected 1111111 (all off) got %b", seg_active_low);
        errors = errors + 1;
    end
    $display("digit_valid=0 blanking: checked");

    // out-of-range digit (e.g. 12) also blanks
    digit = 4'd12;
    digit_valid = 1'b1;
    #10;
    if (seg_active_high !== 7'b0000000) begin
        $display("FAIL out-of-range digit active-high: expected 0000000 got %b", seg_active_high);
        errors = errors + 1;
    end
    $display("Out-of-range digit (12): checked");

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

endmodule
