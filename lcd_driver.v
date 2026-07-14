module lcd_driver (
    input             pclk,      // 9MHz pixel clock (from PLL)
    input             rst_n,     // reset (connect to PLL locked signal)
 
    // Pixel data input from colorbar or frame buffer
    input  [7:0]      data_r,
    input  [7:0]      data_g,
    input  [7:0]      data_b,
 
    // AN430 LCD hardware interface
    output            lcd_clk,   // pixel clock to LCD
    output reg        lcd_hs,    // HSYNC (active low)
    output reg        lcd_vs,    // VSYNC (active low)
    output reg        lcd_de,    // Data Enable (active high)
    output [7:0]      lcd_r,     // Red   8-bit
    output [7:0]      lcd_g,     // Green 8-bit
    output [7:0]      lcd_b,     // Blue  8-bit
 
    // Pixel coordinates for data generation (valid when lcd_de = 1)
    output reg [10:0] pixel_x,   // 0 ~ 479
    output reg [10:0] pixel_y    // 0 ~ 271
);
 

localparam H_SYNC  = 11'd41;
localparam H_BACK  = 11'd2;
localparam H_DISP  = 11'd480;
localparam H_FRONT = 11'd2;
localparam H_TOTAL = 11'd525;   // H_SYNC + H_BACK + H_DISP + H_FRONT
 
localparam V_SYNC  = 11'd10;
localparam V_BACK  = 11'd2;
localparam V_DISP  = 11'd272;
localparam V_FRONT = 11'd2;
localparam V_TOTAL = 11'd286;   // V_SYNC + V_BACK + V_DISP + V_FRONT
 
// Active display start positions
localparam H_ACT_START = H_SYNC + H_BACK;           // = 43
localparam H_ACT_END   = H_SYNC + H_BACK + H_DISP;  // = 523
localparam V_ACT_START = V_SYNC + V_BACK;            // = 12
localparam V_ACT_END   = V_SYNC + V_BACK + V_DISP;  // = 284
 

reg [10:0] h_cnt;
reg [10:0] v_cnt;
 
always @(posedge pclk or negedge rst_n) begin
    if (!rst_n)
        h_cnt <= 11'd0;
    else if (h_cnt == H_TOTAL - 1'b1)
        h_cnt <= 11'd0;
    else
        h_cnt <= h_cnt + 1'b1;
end
 
always @(posedge pclk or negedge rst_n) begin
    if (!rst_n)
        v_cnt <= 11'd0;
    else if (h_cnt == H_TOTAL - 1'b1) begin
        if (v_cnt == V_TOTAL - 1'b1)
            v_cnt <= 11'd0;
        else
            v_cnt <= v_cnt + 1'b1;
    end
end
 

wire h_active = (h_cnt >= H_ACT_START) && (h_cnt < H_ACT_END);
wire v_active = (v_cnt >= V_ACT_START) && (v_cnt < V_ACT_END);
 

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        lcd_hs  <= 1'b1;
        lcd_vs  <= 1'b1;
        lcd_de  <= 1'b0;
        pixel_x <= 11'd0;
        pixel_y <= 11'd0;
    end
    else begin
        // HSYNC: low during sync pulse (first H_SYNC clocks of each line)
        lcd_hs <= (h_cnt < H_SYNC) ? 1'b0 : 1'b1;
 
        // VSYNC: low during sync pulse (first V_SYNC lines of each frame)
        lcd_vs <= (v_cnt < V_SYNC) ? 1'b0 : 1'b1;
 
        // DE: high only in the active display window
        lcd_de <= h_active && v_active;
 
        // Pixel coordinates within the active window
        pixel_x <= h_active ? (h_cnt - H_ACT_START) : 11'd0;
        pixel_y <= v_active ? (v_cnt - V_ACT_START)  : 11'd0;
    end
end
 

assign lcd_r   = lcd_de ? data_r : 8'd0;
assign lcd_g   = lcd_de ? data_g : 8'd0;
assign lcd_b   = lcd_de ? data_b : 8'd0;
 
// Pixel clock: pass-through (FPGA drives LCD_DCLK directly)
assign lcd_clk = pclk;
 
endmodule