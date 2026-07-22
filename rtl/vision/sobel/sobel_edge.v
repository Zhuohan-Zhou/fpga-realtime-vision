module sobel_edge #(
    parameter integer WIDTH = 480
)(
    input             clk,      // clk_9m
    input             rst_n,
    input             de,       // pixel valid strobe (from gaussian_blur3x3's de_out)
    input      [7:0]  y8,       // luma of the pixel at pixel_x/pixel_y now
    input      [10:0] pixel_x,  // 0..479
    input      [10:0] pixel_y,  // 0..271

    
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


always @(posedge clk) begin
    if (de_d1) begin
        line_a[px_d1] <= lb;     // old row N-1 becomes row N-2
        line_b[px_d1] <= y8_d1;  // current row becomes row N-1
    end
end

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

wire gx_dominant = (abs_gx >= (abs_gy <<< 1));
wire gy_dominant = (abs_gy >= (abs_gx <<< 1));
wire same_sign   = (gx[11] == gy[11]);

wire [1:0] dir_code = gy_dominant ? 2'd2 :
                       gx_dominant ? 2'd0 :
                       same_sign   ? 2'd1 : 2'd3;

wire window_valid = (px_d1 >= 11'd3) && (py_d1 >= 11'd2);

assign magnitude    = window_valid ? mag_raw : 13'd0;
assign direction    = dir_code;
assign pixel_x_out  = px_d1;
assign pixel_y_out  = py_d1;
assign de_out       = de_d1;

endmodule
