module dvp_test_top (
    input        clk,           // 50MHz  (PIN_E1)
    input        rst_n,         // Reset  (PIN_N13)

    // OV5640 camera pins
    output       cam_xclk,      // 24MHz  (PIN_K2)
    output       cam_rst_n,     // RESET  (PIN_N6)
    output       cam_pwdn,      // PWDN   (PIN_M7)
    output       cam_scl,       // SCL    (PIN_F1)
    inout        cam_sda,       // SDA    (PIN_F3)
    input        cam_pclk,      // PCLK   (PIN_G1)
    input        cam_href,      // HREF   (PIN_K1)
    input        cam_vsync,     // VSYNC  (PIN_F2)
    input  [7:0] cam_d,         // D[7:0] (PIN_J2~L2)

    // Status LEDs
    output [3:0] led
);

// PLL
wire clk_100m, clk_24m, clk_9m, pll_locked;

my_pll u_pll (
    .inclk0 (clk),
    .c0     (clk_100m),
    .c1     (clk_24m),
    .c2     (clk_9m),
    .locked (pll_locked)
);

wire sys_rst_n = rst_n & pll_locked;
assign cam_xclk = clk_24m;

// SCCB wires
wire        sccb_start;
wire [7:0]  sccb_dev;
wire [15:0] sccb_reg;
wire [7:0]  sccb_data;
wire        sccb_done;
wire        sccb_busy;
wire        init_done;
wire        init_cam_rst_n;
wire        init_cam_pwdn;

assign cam_rst_n = init_cam_rst_n;
assign cam_pwdn  = init_cam_pwdn;

// OV5640 init controller
ov5640_init u_init (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .sccb_start (sccb_start),
    .sccb_dev   (sccb_dev),
    .sccb_reg   (sccb_reg),
    .sccb_data  (sccb_data),
    .sccb_done  (sccb_done),
    .sccb_busy  (sccb_busy),
    .cam_rst_n  (init_cam_rst_n),
    .cam_pwdn   (init_cam_pwdn),
    .init_done  (init_done)
);

// SCCB master
CameraCapture u_sccb (
    .clk      (clk),
    .rst_n    (sys_rst_n),
    .start    (sccb_start),
    .dev_addr (sccb_dev),
    .reg_addr (sccb_reg),
    .reg_data (sccb_data),
    .sccb_scl (cam_scl),
    .sccb_sda (cam_sda),
    .busy     (sccb_busy),
    .done     (sccb_done)
);

// DVP capture (only active after init done)
wire [15:0] pixel_data;
wire        pixel_valid;
wire        frame_vsync;

dvp_capture u_dvp (
    .pclk        (cam_pclk),
    .href        (cam_href),
    .vsync       (cam_vsync),
    .d           (cam_d),
    .rst_n       (sys_rst_n & init_done),  // wait for init before capturing
    .pixel_data  (pixel_data),
    .pixel_valid (pixel_valid),
    .frame_vsync (frame_vsync)
);

// pixel counter -- should land on 480x272 = 130,560 per frame
reg [17:0] pixel_cnt       /* synthesis noprune */; // counts pixels in current frame
reg [17:0] pixel_cnt_latch /* synthesis noprune */; // latched at end of frame (for SignalTap)

always @(posedge cam_pclk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        pixel_cnt       <= 18'd0;
        pixel_cnt_latch <= 18'd0;
    end
    else begin
        if (frame_vsync) begin
            // New frame: latch previous count, reset counter
            pixel_cnt_latch <= pixel_cnt;
            pixel_cnt       <= 18'd0;
        end
        else if (pixel_valid)
            pixel_cnt <= pixel_cnt + 1'b1;
    end
end

// LEDs
// LED[0]: init_done
// LED[1]: pll_locked
// LED[2]: frame_vsync blink (slow toggle on each frame)
// LED[3]: pixel_valid activity

reg led2_toggle;
always @(posedge cam_pclk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        led2_toggle <= 1'b0;
    else if (frame_vsync)
        led2_toggle <= ~led2_toggle;
end

assign led[0] = init_done;
assign led[1] = pll_locked;
assign led[2] = led2_toggle;   // toggles at 30fps → visible flicker
assign led[3] = pixel_valid;   // blinks during active lines

endmodule