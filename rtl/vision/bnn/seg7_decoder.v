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
