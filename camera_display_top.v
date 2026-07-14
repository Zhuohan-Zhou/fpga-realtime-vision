// camera_display_top.v -- full system integration
// OV5640 camera -> DVP capture -> SDRAM ping-pong -> AN430 LCD
//
// Clock domains:
//   50MHz  clk      : SCCB master + OV5640 init
//   27MHz  cam_pclk : DVP capture, write FIFO input
//   100MHz clk_100m : SDRAM controller + frame buffer logic
//   9MHz   clk_9m   : LCD driver, read FIFO output
module camera_display_top (
    input         clk,           // 50MHz  (PIN_E1)
    input         rst_n,         // Reset  (PIN_N13)

    // OV5640 camera
    output        cam_xclk,
    output        cam_rst_n,
    output        cam_pwdn,
    output        cam_scl,
    inout         cam_sda,
    input         cam_pclk,
    input         cam_href,
    input         cam_vsync,
    input   [7:0] cam_d,

    // AN430 LCD
    output        lcd_clk,
    output        lcd_hs,
    output        lcd_vs,
    output        lcd_de,
    output  [7:0] lcd_r,
    output  [7:0] lcd_g,
    output  [7:0] lcd_b,

    // SDRAM
    output        sdram_clk,
    output        sdram_cke,
    output        sdram_cs_n,
    output        sdram_ras_n,
    output        sdram_cas_n,
    output        sdram_we_n,
    output [12:0] sdram_addr,
    output  [1:0] sdram_ba,
    output  [1:0] sdram_dqm,
    inout  [15:0] sdram_dq,

    // Status LEDs
    output  [3:0] led,

    // Mode-select buttons (active-low)
    input         key1_n,   // Sobel edge detection
    input         key2_n,   // threshold binarization
    input         key3_n    // centroid tracking (default)
);

// PLL
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
assign cam_xclk  = clk_24m;
assign sdram_clk = clk_sdram;

// OV5640 init + SCCB (50MHz domain)
wire        sccb_start, sccb_done, sccb_busy, init_done;
wire  [7:0] sccb_dev,  sccb_data;
wire [15:0] sccb_reg;

ov5640_init u_init (
    .clk        (clk),
    .rst_n      (sys_rst_n),
    .sccb_start (sccb_start),
    .sccb_dev   (sccb_dev),
    .sccb_reg   (sccb_reg),
    .sccb_data  (sccb_data),
    .sccb_done  (sccb_done),
    .sccb_busy  (sccb_busy),
    .cam_rst_n  (cam_rst_n),
    .cam_pwdn   (cam_pwdn),
    .init_done  (init_done)
);

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

// DVP capture (pclk domain)
wire [15:0] pixel_data;
wire        pixel_valid;
wire        frame_vsync;

dvp_capture u_dvp (
    .pclk        (cam_pclk),
    .href        (cam_href),
    .vsync       (cam_vsync),
    .d           (cam_d),
    .rst_n       (sys_rst_n & init_done),
    .pixel_data  (pixel_data),
    .pixel_valid (pixel_valid),
    .frame_vsync (frame_vsync)
);

// LCD driver (9MHz domain)
wire        lcd_vs_w, lcd_de_w;
wire [15:0] lcd_pixel_565;
wire  [7:0] disp_r, disp_g, disp_b, disp_y;

wire [7:0] lcd_r_i, lcd_g_i, lcd_b_i;
wire [10:0] pixel_x_w, pixel_y_w;
wire [7:0]  ov_r, ov_g, ov_b;
wire [7:0]  final_r, final_g, final_b;

lcd_driver u_lcd (
    .pclk    (clk_9m),
    .rst_n   (sys_rst_n),
    .data_r  (final_r),
    .data_g  (final_g),
    .data_b  (final_b),
    .lcd_clk (lcd_clk),
    .lcd_hs  (lcd_hs),
    .lcd_vs  (lcd_vs_w),
    .lcd_de  (lcd_de_w),
    .lcd_r   (lcd_r_i),
    .lcd_g   (lcd_g_i),
    .lcd_b   (lcd_b_i),
    .pixel_x (pixel_x_w),
    .pixel_y (pixel_y_w)
);

