// sobel_edge.v -- streaming 3x3 Sobel edge detector on the luma (y8) channel.
//
// Pixels arrive one at a time in raster order, so a 3x3 filter needs two
// on-chip line buffers holding the previous two lines' luma (480x8-bit
// each, ~3.75Kbit total). Each cycle: line_a (row N-2) <- line_b's old
// value (row N-1), line_b (row N-1) <- incoming pixel (row N). Three
// horizontal 3-tap shift regs (one per row) hold the live 3x3 neighborhood.
//
// Gx/Gy use only +-1/+-2 weights so the convolution is adds/subtracts/
// shifts only, no multiplier. Magnitude = |Gx|+|Gy| (city-block approx of
// sqrt(Gx^2+Gy^2), the usual choice for resource-constrained FPGA edge
// detectors), thresholded to white-on-black.
//
// Top-left 2 rows/columns of every frame don't have a full 3x3 neighborhood
// yet (buffers still filling) and get blanked to black -- normal for any
// streaming 3x3 filter.
module sobel_edge #(
    parameter integer WIDTH       = 480,
    parameter [11:0]  EDGE_THRESH = 12'd200   // tune: 0..~2040 (4*255 max per Gx/Gy)
)(
    input             clk,      // clk_9m
    input             rst_n,
    input             de,       // pixel valid strobe (lcd_de_w)
    input      [7:0]  y8,       // luma of the pixel at pixel_x/pixel_y now
    input      [10:0] pixel_x,  // 0..479
    input      [10:0] pixel_y,  // 0..271

    output     [7:0]  edge_r,
    output     [7:0]  edge_g,
    output     [7:0]  edge_b
);

// two-line rotating buffer. Force M9K: with a combinational read port,
// Quartus can fall back to LE-based distributed storage + a wide address
// mux for a 480-deep array, which costs way more than the ~4Kbit of actual
// data (the mux alone can hit four figures of LEs). ramstyle forces M9K
// regardless of coding-style ambiguity.
(* ramstyle = "M9K" *) reg [7:0] line_a [0:WIDTH-1];   // row N-2 (relative to the incoming row)
(* ramstyle = "M9K" *) reg [7:0] line_b [0:WIDTH-1];   // row N-1

integer init_i;
initial begin
    for (init_i = 0; init_i < WIDTH; init_i = init_i + 1) begin
        line_a[init_i] = 8'd0;
        line_b[init_i] = 8'd0;
    end
end

wire [7:0] la = line_a[pixel_x];
wire [7:0] lb = line_b[pixel_x];

always @(posedge clk) begin
    if (de) begin
        line_a[pixel_x] <= lb;   // old row N-1 becomes row N-2 for the next line
        line_b[pixel_x] <= y8;   // current row becomes row N-1 for the next line
    end
end

// 3x3 window: 3 rows x 3-tap horizontal shift regs.
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
    else if (de) begin
        p0d2 <= p0d1; p0d1 <= p0d0; p0d0 <= la;
        p1d2 <= p1d1; p1d1 <= p1d0; p1d0 <= lb;
        p2d2 <= p2d1; p2d1 <= p2d0; p2d0 <= y8;
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
wire [12:0] magnitude = {1'b0, abs_gx} + {1'b0, abs_gy};

// Need 2 full lines of real history before the 3x3 window is valid; blank
// the border otherwise. x threshold is 3, not 2: p0d0<=la happens the same
// cycle pixel_x is asserted but only ripples into d1/d2 on later cycles, so
// at pixel_x==2 the d2 tap still holds the previous line's trailing sample,
// not this line's column 0 -- caught in simulation (tb_sobel_edge.v) as
// false edges at x==2 on every row before this fix.
wire window_valid = (pixel_x >= 11'd3) && (pixel_y >= 11'd2);
wire is_edge = window_valid && (magnitude > {1'b0, EDGE_THRESH});

assign edge_r = is_edge ? 8'd255 : 8'd0;
assign edge_g = is_edge ? 8'd255 : 8'd0;
assign edge_b = is_edge ? 8'd255 : 8'd0;

endmodule
