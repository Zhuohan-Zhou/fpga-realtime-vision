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

    // Buttons (active-low) -- currently unused: runtime KEY1/2/3 mode
    // switching was removed in favor of a single compile-time-selected
    // algorithm (see "ACTIVE ALGORITHM SLOT" below). Kept as ports so
    // CameraCapture.qsf's existing pin assignments for them stay valid.
    input         key1_n,
    input         key2_n,
    input         key3_n,

    // On-board AX4010 6-digit 7-segment display -- BNN handwritten-digit
    // output. Per the AX4010 manual's "Digital tube pin assignment" table
    // (p.31): DIG[7:0] = {dp,g,f,e,d,c,b,a} are the shared segment lines
    // (common anode, active-low -- same polarity already confirmed for
    // this display), and SEL[5:0] are per-digit enable lines, one per
    // physical digit position, driven through switching transistors.
    // We only need to show one digit (the classifier result), so no
    // multiplexed scanning is needed -- SEL[0] (rightmost digit) is held
    // permanently selected and DIG is driven statically; SEL[1:5] are
    // held de-selected so the other 5 digits stay dark.
    output  [7:0] dig,   // {dp,g,f,e,d,c,b,a}, active-low
    output  [5:0] sel    // per-digit enable; polarity assumed active-low
                          // (matches DIG's common-anode convention) --
                          // NOT YET VERIFIED on real hardware, see CLAUDE.md
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

