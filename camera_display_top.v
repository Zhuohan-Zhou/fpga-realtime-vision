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
    input         key3_n,   // centroid tracking (default)

    // LG3661BH 7-segment digit display -- BNN handwritten-digit output.
    // Common anode, active-low segment drive (user-confirmed): seg[6:0] =
    // {a,b,c,d,e,f,g}, driven low to light a segment. This runs as an
    // always-on background classifier independent of the key1/2/3 mode
    // mux above -- it doesn't touch final_r/g/b or disp_mode at all, see
    // the BNN camera pipeline block near the end of this file.
    // NOT YET PIN-ASSIGNED in the qsf -- see the comment there. Physical
    // wiring to the LG3661BH still needs to be confirmed before this does
    // anything on real hardware; leaving the ports here now so the logic
    // is in place and ready the moment pins are known.
    output  [6:0] seg7,
    output        seg7_dp
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

// Motion detector removed from this path (per user request): it never fed
// into the tracker anyway, just an independent yellow-tint overlay
// composited alongside it. Module files (motion_detector.v/motion_overlay.v)
// are kept in the repo and still buildable via their own instance
// elsewhere if wanted later, just not instantiated here -- also frees up
// whatever LAB/M9K they were using.

// Color-threshold blob tracker (centroid of matching pixels), now with
// Kalman-filtered position/velocity + outlier rejection instead of plain
// EMA smoothing -- see color_blob_tracker.v's header for why. R_LO..B_HI
// defaults live in color_blob_tracker.v, tune for whatever object color
// you're tracking.
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

// Crosshair overlay at the tracked centroid, straight over the live image
// now (used to go through motion_overlay's tint first).
overlay_marker u_overlay (
    .pixel_x    (pixel_x_w),
    .pixel_y    (pixel_y_w),
    .cx         (blob_cx_w),
    .cy         (blob_cy_w),
    .blob_found (blob_found_w),
    .in_r       (disp_r),
    .in_g       (disp_g),
    .in_b       (disp_b),
    .out_r      (ov_r),
    .out_g      (ov_g),
    .out_b      (ov_b)
);

// Display mode select (3 buttons): key1 -> Sobel, key2 -> threshold
// binarize, key3 -> centroid tracking (default). All three paths run
// continuously in parallel -- cheap enough, and avoids clock-enable/reset
// gymnastics -- only the final mux picks what actually reaches the screen.
//
// Sobel re-enabled: the LAB overflow (858/645) was actually caused by
// sobel_edge.v's and motion_detector.v's memory reads being coded as
// combinational (`wire = arr[idx]`), which can't map to M9K regardless of
// ramstyle since M9K's read port is physically synchronous-only -- Quartus
// was building an LE-based fake memory instead. Both modules now use
// registered reads. Re-verify the LAB count after this recompile.
wire [1:0] disp_mode;

display_mode_select u_mode (
    .clk    (clk_9m),
    .rst_n  (sys_rst_n),
    .key1_n (key1_n),
    .key2_n (key2_n),
    .key3_n (key3_n),
    .mode   (disp_mode)
);

// Gaussian blur ahead of Sobel: a bare gradient-magnitude threshold makes
// an independent edge/no-edge call at every pixel, so any spot where local
// contrast dips even briefly (sensor noise, soft lighting) breaks the
// line -- smoothing first is the same reason a real Canny pipeline blurs
// before it differentiates.
wire [7:0]  blur_y8;
wire [10:0] blur_px, blur_py;
wire        blur_de;

gaussian_blur3x3 u_blur (
    .clk         (clk_9m),
    .rst_n       (sys_rst_n),
    .de          (lcd_de_w),
    .y8_in       (disp_y),
    .pixel_x     (pixel_x_w),
    .pixel_y     (pixel_y_w),
    .y8_out      (blur_y8),
    .pixel_x_out (blur_px),
    .pixel_y_out (blur_py),
    .de_out      (blur_de)
);

