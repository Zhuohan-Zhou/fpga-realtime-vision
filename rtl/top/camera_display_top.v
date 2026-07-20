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
    input         key2_n,   // BNN digit recognition
    input         key3_n,   // centroid tracking (default)

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
wire [7:0]  ov_r, ov_g, ov_b;
wire [7:0]  final_r, final_g, final_b;

lcd_driver u_lcd (
    .pclk    (clk_9m),
    .rst_n   (sys_rst_n),
    .data_r  (disp_final_r),
    .data_g  (disp_final_g),
    .data_b  (disp_final_b),
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

localparam [1:0] MODE_TRACKING = 2'd0,
                  MODE_SOBEL    = 2'd1,
                  MODE_BNN      = 2'd2;

assign final_r = (disp_mode == MODE_SOBEL) ? sobel_r :
                  (disp_mode == MODE_BNN)   ? disp_r  : ov_r;
assign final_g = (disp_mode == MODE_SOBEL) ? sobel_g :
                  (disp_mode == MODE_BNN)   ? disp_g  : ov_g;
assign final_b = (disp_mode == MODE_SOBEL) ? sobel_b :
                  (disp_mode == MODE_BNN)   ? disp_b  : ov_b;

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

wire [7:0] disp_final_r = roi_box_pixel ? 8'd0   : final_r;
wire [7:0] disp_final_g = roi_box_pixel ? 8'd255 : final_g;
wire [7:0] disp_final_b = roi_box_pixel ? 8'd0   : final_b;

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
    else if (disp_mode != MODE_BNN) begin
        bnn_fsm          <= BNN_IDLE;
        bnn_start        <= 1'b0;
        bnn_result_valid <= 1'b0;
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