sccb_master u_sccb (
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
wire [7:0]  algo_r, algo_g, algo_b;   // driven by whichever algorithm is active below

lcd_driver u_lcd (
    .pclk    (clk_9m),
    .rst_n   (sys_rst_n),
    .data_r  (disp_final2_r),
    .data_g  (disp_final2_g),
    .data_b  (disp_final2_b),
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

// ============================================================================
// ACTIVE ALGORITHM SLOT
//
// Only ONE algorithm runs at a time now -- on an FPGA, an instantiated
// module is real hardware from power-on regardless of whether anything
// ever looks at its output, so the old "all 3 modes running in parallel,
// button just picks which one reaches the screen" design meant Sobel and
// centroid tracking were both permanently burning LE even when you were
// looking at the other one (confirmed via Resource Utilization by Entity:
// e.g. the whole non-BNN, non-base-pipeline chunk was ~3900+ LE). To
// switch algorithms now: comment out the active block below, uncomment
// the one you want, update the matching VERILOG_FILE line(s) in
// CameraCapture.qsf to match (comment out the ones you're switching away
// from, uncomment the ones you're switching to), then recompile+reflash.
// Every block drives the same algo_r/g/b so whichever one is active feeds
// the rest of the display chain (ROI box overlay, then lcd_driver) the
// same way. key1_n/key2_n/key3_n are currently unused -- no runtime mode
// switching anymore -- kept as ports so CameraCapture.qsf's existing pin
// assignments for them don't need touching; free to repurpose per-algorithm
// later (e.g. bnn_demo_top.v-style test-image cycling, ROI recenter, etc).
// ============================================================================

// ---- ACTIVE: BNN handwritten-digit recognition ----
// BNN doesn't touch the live video feed itself (see the BNN classification
// block further down, and roi_binarize_28x28/bnn_img_viz below) -- it just
// runs the digital-tube result and the debug 28x28 viz block. Plain
// passthrough video here.
assign algo_r = disp_r;
assign algo_g = disp_g;
assign algo_b = disp_b;

// ---- Sobel edge detection (KEY1's old mode) ----
// Uncomment this block + comment out the BNN block above + swap the qsf
// VERILOG_FILE lines for gaussian_blur3x3.v/sobel_edge.v/nms_thresh.v
// (uncomment) and roi_binarize_28x28.v/bnn_img_viz.v/bnn_core.v/
// seg7_decoder.v (comment out, unless you want BNN classification to also
// keep running in the background -- it can coexist with any video-mode
// algorithm below since it doesn't touch algo_r/g/b, just costs LE).
//
// wire [7:0]  blur_y8;
// wire [10:0] blur_px, blur_py;
// wire        blur_de;
//
// gaussian_blur3x3 u_blur (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (lcd_de_w), .y8_in (disp_y),
//     .pixel_x (pixel_x_w), .pixel_y (pixel_y_w),
//     .y8_out (blur_y8), .pixel_x_out (blur_px), .pixel_y_out (blur_py), .de_out (blur_de)
// );
//
// wire [12:0] sobel_mag;
// wire [1:0]  sobel_dir;
// wire [10:0] sobel_px, sobel_py;
// wire        sobel_de;
//
// sobel_edge u_sobel (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (blur_de), .y8 (blur_y8),
//     .pixel_x (blur_px), .pixel_y (blur_py),
//     .magnitude (sobel_mag), .direction (sobel_dir),
//     .pixel_x_out (sobel_px), .pixel_y_out (sobel_py), .de_out (sobel_de)
// );
//
// nms_thresh u_nms (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (sobel_de),
//     .magnitude (sobel_mag), .direction (sobel_dir),
//     .pixel_x (sobel_px), .pixel_y (sobel_py),
//     .edge_r (algo_r), .edge_g (algo_g), .edge_b (algo_b)
// );

// ---- Centroid tracking (KEY3's old default mode) ----
// Uncomment + comment out BNN block + swap qsf lines for
// color_blob_tracker.v/kalman_1d.v/seq_divider.v/overlay_marker.v.
//
// wire        blob_found_w, blob_cx_valid_w;
// wire [10:0] blob_cx_w, blob_cy_w;
// wire [17:0] blob_pixels_w;   // hook up to SignalTap to tune thresholds
//
// color_blob_tracker u_blob (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (lcd_de_w), .frame_pulse (lcd_frame_pulse),
//     .r8 (disp_r), .g8 (disp_g), .b8 (disp_b),
//     .pixel_x (pixel_x_w), .pixel_y (pixel_y_w),
//     .cx (blob_cx_w), .cy (blob_cy_w),
//     .blob_found (blob_found_w), .cx_valid (blob_cx_valid_w), .blob_pixels (blob_pixels_w)
// );
//
// overlay_marker u_overlay (
//     .pixel_x (pixel_x_w), .pixel_y (pixel_y_w),
//     .cx (blob_cx_w), .cy (blob_cy_w), .blob_found (blob_found_w),
//     .in_r (disp_r), .in_g (disp_g), .in_b (disp_b),
//     .out_r (algo_r), .out_g (algo_g), .out_b (algo_b)
// );

// ---- EAN-13/UPC-A barcode decoding (KEY2's older mode, pre-BNN) ----
// Uncomment + comment out BNN block + swap qsf line for
// rtl/vision/barcode/ean13_decoder.v (uncomment). Visual feedback: scan
// row drawn yellow while hunting, green for a few frames after a valid
// decode (add a hold counter like the old design if you want the green
// to persist longer than one frame -- ean_valid is only a 1-cycle pulse).
//
// wire        ean_valid;
// wire [51:0] ean_digits;   // 13x4-bit BCD, unused here, hook to SignalTap/seg7 if wanted
// wire        ean_scan_active;
//
// ean13_decoder u_ean13 (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (lcd_de_w), .frame_pulse (lcd_frame_pulse),
//     .y8 (disp_y), .pixel_x (pixel_x_w), .pixel_y (pixel_y_w),
//     .ean_valid (ean_valid), .decoded_digits (ean_digits), .scan_active (ean_scan_active)
// );
//
// assign algo_r = ean_scan_active ? (ean_valid ? 8'd0   : 8'd255) : disp_r;
// assign algo_g = ean_scan_active ? 8'd255                        : disp_g;
// assign algo_b = ean_scan_active ? (ean_valid ? 8'd0   : 8'd0)   : disp_b;

// ---- Motion detection (independent of tracking, tints changed cells) ----
// Uncomment + comment out BNN block + swap qsf lines for
// motion_detector.v/motion_overlay.v.
//
// wire       motion_highlight;
// wire       motion_detected_w;
// wire [8:0] motion_changed_blocks_w;   // debug: hook to SignalTap
//
// motion_detector u_motion (
//     .clk (clk_9m), .rst_n (sys_rst_n), .de (lcd_de_w), .frame_pulse (lcd_frame_pulse),
//     .y8 (disp_y), .pixel_x (pixel_x_w), .pixel_y (pixel_y_w),
//     .highlight (motion_highlight),
//     .motion_detected (motion_detected_w), .changed_blocks (motion_changed_blocks_w)
// );
//
// motion_overlay u_motion_ov (
//     .highlight (motion_highlight),
//     .in_r (disp_r), .in_g (disp_g), .in_b (disp_b),
//     .out_r (algo_r), .out_g (algo_g), .out_b (algo_b)
// );

// Green reference box around the fixed BNN capture ROI (224x224, centered --
// same X0/Y0 as roi_binarize_28x28.v's defaults below) drawn on top of
// whatever's already on screen, regardless of which key1/2/3 mode is
// selected -- so there's always a visible target for where to hold a
// handwritten digit. 2px outline, hollow (not filled) so it doesn't cover
// the ROI's own content.
localparam [10:0] ROI_BOX_X0    = 11'd128;
localparam [10:0] ROI_BOX_Y0    = 11'd24;
localparam [10:0] ROI_BOX_X1    = ROI_BOX_X0 + 11'd224 - 11'd1;   // 351
localparam [10:0] ROI_BOX_Y1    = ROI_BOX_Y0 + 11'd224 - 11'd1;   // 247
localparam [10:0] ROI_BOX_LINE_W = 11'd2;

wire roi_box_in_x    = (pixel_x_w >= ROI_BOX_X0) && (pixel_x_w <= ROI_BOX_X1);
wire roi_box_in_y    = (pixel_y_w >= ROI_BOX_Y0) && (pixel_y_w <= ROI_BOX_Y1);
wire roi_box_on_top  = (pixel_y_w >= ROI_BOX_Y0) && (pixel_y_w < ROI_BOX_Y0 + ROI_BOX_LINE_W);
wire roi_box_on_bot  = (pixel_y_w <= ROI_BOX_Y1) && (pixel_y_w > ROI_BOX_Y1 - ROI_BOX_LINE_W);
wire roi_box_on_left = (pixel_x_w >= ROI_BOX_X0) && (pixel_x_w < ROI_BOX_X0 + ROI_BOX_LINE_W);
wire roi_box_on_rt   = (pixel_x_w <= ROI_BOX_X1) && (pixel_x_w > ROI_BOX_X1 - ROI_BOX_LINE_W);
wire roi_box_pixel   = (roi_box_in_x && (roi_box_on_top || roi_box_on_bot)) ||
                        (roi_box_in_y && (roi_box_on_left || roi_box_on_rt));

wire [7:0] disp_final_r = roi_box_pixel ? 8'd0   : algo_r;
wire [7:0] disp_final_g = roi_box_pixel ? 8'd255 : algo_g;
wire [7:0] disp_final_b = roi_box_pixel ? 8'd0   : algo_b;

// roi_binarize_28x28.v taps the same pixel_x_w/pixel_y_w/disp_y/lcd_de_w/
// lcd_frame_pulse bus every other pixel-level module here already uses,
// crops+downsamples the fixed 224x224 center of the frame (user chose the
// fixed-ROI approach over auto-locating the digit) into a 28x28 binary
// image once per camera frame.
wire         bnn_img_valid;
wire [783:0] bnn_img;
wire [15:0]  bnn_ink_count;

roi_binarize_28x28 u_roi (
    .clk         (clk_9m),
    .rst_n       (sys_rst_n),
    .de          (lcd_de_w),
    .frame_pulse (lcd_frame_pulse),
    .y8          (disp_y),
    .pixel_x     (pixel_x_w),
    .pixel_y     (pixel_y_w),
    .img_valid   (bnn_img_valid),
    .img_out     (bnn_img),
    .ink_count   (bnn_ink_count)
);

// Debug view: draw the actual 28x28 image roi_binarize_28x28 just produced
// -- the same bits bnn_core classifies -- blown up onto the LCD, so you
// can see exactly what's being fed to the network instead of only seeing
// the digital-tube result. Runs regardless of key1/2/3 mode, same as
// u_roi itself; placed at (360,80)-(472,192), clear of the green ROI box
// (which ends at x=351) and fully on-screen (480x272 panel).
wire viz_pixel, viz_bit;

bnn_img_viz #(.VIZ_X0(11'd360), .VIZ_Y0(11'd80), .SCALE(4)) u_bnn_viz (
    .clk       (clk_9m),
    .rst_n     (sys_rst_n),
    .img_valid (bnn_img_valid),
    .img_in    (bnn_img),
    .pixel_x   (pixel_x_w),
    .pixel_y   (pixel_y_w),
    .viz_pixel (viz_pixel),
    .viz_bit   (viz_bit)
);

// viz_bit=1 means "ink" (roi_binarize_28x28's dark=1 convention) -- draw
// black to match what the ink looks like on the actual paper; 0 (background)
// draws white. Layered on top of disp_final_r/g/b (which already has the
// green ROI box baked in), so this always wins inside its own box.
wire [7:0] viz_gray = viz_bit ? 8'd0 : 8'd255;

wire [7:0] disp_final2_r = viz_pixel ? viz_gray : disp_final_r;
wire [7:0] disp_final2_g = viz_pixel ? viz_gray : disp_final_g;
wire [7:0] disp_final2_b = viz_pixel ? viz_gray : disp_final_b;

// Small FSM: kick off one bnn_core classification each time roi_binarize
// finishes a fresh frame, wait for it to finish (~1040 cycles at clk_9m,
// well within a single frame period), latch the result, go back to
// waiting for the next img_valid. bnn_img is only sampled the one cycle
// bnn_core latches image_in right after start -- by then there's a full
// vertical-blanking-plus-24-lines margin before roi_binarize's img_mem
// starts getting overwritten by the next frame, so no torn-frame risk.
//
// bnn_core has no "reject/unknown" class -- it always argmaxes to some
// digit 0-9, even fed a nearly-blank ROI (empty paper/background), so the
// display would otherwise show a stale or nonsense digit at all times.
// MIN_INK_PIXELS gates that: bnn_ink_count (raw dark-pixel count within
// the 224x224 ROI, from roi_binarize_28x28.v) is sampled at BNN_START and
// carried through the classification latency; if it was below threshold,
// the result is discarded (bnn_result_valid stays 0, display blanks)
// instead of being shown. 150px out of 50176 is a rough, untested
// first-cut ("is there any ink here at all") -- not a real digit/no-digit
// classifier, just a presence gate; likely needs real-world tuning like
// THRESH/ROI size already flagged in CLAUDE.md.
localparam [1:0]  BNN_IDLE = 2'd0, BNN_START = 2'd1, BNN_WAIT = 2'd2;
localparam [15:0] MIN_INK_PIXELS = 16'd150;
reg [1:0] bnn_fsm;
reg       bnn_start;
reg       bnn_result_valid;
reg       bnn_ink_ok;
reg [3:0] bnn_digit;
wire      bnn_done;
wire [3:0] bnn_digit_out;

always @(posedge clk_9m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        bnn_fsm          <= BNN_IDLE;
        bnn_start        <= 1'b0;
        bnn_digit        <= 4'd0;
        bnn_result_valid <= 1'b0;
        bnn_ink_ok       <= 1'b0;
    end
    else begin
        bnn_start <= 1'b0;
        case (bnn_fsm)
            BNN_IDLE: begin
                if (bnn_img_valid) begin
                    bnn_ink_ok <= (bnn_ink_count >= MIN_INK_PIXELS);
                    bnn_fsm    <= BNN_START;
                end
            end
            BNN_START: begin
                bnn_start <= 1'b1;
                bnn_fsm   <= BNN_WAIT;
            end
            BNN_WAIT: begin
                if (bnn_done) begin
                    bnn_digit        <= bnn_digit_out;
                    bnn_result_valid <= bnn_ink_ok;   // blank if there was nothing to classify
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
wire [6:0] seg7_pattern;
wire       seg7_dp_pattern;

seg7_decoder #(.ACTIVE_LOW(1)) u_seg7 (
    .digit       (bnn_digit),
    .digit_valid (bnn_result_valid),
    .seg         (seg7_pattern),
    .dp          (seg7_dp_pattern)
);

// AX4010 on-board 6-digit display: DIG[7:0] = {dp,g,f,e,d,c,b,a} shared
// across all 6 digit positions, SEL[5:0] picks which position is
// currently powered. We only need one digit lit (the classifier result),
// so no scanning/multiplexing -- SEL[0] (rightmost) held selected, the
// other 5 held de-selected so they stay dark regardless of DIG.
//
// BUG FIXED 2026-07-17: this used to be a blind concatenation
// `assign dig = {seg7_dp_pattern, seg7_pattern};`. seg7_pattern[6:0] is
// {a,b,c,d,e,f,g} (seg7_pattern[6]=a .. seg7_pattern[0]=g, per
// seg7_decoder.v's own convention), so that concatenation produced
// dig[6]=a, dig[5]=b, dig[4]=c, dig[3]=d, dig[2]=e, dig[1]=f, dig[0]=g --
// i.e. dp landed correctly at dig[7], but the a..g order was reversed
// against the manual's DIG[0]=a .. DIG[6]=g mapping. Root cause of user's
// report "single digit position lights up correctly, but the segment
// shape isn't any real digit" -- each segment was driving the wrong
// physical DIG pin. Fixed with explicit per-bit wiring below instead of
// a concatenation, so this can't silently reverse again.
assign dig[0] = seg7_pattern[6];   // a
assign dig[1] = seg7_pattern[5];   // b
assign dig[2] = seg7_pattern[4];   // c
assign dig[3] = seg7_pattern[3];   // d
assign dig[4] = seg7_pattern[2];   // e
assign dig[5] = seg7_pattern[1];   // f
assign dig[6] = seg7_pattern[0];   // g
assign dig[7] = seg7_dp_pattern;   // dp

localparam SEL_ACTIVE_LOW = 1;   // matches DIG's common-anode polarity;
                                  // not yet verified on real hardware
assign sel = SEL_ACTIVE_LOW ? 6'b111110 : 6'b000001;   // only bit0 (digit 0) selected

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
