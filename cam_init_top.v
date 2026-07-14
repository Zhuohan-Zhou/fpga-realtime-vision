// cam_init_top.v -- OV5640 init test top. PLL -> ov5640_init -> CameraCapture (SCCB master).
// After download, init_done LED should come on after ~3s.
module cam_init_top (
    input        clk,           // 50MHz system clock  (PIN_E1)
    input        rst_n,         // Reset button         (PIN_N13)

    // OV5640 camera control pins
    output       cam_xclk,      // 24MHz clock to OV5640 (PIN_K2)
    output       cam_rst_n,     // OV5640 RESET          (PIN_N6)
    output       cam_pwdn,      // OV5640 PWDN           (PIN_M7)
    output       cam_scl,       // SCCB SCL              (PIN_F1)
    inout        cam_sda,       // SCCB SDA              (PIN_F3)

    // Status LEDs
    output [3:0] led            // LED[0]=init_done, LED[3:1]=state indicator
);

// PLL: 50MHz → 100MHz(c0) / 24MHz(c1) / 9MHz(c2)
wire clk_100m, clk_24m, clk_9m, pll_locked;

my_pll u_pll (
    .inclk0 (clk),
    .c0     (clk_100m),
    .c1     (clk_24m),
    .c2     (clk_9m),
    .locked (pll_locked)
);

// System reset: hold until PLL locked
wire sys_rst_n = rst_n & pll_locked;

// 24MHz clock to camera XCLK pin
assign cam_xclk = clk_24m;

// SCCB master interface wires
wire        sccb_start;
wire [7:0]  sccb_dev;
wire [15:0] sccb_reg;
wire [7:0]  sccb_data;
wire        sccb_done;
wire        sccb_busy;

// OV5640 initialization controller
wire        init_done;
wire        init_cam_rst_n;
wire        init_cam_pwdn;

ov5640_init u_ov5640_init (
    .clk         (clk),          // use 50MHz for delay counters
    .rst_n       (sys_rst_n),
    .sccb_start  (sccb_start),
    .sccb_dev    (sccb_dev),
    .sccb_reg    (sccb_reg),
    .sccb_data   (sccb_data),
    .sccb_done   (sccb_done),
    .sccb_busy   (sccb_busy),
    .cam_rst_n   (init_cam_rst_n),
    .cam_pwdn    (init_cam_pwdn),
    .init_done   (init_done)
);

// Drive camera control pins from init controller
assign cam_rst_n = init_cam_rst_n;
assign cam_pwdn  = init_cam_pwdn;

// SCCB master (CameraCapture)
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

// LED status indicators
// LED[0]: init_done  (stays ON after all registers written)
// LED[1]: pll_locked (ON immediately after power-up)
// LED[2]: sccb_busy  (blinks rapidly during init sequence)
// LED[3]: cam_rst_n  (ON after reset released)
assign led[0] = init_done;
assign led[1] = pll_locked;
assign led[2] = sccb_busy;
assign led[3] = init_cam_rst_n;

endmodule