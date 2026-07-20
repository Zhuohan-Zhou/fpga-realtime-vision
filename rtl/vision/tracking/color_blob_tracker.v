// color_blob_tracker.v -- streaming color-threshold blob detection +
// Kalman-filtered centroid tracking (v3).
//
// v1 was per-pixel RGB threshold -> frame-sum -> divide once per frame.
// v2 added EMA smoothing plus a search window locked onto the last
// position. v3 replaces the EMA with two independent 1D steady-state
// Kalman ("alpha-beta") filters (kalman_1d.v), one per axis, which buys
// two real improvements over EMA:
//
//  1) A motion model. EMA just blends toward the new measurement by a
//     fixed fraction every frame, with no notion of "which way is it
//     moving". The Kalman filters track position AND velocity, so the
//     predicted position for the next frame extrapolates along the
//     target's actual heading instead of always lagging behind it, and
//     the search window (now centered on that prediction, not the last
//     smoothed position) tracks ahead of a moving target.
//
//  2) Outlier rejection. If a same-color object other than the tracked
//     one appears (e.g. a face showing up inside the same red threshold
//     bracket used for a red object), its raw centroid can be far from
//     where the real target is predicted to be. gate_reject below checks
//     the (Manhattan) distance between the raw measurement and the
//     current prediction once we're actually locked onto something; too
//     far and the measurement is ignored for this frame -- the filters
//     just coast on their motion model instead of snapping to the
//     distractor. This is what actually fixes the crosshair jumping
//     between objects; Kalman smoothing alone would not have.
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
    parameter [17:0] MIN_PIXELS   = 18'd40,  // noise floor to call a frame "matched"
    parameter [10:0] WINDOW_HALF  = 11'd70,  // search-window half-size once locked on
    parameter integer FRAC_BITS   = 5,       // kalman_1d.v fixed-point fractional bits
    parameter integer ALPHA_SHIFT = 2,       // kalman_1d.v position gain = 1/2^ALPHA_SHIFT
    parameter integer BETA_SHIFT  = 5,       // kalman_1d.v velocity gain = 1/2^BETA_SHIFT
    parameter [10:0] GATE_DIST    = 11'd90,  // max plausible per-frame jump (L1, px) once locked on
    parameter integer MISS_LIMIT  = 15       // consecutive missed/rejected frames before "lost"
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

    output     [10:0] cx,           // Kalman-filtered, displayed centroid
    output     [10:0] cy,
    output reg        blob_found,   // 1 = currently locked on (see MISS_LIMIT)
    output reg        cx_valid,     // 1-cycle pulse: cx/cy just updated
    output reg [17:0] blob_pixels   // debug: matching pixel count, last frame
);

wire [10:0] pred_x, pred_y;   // this frame's predicted position, held for the whole frame

// per-pixel color threshold (combinational)
wire in_range = (r8 >= R_LO) && (r8 <= R_HI) &&
                (g8 >= G_LO) && (g8 <= G_HI) &&
                (b8 >= B_LO) && (b8 <= B_HI);

// search-window gate: full frame when not locked on, a box around the
// KALMAN PREDICTION for this frame once we are -- ahead of a moving
// target instead of centered on where it was last seen.
wire signed [11:0] wdx = $signed({1'b0, pixel_x}) - $signed({1'b0, pred_x});
wire signed [11:0] wdy = $signed({1'b0, pixel_y}) - $signed({1'b0, pred_y});
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

// shared sequential divider (time-multiplexed X then Y), unchanged from v2
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

// Two independent axis filters. Both always receive the SAME predict/
// update/accept/force_reset pulses -- the accept/reject decision below is
// computed once, from both axes together (real 2D distance), not as two
// per-axis decisions that could disagree about the same detection.
reg        k_predict, k_update, k_accept, k_reset;
reg [10:0] mx_reg, my_reg;

kalman_1d #(.FRAC_BITS(FRAC_BITS), .ALPHA_SHIFT(ALPHA_SHIFT), .BETA_SHIFT(BETA_SHIFT)) u_kx (
    .clk (clk), .rst_n (rst_n),
    .predict (k_predict), .update (k_update),
    .accept  (k_accept),  .force_reset (k_reset),
    .meas    (mx_reg),
    .pred_pos (pred_x), .pos (cx)
);