// Board LCD data buses are wired MSB-first vs our qsf pin numbering, so
// reverse each channel here. Colorbar test doesn't catch this -- saturated
// colors are all-1s/all-0s per channel, look the same either way.
genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_bitrev
        assign lcd_r[gi] = lcd_r_i[7-gi];
        assign lcd_g[gi] = lcd_g_i[7-gi];
        assign lcd_b[gi] = lcd_b_i[7-gi];
    end
endgenerate

assign lcd_vs = lcd_vs_w;
assign lcd_de = lcd_de_w;

// LCD frame pulse: falling edge of VSYNC (active-low sync starts)
reg vs_r;
always @(posedge clk_9m or negedge sys_rst_n) begin
    if (!sys_rst_n) vs_r <= 1'b1;
    else            vs_r <= lcd_vs_w;
end
wire lcd_frame_pulse = vs_r & ~lcd_vs_w;

// Frame buffer: camera -> SDRAM -> LCD
frame_buffer u_fb (
    .clk_100m    (clk_100m),
    .rst_n       (sys_rst_n & init_done),

    .pclk        (cam_pclk),
    .cam_data    (pixel_data),
    .cam_valid   (pixel_valid),
    .cam_frame   (frame_vsync),

    .lclk        (clk_9m),
    .lcd_req     (lcd_de_w),
    .lcd_frame   (lcd_frame_pulse),
    .lcd_data    (lcd_pixel_565),

    .sdram_cke   (sdram_cke),
    .sdram_cs_n  (sdram_cs_n),
    .sdram_ras_n (sdram_ras_n),
    .sdram_cas_n (sdram_cas_n),
    .sdram_we_n  (sdram_we_n),
    .sdram_addr  (sdram_addr),
    .sdram_ba    (sdram_ba),
    .sdram_dqm   (sdram_dqm),
    .sdram_dq    (sdram_dq)
);

// YUV422 -> RGB888. Sensor outputs YUV422 now (8-bit luma, 256 gray levels
// vs RGB565's 32/64), which is what killed the concentric banding.
yuv422_to_rgb888 u_conv (
    .clk   (clk_9m),
    .rst_n (sys_rst_n),
    .de    (lcd_de_w),
    .yc    (lcd_pixel_565),   // 16-bit words, now {Y,U}/{Y,V} pairs
    .r8    (disp_r),
    .g8    (disp_g),
    .b8    (disp_b),
    .y8    (disp_y)
);

// Motion detector (16x16-cell frame differencing)
wire       motion_highlight_w, motion_detected_w;
wire [8:0] motion_blocks_w;    // hook up to SignalTap for tuning

motion_detector u_motion (
    .clk             (clk_9m),
    .rst_n           (sys_rst_n),
    .de              (lcd_de_w),
    .frame_pulse     (lcd_frame_pulse),
    .y8              (disp_y),
    .pixel_x         (pixel_x_w),
    .pixel_y         (pixel_y_w),
    .highlight       (motion_highlight_w),
    .motion_detected (motion_detected_w),
    .changed_blocks  (motion_blocks_w)
);

wire [7:0] mo_r, mo_g, mo_b;

// Gate the per-cell highlight with the frame-level motion_detected flag
// (>= MIN_BLOCKS cells changed together) so a single cell tripped by sensor
// noise/AEC/flicker never lights up alone. Costs one frame of latency,
// not noticeable at video rate.
wire motion_highlight_gated = motion_highlight_w & motion_detected_w;

motion_overlay u_motion_ov (
    .highlight (motion_highlight_gated),
    .in_r      (disp_r),
    .in_g      (disp_g),
    .in_b      (disp_b),
    .out_r     (mo_r),
    .out_g     (mo_g),
    .out_b     (mo_b)
);

// Color-threshold blob tracker (centroid of matching pixels).
// R_LO..B_HI defaults live in color_blob_tracker.v, tune for whatever
// object color you're tracking.
wire        blob_found_w, blob_cx_valid_w;
wire [10:0] blob_cx_w, blob_cy_w;
wire [17:0] blob_pixels_w;   // hook up to SignalTap to tune thresholds

