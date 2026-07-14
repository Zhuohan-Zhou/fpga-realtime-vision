// color_blob_tracker.v -- streaming color-threshold blob detection + centroid
// tracking (v2). v1 was just per-pixel RGB threshold -> frame-sum -> divide
// once per frame. v2 adds two things on top:
//
//  1) EMA smoothing on the reported centroid: cx/cy move 1/2^EMA_SHIFT of the
//     way toward the new measurement each frame instead of snapping to it.
//     Kills frame-to-frame jitter from sensor/threshold noise without adding
//     noticeable lag at video rate.
//
//  2) A search window centered on the last known (smoothed) position: once
//     locked on, only pixels within +/-WINDOW_HALF of cx/cy count toward the
//     next centroid, so same-color clutter elsewhere can't drag it off the
//     real object. If the window's pixel count drops below MIN_PIXELS (track
//     lost), the next frame falls back to a full-frame search to reacquire.
//
// Runs in clk_9m, tapping the same r8/g8/b8 (post yuv422_to_rgb888) and
// pixel_x/pixel_y (from lcd_driver) that already feed the display.
module color_blob_tracker #(
    parameter [7:0]  R_LO = 8'd140,   // default: bracket for a red object
    parameter [7:0]  R_HI = 8'd255,
    parameter [7:0]  G_LO = 8'd0,
    parameter [7:0]  G_HI = 8'd110,
    parameter [7:0]  B_LO = 8'd0,
    parameter [7:0]  B_HI = 8'd110,
    parameter [17:0] MIN_PIXELS  = 18'd40,  // noise floor to call it "found"
    parameter [10:0] WINDOW_HALF = 11'd70,  // search-window half-size once locked on
    parameter integer EMA_SHIFT  = 2        // smoothing time-constant (bigger = smoother/slower)
)(
    input             clk,          // clk_9m
    input             rst_n,

    input             de,           // pixel valid strobe (lcd_de_w)
    input             frame_pulse,  // 1-cycle pulse, start of each LCD frame
    input      [7:0]  r8,
    input      [7:0]  g8,
    input      [7:0]  b8,
    input      [10:0] pixel_x,      // 0..479
    input      [10:0] pixel_y,      // 0..271

    output reg [10:0] cx,           // smoothed, displayed centroid
    output reg [10:0] cy,
    output reg        blob_found,   // 1 = last frame had >= MIN_PIXELS matches
    output reg        cx_valid,     // 1-cycle pulse: cx/cy just updated
    output reg [17:0] blob_pixels   // debug: matching pixel count, last frame
);

// per-pixel color threshold (combinational)
wire in_range = (r8 >= R_LO) && (r8 <= R_HI) &&
                (g8 >= G_LO) && (g8 <= G_HI) &&
                (b8 >= B_LO) && (b8 <= B_HI);

// search-window gate: full frame when not locked on, a box around the
// last smoothed position once we are
wire signed [11:0] wdx = $signed({1'b0, pixel_x}) - $signed({1'b0, cx});
wire signed [11:0] wdy = $signed({1'b0, pixel_y}) - $signed({1'b0, cy});
wire signed [11:0] win_half_s = $signed({1'b0, WINDOW_HALF});
wire in_window = (!blob_found) ||
                 ((wdx >= -win_half_s) && (wdx <= win_half_s) &&
                  (wdy >= -win_half_s) && (wdy <= win_half_s));

wire gated_match = in_range && in_window;

// running accumulators, reset every frame
reg [31:0] sum_x, sum_y;
reg [17:0] count;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sum_x <= 32'd0;
        sum_y <= 32'd0;
        count <= 18'd0;
    end
    else if (frame_pulse) begin
        sum_x <= 32'd0;
        sum_y <= 32'd0;
        count <= 18'd0;
    end
    else if (de && gated_match) begin
        sum_x <= sum_x + {21'd0, pixel_x};
        sum_y <= sum_y + {21'd0, pixel_y};
        count <= count + 18'd1;
    end
end

// shared sequential divider (time-multiplexed X then Y)
reg        div_start;
reg [31:0] div_dividend, div_divisor;
wire       div_busy, div_done;
wire [31:0] div_quotient;

seq_divider #(.WIDTH(32)) u_div (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (div_start),
    .dividend (div_dividend),
    .divisor  (div_divisor),
    .busy     (div_busy),
    .done     (div_done),
    .quotient (div_quotient)
);

localparam S_WAIT  = 2'd0,
           S_DIV_X = 2'd1,
           S_DIV_Y = 2'd2;

reg [1:0]  state;
reg [31:0] cap_sum_y;
reg [17:0] cap_count;

// EMA blend: new = old + (raw - old) / 2^EMA_SHIFT, done in a wide signed
// temporary then truncated back. Result is always a convex combination of
// two valid 0..479-ish values, so it can't leave the valid range.
//
// Exception: if we weren't locked on going into this measurement
// (blob_found==0, fresh reacquisition), snap straight to the raw
// measurement instead of blending. Otherwise the window gate (still
// centered on the stale position) can keep excluding the object we just
// reacquired -- a slow tug-of-war instead of a clean reacquire.
wire signed [11:0] cx_raw_s = $signed({1'b0, div_quotient[10:0]});
wire signed [11:0] cy_raw_s = $signed({1'b0, div_quotient[10:0]});
wire signed [11:0] cx_err   = cx_raw_s - $signed({1'b0, cx});
wire signed [11:0] cy_err   = cy_raw_s - $signed({1'b0, cy});
wire signed [11:0] cx_new_s = blob_found ? ($signed({1'b0, cx}) + (cx_err >>> EMA_SHIFT)) : cx_raw_s;
wire signed [11:0] cy_new_s = blob_found ? ($signed({1'b0, cy}) + (cy_err >>> EMA_SHIFT)) : cy_raw_s;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_WAIT;
        cap_sum_y    <= 32'd0;
        cap_count    <= 18'd0;
        div_start    <= 1'b0;
        div_dividend <= 32'd0;
        div_divisor  <= 32'd0;
        cx           <= 11'd0;
        cy           <= 11'd0;
        blob_found   <= 1'b0;
        cx_valid     <= 1'b0;
        blob_pixels  <= 18'd0;
    end
    else begin
        div_start <= 1'b0;
        cx_valid  <= 1'b0;

        case (state)
            S_WAIT: begin
                if (frame_pulse) begin
                    blob_pixels <= count;

                    if (count >= MIN_PIXELS) begin
                        cap_sum_y    <= sum_y;
                        cap_count    <= count;
                        div_dividend <= sum_x;
                        div_divisor  <= {14'd0, count};
                        div_start    <= 1'b1;
                        state        <= S_DIV_X;
                    end
                    else begin
                        blob_found <= 1'b0;   // too few matching px: no blob
                    end
                end
            end

            S_DIV_X: begin
                if (div_done) begin
                    cx           <= cx_new_s[10:0];   // EMA-smoothed
                    div_dividend <= cap_sum_y;
                    div_divisor  <= {14'd0, cap_count};
                    div_start    <= 1'b1;
                    state        <= S_DIV_Y;
                end
            end

            S_DIV_Y: begin
                if (div_done) begin
                    cy         <= cy_new_s[10:0];     // EMA-smoothed
                    blob_found <= 1'b1;
                    cx_valid   <= 1'b1;
                    state      <= S_WAIT;
                end
            end

            default: state <= S_WAIT;
        endcase
    end
end

endmodule