kalman_1d #(.FRAC_BITS(FRAC_BITS), .ALPHA_SHIFT(ALPHA_SHIFT), .BETA_SHIFT(BETA_SHIFT)) u_ky (
    .clk (clk), .rst_n (rst_n),
    .predict (k_predict), .update (k_update),
    .accept  (k_accept),  .force_reset (k_reset),
    .meas    (my_reg),
    .pred_pos (pred_y), .pos (cy)
);

localparam S_WAIT    = 3'd0,
           S_DIV_X   = 3'd1,
           S_DIV_Y   = 3'd2,
           S_APPLY   = 3'd3,
           S_NO_MEAS = 3'd4;

reg [2:0]  state;
reg [31:0] cap_sum_y;
reg [17:0] cap_count;
reg [7:0]  miss_streak;

// Outlier gate: is this frame's raw color centroid anywhere near where the
// tracked target is predicted to be? L1 (Manhattan) distance -- avoids a
// square root, same city-block-distance approximation used for the Sobel
// magnitude elsewhere in this project. Only applied once actually locked
// on (blob_found) -- while reacquiring after a loss there's no prediction
// worth trusting yet, so take whatever's found.
wire signed [11:0] gdx = $signed({1'b0, mx_reg}) - $signed({1'b0, pred_x});
wire signed [11:0] gdy = $signed({1'b0, my_reg}) - $signed({1'b0, pred_y});
wire        [11:0] gdx_abs = gdx[11] ? (~gdx + 12'd1) : gdx;
wire        [11:0] gdy_abs = gdy[11] ? (~gdy + 12'd1) : gdy;
wire        [12:0] gdist   = gdx_abs + gdy_abs;
wire               gate_reject = blob_found && (gdist > {1'b0, GATE_DIST});

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_WAIT;
        cap_sum_y    <= 32'd0;
        cap_count    <= 18'd0;
        div_start    <= 1'b0;
        div_dividend <= 32'd0;
        div_divisor  <= 32'd0;
        mx_reg       <= 11'd0;
        my_reg       <= 11'd0;
        blob_found   <= 1'b0;
        cx_valid     <= 1'b0;
        blob_pixels  <= 18'd0;
        miss_streak  <= 8'd0;
        k_predict    <= 1'b0;
        k_update     <= 1'b0;
        k_accept     <= 1'b0;
        k_reset      <= 1'b0;
    end
    else begin
        div_start <= 1'b0;
        cx_valid  <= 1'b0;
        k_predict <= 1'b0;
        k_update  <= 1'b0;

        case (state)
            S_WAIT: begin
                if (frame_pulse) begin
                    blob_pixels <= count;
                    k_predict   <= 1'b1;   // extrapolate last frame's state forward,
                                            // held in pred_x/pred_y for this whole frame

                    if (count >= MIN_PIXELS) begin
                        cap_sum_y    <= sum_y;
                        cap_count    <= count;
                        div_dividend <= sum_x;
                        div_divisor  <= {14'd0, count};
                        div_start    <= 1'b1;
                        state        <= S_DIV_X;
                    end
                    else begin
                        state <= S_NO_MEAS;
                    end
                end
            end

            S_DIV_X: begin
                if (div_done) begin
                    mx_reg       <= div_quotient[10:0];
                    div_dividend <= cap_sum_y;
                    div_divisor  <= {14'd0, cap_count};
                    div_start    <= 1'b1;
                    state        <= S_DIV_Y;
                end
            end

            S_DIV_Y: begin
                if (div_done) begin
                    my_reg <= div_quotient[10:0];
                    state  <= S_APPLY;
                end
            end

            S_APPLY: begin
                k_update <= 1'b1;
                k_accept <= !gate_reject;
                k_reset  <= !gate_reject && !blob_found;  // fresh lock-on: snap, don't blend

                if (!gate_reject) begin
                    blob_found  <= 1'b1;
                    miss_streak <= 8'd0;
                end
                else begin
                    miss_streak <= miss_streak + 8'd1;
                    if (miss_streak + 8'd1 >= MISS_LIMIT)
                        blob_found <= 1'b0;
                end
                cx_valid <= 1'b1;
                state    <= S_WAIT;
            end

            S_NO_MEAS: begin
                // no color match at all this frame -- coast on the motion
                // model rather than freezing or vanishing outright.
                k_update <= 1'b1;
                k_accept <= 1'b0;
                k_reset  <= 1'b0;
                miss_streak <= miss_streak + 8'd1;
                if (miss_streak + 8'd1 >= MISS_LIMIT)
                    blob_found <= 1'b0;
                state <= S_WAIT;
            end

            default: state <= S_WAIT;
        endcase
    end
end

endmodule
