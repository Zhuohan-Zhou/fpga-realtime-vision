// gaussian_blur3x3.v -- streaming 3x3 approximate Gaussian blur on the luma
// (y8) channel. Meant to sit ahead of sobel_edge.v: plain Sobel makes an
// independent edge/no-edge call at every pixel, so any spot where the local
// contrast dips even briefly (sensor noise, soft lighting) breaks the line.
// A blur pass first smooths that noise out, which is the standard first
// step of a real Canny pipeline too.
//
// Same architecture as sobel_edge.v (copy its header for the full
// rationale): two on-chip line buffers hold the previous two rows with a
// registered (synchronous) read -- required for M9K inference, an
// unregistered `wire = arr[idx]` read can't map to it -- and three
// horizontal 3-tap shift registers hold the live 3x3 neighborhood, one
// cycle behind de/pixel_x/pixel_y (de_d1/px_d1/py_d1).
//
// Kernel is the standard integer Gaussian approximation:
//   1 2 1
//   2 4 2     weights sum to 16, so the blur is an exact >>4, no divider
//   1 2 1
// All adds/shifts, no multiplier -- weight-2 taps are <<1, the weight-4
// center tap <<2.
//
// Outputs the delayed pixel_x/pixel_y/de alongside the blurred sample so
// whatever's downstream (sobel_edge.v) can treat this as its own live
// input stream instead of trying to re-derive the two cycles of latency
// this stage adds.
module gaussian_blur3x3 #(
    parameter integer WIDTH = 480
)(
    input             clk,      // clk_9m
    input             rst_n,
    input             de,       // pixel valid strobe (lcd_de_w)
    input      [7:0]  y8_in,    // raw luma of the pixel at pixel_x/pixel_y now
    input      [10:0] pixel_x,  // 0..479
    input      [10:0] pixel_y,  // 0..271

    output     [7:0]  y8_out,       // blurred luma
    output     [10:0] pixel_x_out,  // pixel_x/pixel_y/de delayed to match y8_out
    output     [10:0] pixel_y_out,
    output            de_out
);

reg [7:0] line_a [0:WIDTH-1];   // row N-2
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
            y8_d1 <= y8_in;
        end
    end
end

always @(posedge clk) begin
    if (de_d1) begin
        line_a[px_d1] <= lb;
        line_b[px_d1] <= y8_d1;
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

// 1 2 1 / 2 4 2 / 1 2 1, weights sum to 16 -> exact >>4
wire [11:0] wsum =
      {4'd0,p0d2} + ({4'd0,p0d1}<<<1) + {4'd0,p0d0}
    + ({4'd0,p1d2}<<<1) + ({4'd0,p1d1}<<<2) + ({4'd0,p1d0}<<<1)
    + {4'd0,p2d2} + ({4'd0,p2d1}<<<1) + {4'd0,p2d0};

wire [7:0] blurred = wsum[11:4];

// Same border logic as sobel_edge.v -- window isn't full yet for the first
// couple rows/cols, so just pass the raw center sample through unblurred
// rather than distort it with a partial window.
wire window_valid = (px_d1 >= 11'd3) && (py_d1 >= 11'd2);

assign y8_out      = window_valid ? blurred : p2d0;
assign pixel_x_out = px_d1;
assign pixel_y_out = py_d1;
assign de_out      = de_d1;

endmodule
