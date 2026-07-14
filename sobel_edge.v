module sobel_edge #(
    parameter integer WIDTH = 480
)(
    input             clk,      // clk_9m
    input             rst_n,
    input             de,       // pixel valid strobe (from gaussian_blur3x3's de_out)
    input      [7:0]  y8,       // luma of the pixel at pixel_x/pixel_y now
    input      [10:0] pixel_x,  // 0..479
    input      [10:0] pixel_y,  // 0..271

    // Raw gradient only -- thresholding used to happen right here, but
    // that's what made low EDGE_THRESH values draw fat lines (see
    // nms_thresh.v): a real edge's gradient magnitude ramps up and back
    // down like a hill, not a single spike, so a plain "> threshold" test
    // lights up every pixel on the shoulder of that hill, not just the
    // peak. nms_thresh.v does non-max suppression along the gradient
    // direction first (keep only the local peak), then thresholds.
    output     [12:0] magnitude,
    output     [1:0]  direction,     // 0=horizontal grad (vert. edge), 1=diag "/", 2=vertical grad (horiz. edge), 3=diag "\"
    output     [10:0] pixel_x_out,
    output     [10:0] pixel_y_out,
    output            de_out
);

reg [7:0] line_a [0:WIDTH-1];   // row N-2 (relative to the incoming row)
reg [7:0] line_b [0:WIDTH-1];   // row N-1

integer init_i;
initial begin
    for (init_i = 0; init_i < WIDTH; init_i = init_i + 1) begin
        line_a[init_i] = 8'd0;
        line_b[init_i] = 8'd0;
    end
end

// registered read + a matching one-cycle-delayed copy of everything else,
// so the write-back below and the shift register further down both work
// off signals that are consistently one cycle behind the live inputs.
reg [7:0]  la, lb;
reg [10:0] px_d1, py_d1;
reg [7:0]  y8_d1;
reg        de_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        de_d1 <= 1'b0;
        la    <= 8'd0;
        lb    <= 8'd0;
        px_d1 <= 11'd0;
        py_d1 <= 11'd0;
        y8_d1 <= 8'd0;
    end
    else begin
        de_d1 <= de;
        if (de) begin
            la    <= line_a[pixel_x];
            lb    <= line_b[pixel_x];
            px_d1 <= pixel_x;
            py_d1 <= pixel_y;
            y8_d1 <= y8;
        end
    end
end

// write-back one cycle after the read of the same column: la/lb read
// port and this write port land on different addresses on any given
// cycle (write trails read by one column), so this is an ordinary
// simple-dual-port access, exactly what M9K expects.
always @(posedge clk) begin
    if (de_d1) begin
        line_a[px_d1] <= lb;     // old row N-1 becomes row N-2
        line_b[px_d1] <= y8_d1;  // current row becomes row N-1
    end
end

// 3x3 window: 3 rows x 3-tap horizontal shift regs, gated by de_d1 to
// match la/lb/y8_d1's timing (one cycle behind de/pixel_x/pixel_y).
// p0 = top row (line_a), p1 = mid row (line_b), p2 = bottom row (incoming
// y8). d2 = 2 pixels ago (left), d0 = current (right).
reg [7:0] p0d2, p0d1, p0d0;
reg [7:0] p1d2, p1d1, p1d0;
reg [7:0] p2d2, p2d1, p2d0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p0d2<=0; p0d1<=0; p0d0<=0;
        p1d2<=0; p1d1<=0; p1d0<=0;
        p2d2<=0; p2d1<=0; p2d0<=0;
    end
    else if (de_d1) begin
        p0d2 <= p0d1; p0d1 <= p0d0; p0d0 <= la;
        p1d2 <= p1d1; p1d1 <= p1d0; p1d0 <= lb;
        p2d2 <= p2d1; p2d1 <= p2d0; p2d0 <= y8_d1;
    end
end

// Sobel convolution (adds/subtracts/shifts only, no multiplier)
// Gx = [-1 0 1; -2 0 2; -1 0 1]   Gy = [-1 -2 -1; 0 0 0; 1 2 1]
wire signed [11:0] gx =
      ($signed({3'b0,p0d0}) - $signed({3'b0,p0d2}))
    + (($signed({3'b0,p1d0}) - $signed({3'b0,p1d2})) <<< 1)
    + ($signed({3'b0,p2d0}) - $signed({3'b0,p2d2}));

wire signed [11:0] gy =
      ($signed({3'b0,p2d2}) + ($signed({3'b0,p2d1}) <<< 1) + $signed({3'b0,p2d0}))
    - ($signed({3'b0,p0d2}) + ($signed({3'b0,p0d1}) <<< 1) + $signed({3'b0,p0d0}));

wire [11:0] abs_gx = gx[11] ? (~gx + 12'd1) : gx;
wire [11:0] abs_gy = gy[11] ? (~gy + 12'd1) : gy;
wire [12:0] mag_raw = {1'b0, abs_gx} + {1'b0, abs_gy};

// Cheap direction bucket, no atan2/divider: compare |Gx| and |Gy| against
// 2x each other (~26.6/63.4 deg boundaries, close enough to the classic
// 22.5/67.5 split for picking which pair of the 8 neighbors to compare
// against in nms_thresh.v -- same shift/add-only philosophy as the rest
// of this pipeline). same_sign picks which of the two diagonals.
wire gx_dominant = (abs_gx >= (abs_gy <<< 1));
wire gy_dominant = (abs_gy >= (abs_gx <<< 1));
wire same_sign   = (gx[11] == gy[11]);

wire [1:0] dir_code = gy_dominant ? 2'd2 :
                       gx_dominant ? 2'd0 :
                       same_sign   ? 2'd1 : 2'd3;

// Need 2 full lines of real history before the 3x3 window is valid; force
// magnitude to 0 on the border instead of passing a bogus value through --
// 0 can never look like a local max in nms_thresh.v, so the border stays
// blanked without needing a separate "valid" flag downstream. Compares
// against px_d1/py_d1 (the delayed coordinate), not the live pixel_x/
// pixel_y, since that's the frame of reference the window content lags
// behind now.
wire window_valid = (px_d1 >= 11'd3) && (py_d1 >= 11'd2);

assign magnitude    = window_valid ? mag_raw : 13'd0;
assign direction    = dir_code;
assign pixel_x_out  = px_d1;
assign pixel_y_out  = py_d1;
assign de_out       = de_d1;

endmodule
