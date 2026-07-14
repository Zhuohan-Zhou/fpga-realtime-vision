module rgb565_to_rgb888 (
    input  [15:0] rgb565,   // packed RGB565 from DVP capture module

    output [7:0]  r8,       // Red   channel for LCD (LCD_R[7:0])
    output [7:0]  g8,       // Green channel for LCD (LCD_G[7:0])
    output [7:0]  b8        // Blue  channel for LCD (LCD_B[7:0])
);

// Extract individual channels from packed pixel
wire [4:0] r5 = rgb565[15:11];
wire [5:0] g6 = rgb565[10:5];
wire [4:0] b5 = rgb565[4:0];

// Expand to 8-bit by replicating MSBs into the vacant low bits
assign r8 = {r5, r5[4:2]};   // [7:3]=r5, [2:0]=r5[4:2]
assign g8 = {g6, g6[5:4]};   // [7:2]=g6, [1:0]=g6[5:4]
assign b8 = {b5, b5[4:2]};   // [7:3]=b5, [2:0]=b5[4:2]

endmodule