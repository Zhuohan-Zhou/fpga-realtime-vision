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

reg [12:0] mline_a [0:WIDTH-1];   // row N-2 magnitude
reg [12:0] mline_b [0:WIDTH-1];   // row N-1 magnitude
reg [1:0]  dline_b [0:WIDTH-1];   // row N-1 direction 
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


wire [1:0] cdir = dird1;

wire [12:0] nbr_a = (cdir == 2'd0) ? m1d2 :   // horizontal grad: left
                     (cdir == 2'd2) ? m0d1 :   // vertical grad:   up
                     (cdir == 2'd1) ? m0d0 :   // diag "/":        top-right
                                       m0d2;    // diag "\":        top-left

wire [12:0] nbr_b = (cdir == 2'd0) ? m1d0 :   // horizontal grad: right
                     (cdir == 2'd2) ? m2d1 :   // vertical grad:   down
                     (cdir == 2'd1) ? m2d2 :   // diag "/":        bottom-left
                                       m2d0;    // diag "\":        bottom-right

wire is_local_max = (m1d1 > nbr_a) && (m1d1 >= nbr_b);
wire [12:0] suppressed_mag = is_local_max ? m1d1 : 13'd0;

// Same border rule as sobel_edge.v: need a full 3x3 of real history.
wire window_valid = (px_d1 >= 11'd3) && (py_d1 >= 11'd2);
wire is_edge = window_valid && (suppressed_mag > EDGE_THRESH);

assign edge_r = is_edge ? 8'd255 : 8'd0;
assign edge_g = is_edge ? 8'd255 : 8'd0;
assign edge_b = is_edge ? 8'd255 : 8'd0;

endmodule