// Sobel now only computes the raw gradient (magnitude + a quantized
// direction); nms_thresh.v does non-max suppression along that direction
// before thresholding. Plain "magnitude > threshold" used to light up the
// whole shoulder of a real edge's gradient hill, not just the peak, which
// is why lowering EDGE_THRESH alone made lines thicker -- NMS keeps only
// each hill's local peak first, so line width stays ~1px regardless of
// where the threshold is set (verified in tb_integration_nms.v).
wire [12:0] sobel_mag;
wire [1:0]  sobel_dir;
wire [10:0] sobel_px, sobel_py;
wire        sobel_de;

sobel_edge u_sobel (
    .clk         (clk_9m),
    .rst_n       (sys_rst_n),
    .de          (blur_de),
    .y8          (blur_y8),
    .pixel_x     (blur_px),
    .pixel_y     (blur_py),
    .magnitude   (sobel_mag),
    .direction   (sobel_dir),
    .pixel_x_out (sobel_px),
    .pixel_y_out (sobel_py),
    .de_out      (sobel_de)
);

wire [7:0] sobel_r, sobel_g, sobel_b;

nms_thresh u_nms (
    .clk       (clk_9m),
    .rst_n     (sys_rst_n),
    .de        (sobel_de),
    .magnitude (sobel_mag),
    .direction (sobel_dir),
    .pixel_x   (sobel_px),
    .pixel_y   (sobel_py),
    .edge_r    (sobel_r),
    .edge_g    (sobel_g),
    .edge_b    (sobel_b)
);

// key2 was plain black/white threshold_binarize.v, then briefly a Code 39
// reader (barcode_decoder.v) -- swapped again to EAN-13/UPC-A
// (ean13_decoder.v) once real testing showed retail packaging (the
// drink-box case this was built for) is printed in EAN-13/UPC-A, not
// Code 39. barcode_decoder.v itself is untouched and still in the repo
// (not instantiated, same treatment as threshold_binarize.v and
// motion_detector.v/motion_overlay.v below -- qsf lines commented, not
// deleted) in case Code 39 (asset tags etc) is ever wanted again.
localparam [10:0] BARCODE_SCAN_ROW = 11'd136;

wire        bc_valid_w;
wire [51:0] bc_digits_w;
wire        bc_scan_active_w;

ean13_decoder #(
    .SCAN_ROW (BARCODE_SCAN_ROW)
) u_barcode (
    .clk            (clk_9m),
    .rst_n          (sys_rst_n),
    .de             (lcd_de_w),
    .frame_pulse    (lcd_frame_pulse),
    .y8             (disp_y),
    .pixel_x        (pixel_x_w),
    .pixel_y        (pixel_y_w),
    .ean_valid      (bc_valid_w),
    .decoded_digits (bc_digits_w),        // 13 BCD nibbles -- not displayed
    .scan_active    (bc_scan_active_w)    // yet, see CLAUDE.md
);

