// seg7_decoder.v -- digit (0-9) -> 7-segment pattern, for the LG3661BH tube.
//
// User-confirmed hardware: LG3661BH is COMMON ANODE, and segment pins are
// ACTIVE-LOW (pin driven low = that segment lights; high = off). Default
// ACTIVE_LOW=1 matches that; set to 0 if this is ever reused on a
// common-cathode display instead.
//
// Segment bit order: seg[6:0] = {a, b, c, d, e, f, g} (seg[6]=a .. seg[0]=g),
// standard layout:
//        a
//      f   b
//        g
//      e   c
//        d
//
// digit_valid gates the output: when low, all segments are forced OFF
// (blank display) rather than showing a stale/garbage digit -- e.g. before
// the first camera-fed classification has completed.
module seg7_decoder #(
    parameter ACTIVE_LOW = 1
)(
    input        [3:0] digit,        // 0-9; values 10-15 are treated as blank
    input              digit_valid,
    output       [6:0] seg,          // {a,b,c,d,e,f,g}
    output             dp            // decimal point, always off
);

reg [6:0] pattern;   // active-HIGH internally: 1 = segment on

always @* begin
    case (digit)
        4'd0: pattern = 7'b1111110;
        4'd1: pattern = 7'b0110000;
        4'd2: pattern = 7'b1101101;
        4'd3: pattern = 7'b1111001;
        4'd4: pattern = 7'b0110011;
        4'd5: pattern = 7'b1011011;
        4'd6: pattern = 7'b1011111;
        4'd7: pattern = 7'b1110000;
        4'd8: pattern = 7'b1111111;
        4'd9: pattern = 7'b1111011;
        default: pattern = 7'b0000000;   // blank
    endcase
end

wire [6:0] pattern_gated = digit_valid ? pattern : 7'b0000000;

assign seg = ACTIVE_LOW ? ~pattern_gated : pattern_gated;
assign dp  = ACTIVE_LOW ? 1'b1 : 1'b0;   // decimal point always off

endmodule