color_blob_tracker u_blob (
    .clk         (clk_9m),
    .rst_n       (sys_rst_n),
    .de          (lcd_de_w),
    .frame_pulse (lcd_frame_pulse),
    .r8          (disp_r),
    .g8          (disp_g),
    .b8          (disp_b),
    .pixel_x     (pixel_x_w),
    .pixel_y     (pixel_y_w),
    .cx          (blob_cx_w),
    .cy          (blob_cy_w),
    .blob_found  (blob_found_w),
    .cx_valid    (blob_cx_valid_w),
    .blob_pixels (blob_pixels_w)
);

// Crosshair overlay at the tracked centroid
overlay_marker u_overlay (
    .pixel_x    (pixel_x_w),
    .pixel_y    (pixel_y_w),
    .cx         (blob_cx_w),
    .cy         (blob_cy_w),
    .blob_found (blob_found_w),
    .in_r       (mo_r),
    .in_g       (mo_g),
    .in_b       (mo_b),
    .out_r      (ov_r),
    .out_g      (ov_g),
    .out_b      (ov_b)
);

// Display mode select (3 buttons): key1 -> Sobel, key2 -> threshold
// binarize, key3 -> centroid tracking (default). All three paths run
// continuously in parallel -- cheap enough, and avoids clock-enable/reset
// gymnastics -- only the final mux picks what actually reaches the screen.
//
// Sobel disabled for now -- didn't fit (858/645 LABs) even after forcing
// M9K ramstyle on the line buffers. Instance below is commented out rather
// than removed so it's easy to bring back once the LAB overflow is sorted;
// sobel_edge.v itself is unchanged. To re-enable: uncomment the instance,
// restore the mux, re-add the VERILOG_FILE line in the qsf.
wire [1:0] disp_mode;

display_mode_select u_mode (
    .clk    (clk_9m),
    .rst_n  (sys_rst_n),
    .key1_n (key1_n),
    .key2_n (key2_n),
    .key3_n (key3_n),
    .mode   (disp_mode)
);

wire [7:0] sobel_r, sobel_g, sobel_b;
assign sobel_r = ov_r;   // placeholder while Sobel is disabled -- see note above
assign sobel_g = ov_g;
assign sobel_b = ov_b;

// sobel_edge u_sobel (
//     .clk     (clk_9m),
//     .rst_n   (sys_rst_n),
//     .de      (lcd_de_w),
//     .y8      (disp_y),
//     .pixel_x (pixel_x_w),
//     .pixel_y (pixel_y_w),
//     .edge_r  (sobel_r),
//     .edge_g  (sobel_g),
//     .edge_b  (sobel_b)
// );

wire [7:0] bin_r, bin_g, bin_b;

threshold_binarize u_binarize (
    .y8    (disp_y),
    .bin_r (bin_r),
    .bin_g (bin_g),
    .bin_b (bin_b)
);

localparam [1:0] MODE_TRACKING = 2'd0,
                  MODE_SOBEL    = 2'd1,
                  MODE_BINARIZE = 2'd2;

assign final_r = (disp_mode == MODE_SOBEL)    ? sobel_r :
                  (disp_mode == MODE_BINARIZE) ? bin_r   : ov_r;
assign final_g = (disp_mode == MODE_SOBEL)    ? sobel_g :
                  (disp_mode == MODE_BINARIZE) ? bin_g   : ov_g;
assign final_b = (disp_mode == MODE_SOBEL)    ? sobel_b :
                  (disp_mode == MODE_BINARIZE) ? bin_b   : ov_b;

// LEDs
reg cam_frame_led;
always @(posedge cam_pclk or negedge sys_rst_n) begin
    if (!sys_rst_n)        cam_frame_led <= 1'b0;
    else if (frame_vsync)  cam_frame_led <= ~cam_frame_led;
end

assign led[0] = init_done;       // camera configured
assign led[1] = pll_locked;      // clocks alive
assign led[2] = cam_frame_led;   // camera frames arriving
assign led[3] = ~lcd_vs_w;       // LCD frames being generated

endmodule