// Sticky "recently decoded" flag so a valid read is visible for longer than
// ean_valid's single-cycle pulse -- counts down once per LCD frame.
reg [7:0] bc_hold_cnt;
always @(posedge clk_9m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        bc_hold_cnt <= 8'd0;
    end
    else if (bc_valid_w) begin
        bc_hold_cnt <= 8'd90;   // purely visual hold, not timing-critical
    end
    else if (lcd_frame_pulse && (bc_hold_cnt != 8'd0)) begin
        bc_hold_cnt <= bc_hold_cnt - 8'd1;
    end
end

// Live image passthrough with a reference line drawn across the scan row:
// yellow while hunting, green for a short hold right after a valid decode.
wire       bc_hold_active = (bc_hold_cnt != 8'd0);
wire [7:0] bc_r = bc_scan_active_w ? (bc_hold_active ? 8'd0 : 8'd255) : disp_r;
wire [7:0] bc_g = bc_scan_active_w ? 8'd255                          : disp_g;
wire [7:0] bc_b = bc_scan_active_w ? 8'd0                            : disp_b;

localparam [1:0] MODE_TRACKING = 2'd0,
                  MODE_SOBEL    = 2'd1,
                  MODE_BINARIZE = 2'd2;   // now the barcode-scan view

assign final_r = (disp_mode == MODE_SOBEL)    ? sobel_r :
                  (disp_mode == MODE_BINARIZE) ? bc_r    : ov_r;
assign final_g = (disp_mode == MODE_SOBEL)    ? sobel_g :
                  (disp_mode == MODE_BINARIZE) ? bc_g    : ov_g;
assign final_b = (disp_mode == MODE_SOBEL)    ? sobel_b :
                  (disp_mode == MODE_BINARIZE) ? bc_b    : ov_b;

// ---- BNN camera pipeline: live digit -> LG3661BH, always-on background
// classifier, decoupled from the key1/2/3 display-mode mux above (all
// three buttons are already spoken for by Sobel/EAN-13/tracking) ----
//
// roi_binarize_28x28.v taps the same pixel_x_w/pixel_y_w/disp_y/lcd_de_w/
// lcd_frame_pulse bus every other pixel-level module here already uses,
// crops+downsamples the fixed 224x224 center of the frame (user chose the
// fixed-ROI approach over auto-locating the digit) into a 28x28 binary
// image once per camera frame.
wire         bnn_img_valid;
wire [783:0] bnn_img;

roi_binarize_28x28 u_roi (
    .clk         (clk_9m),
    .rst_n       (sys_rst_n),
    .de          (lcd_de_w),
    .frame_pulse (lcd_frame_pulse),
    .y8          (disp_y),
    .pixel_x     (pixel_x_w),
    .pixel_y     (pixel_y_w),
    .img_valid   (bnn_img_valid),
    .img_out     (bnn_img)
);

// Small FSM: kick off one bnn_core classification each time roi_binarize
// finishes a fresh frame, wait for it to finish (~1040 cycles at clk_9m,
// well within a single frame period), latch the result, go back to
// waiting for the next img_valid. bnn_img is only sampled the one cycle
// bnn_core latches image_in right after start -- by then there's a full
// vertical-blanking-plus-24-lines margin before roi_binarize's img_mem
// starts getting overwritten by the next frame, so no torn-frame risk.
localparam [1:0] BNN_IDLE = 2'd0, BNN_START = 2'd1, BNN_WAIT = 2'd2;
reg [1:0] bnn_fsm;
reg       bnn_start;
reg       bnn_result_valid;
reg [3:0] bnn_digit;
wire      bnn_done;
wire [3:0] bnn_digit_out;

always @(posedge clk_9m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        bnn_fsm          <= BNN_IDLE;
        bnn_start        <= 1'b0;
        bnn_digit        <= 4'd0;
        bnn_result_valid <= 1'b0;
    end
    else begin
        bnn_start <= 1'b0;
        case (bnn_fsm)
            BNN_IDLE: begin
                if (bnn_img_valid)
                    bnn_fsm <= BNN_START;
            end
            BNN_START: begin
                bnn_start <= 1'b1;
                bnn_fsm   <= BNN_WAIT;
            end
            BNN_WAIT: begin
                if (bnn_done) begin
                    bnn_digit        <= bnn_digit_out;
                    bnn_result_valid <= 1'b1;
                    bnn_fsm          <= BNN_IDLE;
                end
            end
            default: bnn_fsm <= BNN_IDLE;
        endcase
    end
end

bnn_core u_bnn_cam (
    .clk       (clk_9m),
    .rst_n     (sys_rst_n),
    .start     (bnn_start),
    .image_in  (bnn_img),
    .done      (bnn_done),
    .digit_out (bnn_digit_out)
);

// digit_valid gates the display blank until the first real classification
// has completed -- avoids showing a stray "0" before there's a real result.
seg7_decoder #(.ACTIVE_LOW(1)) u_seg7 (
    .digit       (bnn_digit),
    .digit_valid (bnn_result_valid),
    .seg         (seg7),
    .dp          (seg7_dp)
);

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
