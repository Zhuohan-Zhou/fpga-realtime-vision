module nms_thresh #(
    parameter integer WIDTH       = 480,
    parameter [12:0]  EDGE_THRESH = 13'd45    // tune: 0..~2040 (4*255 max per Gx/Gy).
                                               // Same knob as before, just applied after
                                               // suppression now -- lowering it no longer
                                               // fattens lines, it only reaches fainter
                                               // real edges (see header note below).
)(
    input             clk,      // clk_9m
    input             rst_n,
    input             de,       // from sobel_edge's de_out
    input      [12:0] magnitude,
    input      [1:0]  direction,
    input      [10:0] pixel_x,  // from sobel_edge's pixel_x_out/pixel_y_out
    input      [10:0] pixel_y,

    output     [7:0]  edge_r,
    output     [7:0]  edge_g,
    output     [7:0]  edge_b
);

// Non-max suppression: a real edge's gradient magnitude doesn't jump from
// 0 to a spike and back to 0 -- it ramps up across a few pixels, peaks
// right on the edge, then ramps back down, like a hill (blurring widens
// the hill further). Plain thresholding lights up the whole hill wherever
// it's above the bar, which is exactly why lowering EDGE_THRESH alone
// made lines thicker: more of each hill's shoulder cleared the bar.
//
// The fix: for every pixel, look at its own gradient direction (computed
// in sobel_edge.v) and compare its magnitude against ONLY the two
// neighbors that lie along that direction (i.e. perpendicular to the
// edge, which is the direction the hill actually rises and falls along).
// Keep it only if it's >= both -- the local peak of its own hill. Every
// other pixel on the same hill loses to a neighbor closer to the true
// peak and gets suppressed to 0 before the threshold is even applied.
// Net effect: edges come out a consistent ~1px wide regardless of how low
// EDGE_THRESH is set, same as OpenCV's Canny.
//
// Architecture mirrors sobel_edge.v: registered (synchronous) line-buffer
// reads so this maps to M9K instead of eating LEs, and a delay chain so
// write-back and the shift register work off signals that consistently
// lag the live inputs by one cycle.

reg [12:0] mline_a [0:WIDTH-1];   // row N-2 magnitude
reg [12:0] mline_b [0:WIDTH-1];   // row N-1 magnitude
reg [1:0]  dline_b [0:WIDTH-1];   // row N-1 direction -- NMS only ever needs
                                   // the CENTER pixel's own direction to pick
                                   // its two neighbors, and the center tap
                                   // always lands on row N-1, so that's the
                                   // only row direction needs to be buffered
                                   // for at all (rows N-2/N never get looked
                                   // up as a "center").

integer init_i;
initial begin
    for (init_i = 0; init_i < WIDTH; init_i = init_i + 1) begin
        mline_a[init_i] = 13'd0;
        mline_b[init_i] = 13'd0;
        dline_b[init_i] = 2'd0;
    end
end

reg [12:0] la_m, lb_m;
reg [1:0]  db_m;          // row N-1's direction at this column, registered read
reg [10:0] px_d1, py_d1;
reg [12:0] mag_d1;
reg [1:0]  dir_d1;        // this cycle's incoming direction, latched for write-back
reg        de_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        de_d1  <= 1'b0;
        la_m   <= 13'd0;
        lb_m   <= 13'd0;
        db_m   <= 2'd0;
        px_d1  <= 11'd0;
        py_d1  <= 11'd0;
        mag_d1 <= 13'd0;
        dir_d1 <= 2'd0;
    end
    else begin
        de_d1 <= de;
        if (de) begin
            la_m   <= mline_a[pixel_x];
            lb_m   <= mline_b[pixel_x];
            db_m   <= dline_b[pixel_x];
            px_d1  <= pixel_x;
            py_d1  <= pixel_y;
            mag_d1 <= magnitude;
            dir_d1 <= direction;
        end
    end
end

always @(posedge clk) begin
    if (de_d1) begin
        mline_a[px_d1] <= lb_m;    // old row N-1 becomes row N-2
        mline_b[px_d1] <= mag_d1;  // current row becomes row N-1
        dline_b[px_d1] <= dir_d1;
    end
end

// 3x3 magnitude window, same layout convention as sobel_edge.v's luma
// window (m0=top row, m1=mid row, m2=bottom row; d2=left...d0=right).
// dird2/dird1/dird0 shifts in lockstep with the mid row (m1) specifically,
// since m1d1 is the window's center and dird1 is its matching direction.
reg [12:0] m0d2, m0d1, m0d0;
reg [12:0] m1d2, m1d1, m1d0;
reg [12:0] m2d2, m2d1, m2d0;
reg [1:0]  dird2, dird1, dird0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m0d2<=0; m0d1<=0; m0d0<=0;
        m1d2<=0; m1d1<=0; m1d0<=0;
        m2d2<=0; m2d1<=0; m2d0<=0;
        dird2<=0; dird1<=0; dird0<=0;
    end
    else if (de_d1) begin
        m0d2 <= m0d1; m0d1 <= m0d0; m0d0 <= la_m;
        m1d2 <= m1d1; m1d1 <= m1d0; m1d0 <= lb_m;
        m2d2 <= m2d1; m2d1 <= m2d0; m2d0 <= mag_d1;
        dird2 <= dird1; dird1 <= dird0; dird0 <= db_m;
    end
end

// center = m1d1 (mid row, mid col); cdir = its own gradient direction.
// Neighbor layout relative to the center:
//   m0d2 m0d1 m0d0        TL   UP   TR
//   m1d2 m1d1 m1d0    =   L   ctr   R
//   m2d2 m2d1 m2d0        BL  DOWN  BR
wire [1:0] cdir = dird1;

wire [12:0] nbr_a = (cdir == 2'd0) ? m1d2 :   // horizontal grad: left
                     (cdir == 2'd2) ? m0d1 :   // vertical grad:   up
                     (cdir == 2'd1) ? m0d0 :   // diag "/":        top-right
                                       m0d2;    // diag "\":        top-left

wire [12:0] nbr_b = (cdir == 2'd0) ? m1d0 :   // horizontal grad: right
                     (cdir == 2'd2) ? m2d1 :   // vertical grad:   down
                     (cdir == 2'd1) ? m2d2 :   // diag "/":        bottom-left
                                       m2d0;    // diag "\":        bottom-right

// Asymmetric compare (strict on one side, non-strict on the other) so a
// hard, single-sample step edge -- where the Sobel response can come out
// exactly tied between two adjacent pixels -- still picks exactly one
// winner instead of keeping both (verified against tb_integration_nms.v,
// which chains the real sobel_edge.v into this module and hit exactly
// that tie on a synthetic step edge).
wire is_local_max = (m1d1 > nbr_a) && (m1d1 >= nbr_b);
wire [12:0] suppressed_mag = is_local_max ? m1d1 : 13'd0;

// Same border rule as sobel_edge.v: need a full 3x3 of real history.
wire window_valid = (px_d1 >= 11'd3) && (py_d1 >= 11'd2);
wire is_edge = window_valid && (suppressed_mag > EDGE_THRESH);

assign edge_r = is_edge ? 8'd255 : 8'd0;
assign edge_g = is_edge ? 8'd255 : 8'd0;
assign edge_b = is_edge ? 8'd255 : 8'd0;

endmodule
