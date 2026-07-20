module lcd_top (
    input        clk,          // 50MHz system clock (PIN_E1)
    input        rst_n,        // Reset button (PIN_N13, active low)

    // AN430 LCD interface (connected to J1 expansion port)
    output       lcd_clk,      // PIN_T2   LCD_DCLK
    output       lcd_hs,       // PIN_M9   LCD_HSYNC
    output       lcd_vs,       // PIN_L10  LCD_VSYNC
    output       lcd_de,       // PIN_L9   LCD_DE
    output [7:0] lcd_r,        // PIN_R10~T14  LCD_R[7:0]
    output [7:0] lcd_g,        // PIN_R6~T10   LCD_G[7:0]
    output [7:0] lcd_b         // PIN_P3~T6    LCD_B[7:0]
);

wire clk_9m;
wire clk_100m;
wire clk_24m;
wire pll_locked;

my_pll u_pll (
    .inclk0 (clk),
    .c0     (clk_100m),   // 100MHz (unused in this module)
    .c1     (clk_24m),    // 24MHz  (unused in this module)
    .c2     (clk_9m),     // 9MHz   → LCD pixel clock
    .locked (pll_locked)
);

// Use PLL locked signal as system reset:
// Before PLL locks, the whole design stays in reset.
// After PLL locks, the system starts running.
wire sys_rst_n = rst_n & pll_locked;

wire [10:0] pixel_x;    // current pixel column (0~479), valid when lcd_de=1
wire [10:0] pixel_y;    // current pixel row    (0~271), valid when lcd_de=1

wire [7:0]  bar_r;
wire [7:0]  bar_g;
wire [7:0]  bar_b;

lcd_driver u_lcd_driver (
    .pclk    (clk_9m),
    .rst_n   (sys_rst_n),
    .data_r  (bar_r),
    .data_g  (bar_g),
    .data_b  (bar_b),
    .lcd_clk (lcd_clk),
    .lcd_hs  (lcd_hs),
    .lcd_vs  (lcd_vs),
    .lcd_de  (lcd_de),
    .lcd_r   (lcd_r),
    .lcd_g   (lcd_g),
    .lcd_b   (lcd_b),
    .pixel_x (pixel_x),
    .pixel_y (pixel_y)
);


assign {bar_r, bar_g, bar_b} =
    (pixel_x < 11'd80)  ? {8'hFF, 8'h00, 8'h00} :  // Red
    (pixel_x < 11'd160) ? {8'h00, 8'hFF, 8'h00} :  // Green
    (pixel_x < 11'd240) ? {8'h00, 8'h00, 8'hFF} :  // Blue
    (pixel_x < 11'd320) ? {8'hFF, 8'hFF, 8'h00} :  // Yellow
    (pixel_x < 11'd400) ? {8'h00, 8'hFF, 8'hFF} :  // Cyan
                          {8'hFF, 8'hFF, 8'hFF};    // White

endmodule