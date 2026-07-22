module lcd_pattern_top (
    input        clk,          // 50MHz (PIN_E1)
    input        rst_n,        // (PIN_N13)

    output       lcd_clk,
    output       lcd_hs,
    output       lcd_vs,
    output       lcd_de,
    output [7:0] lcd_r,
    output [7:0] lcd_g,
    output [7:0] lcd_b,

    output [3:0] led
);

// PLL (only 9MHz used here)
wire clk_100m, clk_24m, clk_9m, clk_sdram, pll_locked;
my_pll u_pll (
    .inclk0 (clk),
    .c0     (clk_100m),
    .c1     (clk_24m),
    .c2     (clk_9m),
    .c3     (clk_sdram),
    .locked (pll_locked)
);
wire sys_rst_n = rst_n & pll_locked;

// LCD driver
wire [10:0] px, py;
wire        lcd_vs_w;
reg  [7:0]  pr, pg, pb;
wire [7:0]  lcd_r_i, lcd_g_i, lcd_b_i;

lcd_driver u_lcd (
    .pclk    (clk_9m),
    .rst_n   (sys_rst_n),
    .data_r  (pr),
    .data_g  (pg),
    .data_b  (pb),
    .lcd_clk (lcd_clk),
    .lcd_hs  (lcd_hs),
    .lcd_vs  (lcd_vs_w),
    .lcd_de  (lcd_de),
    .lcd_r   (lcd_r_i),
    .lcd_g   (lcd_g_i),
    .lcd_b   (lcd_b_i),
    .pixel_x (px),
    .pixel_y (py)
);
assign lcd_vs = lcd_vs_w;

// Same bit-order fix as camera_display_top (board buses are MSB-first
// relative to qsf numbering) -- without it this test is meaningless.
genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_bitrev
        assign lcd_r[gi] = lcd_r_i[7-gi];
        assign lcd_g[gi] = lcd_g_i[7-gi];
        assign lcd_b[gi] = lcd_b_i[7-gi];
    end
endgenerate

// Screen sequencer: new screen every 256 frames (~4.4s)
reg vs_r;
reg [10:0] frame_cnt;
always @(posedge clk_9m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        vs_r      <= 1'b1;
        frame_cnt <= 11'd0;
    end
    else begin
        vs_r <= lcd_vs_w;
        if (vs_r & ~lcd_vs_w)
            frame_cnt <= frame_cnt + 1'b1;
    end
end
wire [2:0] screen = frame_cnt[10:8];

// Pattern generators
// Horizontal gradient: 0..239 over 480 px (smooth, ~2px per level)
wire [7:0] grad_h = px[8:1];

// Radial gradient around screen center (240,136)
wire signed [10:0] dx = $signed(px) - 11'sd240;
wire signed [10:0] dy = $signed(py) - 11'sd136;
wire [21:0] r2 = dx*dx + dy*dy;          // max 76096
wire [7:0] grad_r = (r2[16:8] > 9'd255) ? 8'd255 : r2[15:8];

// RGB565 quantizer (exactly what the camera path does)
function [23:0] q565;   // returns {r8,g8,b8}
    input [7:0] g;
    reg [4:0] c5;
    reg [5:0] c6;
    begin
        c5 = g[7:3];
        c6 = g[7:2];
        q565 = {{c5, c5[4:2]}, {c6, c6[5:4]}, {c5, c5[4:2]}};
    end
endfunction

// Color bars
reg [23:0] bar;
always @(*) begin
    case (px[8:6])   // 8 bars of 64px (last bar wider)
        3'd0: bar = 24'hFFFFFF;
        3'd1: bar = 24'hFFFF00;
        3'd2: bar = 24'h00FFFF;
        3'd3: bar = 24'h00FF00;
        3'd4: bar = 24'hFF00FF;
        3'd5: bar = 24'hFF0000;
        3'd6: bar = 24'h0000FF;
        default: bar = 24'h000000;
    endcase
end

// Screen mux (registered at pixel clock)
reg [23:0] q;
always @(posedge clk_9m) begin
    case (screen)
        3'd0: {pr, pg, pb} <= {grad_h, grad_h, grad_h};       // gradient 888
        3'd1: {pr, pg, pb} <= q565(grad_h);                   // gradient 565
        3'd2: {pr, pg, pb} <= {grad_r, grad_r, grad_r};       // radial 888
        3'd3: {pr, pg, pb} <= q565(grad_r);                   // radial 565
        3'd4: {pr, pg, pb} <= (py < 11'd136)
                              ? ((px[0]^py[0]) ? 24'hFFFFFF : 24'h000000)
                              : (px[0]        ? 24'hFFFFFF : 24'h000000);
        3'd5: {pr, pg, pb} <= bar;                            // color bars
        3'd6: {pr, pg, pb} <= 24'hFFFFFF;                     // white
        default: {pr, pg, pb} <= 24'h000000;                  // black
    endcase
end

// LEDs: current screen number + heartbeat
reg [22:0] hb;
always @(posedge clk_9m or negedge sys_rst_n)
    if (!sys_rst_n) hb <= 23'd0;
    else            hb <= hb + 1'b1;

assign led[2:0] = screen;
assign led[3]   = hb[22];

endmodule
