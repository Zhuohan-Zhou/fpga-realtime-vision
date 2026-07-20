// yuv422_to_rgb888.v -- streaming YUV422 (YUYV) -> RGB888 for the LCD path.
//
// Input: one 16-bit word per 'de' clock from the read FIFO, alternating
//   {Y0,U} , {Y1,V}  (dvp_capture packs {1st,2nd} byte)
// Output: RGB888 pixel, 1-pixel latency (image shifts 1px, harmless)
//
// Math (BT.601, fixed point <<8):
//   R = Y + 1.402(V-128)          = Y + (359*Cr >> 8)
//   G = Y - 0.344(U-128) - 0.714(V-128) = Y - (88*Cb + 183*Cr >> 8)
//   B = Y + 1.772(U-128)          = Y + (454*Cb >> 8)
module yuv422_to_rgb888 (
    input             clk,      // LCD pixel clock
    input             rst_n,
    input             de,       // pixel strobe (FIFO word valid)
    input      [15:0] yc,       // {Y, chroma} current word
    output reg  [7:0] r8,
    output reg  [7:0] g8,
    output reg  [7:0] b8,
    output reg  [7:0] y8        // luma of the pixel on r8/g8/b8 this cycle (same
                                 // latency) -- for motion detection etc. downstream
                                 // without redoing the YUV math
);

reg       phase;                // 0: expect {Y0,U}, 1: expect {Y1,V}
reg [7:0] y0, y1, ur, vr;

// clip helper
function [7:0] clip;
    input signed [19:0] t;      // Y<<8 + weighted chroma
    begin
        if (t < 0)                clip = 8'd0;
        else if (t > 20'sd65280)  clip = 8'd255;   // 255<<8
        else                      clip = t[15:8];
    end
endfunction

// converter
function [23:0] conv;
    input [7:0] y;
    input [7:0] u;
    input [7:0] v;
    reg signed [9:0]  cb, cr;
    reg signed [19:0] yy, rt, gt, bt;
    begin
        cb = $signed({2'b00, u}) - 10'sd128;
        cr = $signed({2'b00, v}) - 10'sd128;
        yy = {4'b0000, y, 8'd0};                    // Y << 8
        rt = yy + cr * 10'sd359;
        gt = yy - cb * 10'sd88 - cr * 10'sd183;
        bt = yy + cb * 10'sd454;
        conv = {clip(rt), clip(gt), clip(bt)};
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase <= 1'b0;
        y0 <= 8'd0; y1 <= 8'd0; ur <= 8'd128; vr <= 8'd128;
        r8 <= 8'd0; g8 <= 8'd0; b8 <= 8'd0; y8 <= 8'd0;
    end
    else if (de) begin
        if (!phase) begin
            // word {Y0,U}: latch, output SECOND pixel of previous pair
            y0    <= yc[15:8];
            ur    <= yc[7:0];
            phase <= 1'b1;
            {r8, g8, b8} <= conv(y1, ur, vr);
            y8    <= y1;
        end
        else begin
            // word {Y1,V}: V just arrived -> output FIRST pixel of pair
            y1    <= yc[15:8];
            vr    <= yc[7:0];
            phase <= 1'b0;
            {r8, g8, b8} <= conv(y0, ur, yc[7:0]);
            y8    <= y0;
        end
    end
    else
        phase <= 1'b0;          // re-sync pairing at line boundaries
end

endmodule
