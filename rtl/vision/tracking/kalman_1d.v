module kalman_1d #(
    parameter integer FRAC_BITS   = 5,   // fixed-point fractional bits for pos/vel
    parameter integer ALPHA_SHIFT = 2,   // position gain = 1/2^ALPHA_SHIFT (bigger shift = gentler)
    parameter integer BETA_SHIFT  = 5    // velocity gain = 1/2^BETA_SHIFT
)(
    input             clk,
    input             rst_n,

    input             predict,      // 1-cycle pulse: latch pos+vel -> pred_pos/pred_vel
    input             update,       // 1-cycle pulse: commit this frame's result
    input             accept,       // valid alongside `update`: apply `meas`
    input             force_reset,  // valid alongside `update` && accept: snap instead of blend
    input      [10:0] meas,         // raw measurement, valid alongside `update`

    output reg [10:0] pred_pos,     // held for the whole frame -- search window center
    output     [10:0] pos           // filtered position (integer, truncated)
);

localparam integer FP = FRAC_BITS;

reg signed [20:0] pos_fp, vel_fp;            // committed state, carried frame to frame
reg signed [20:0] pred_pos_fp, pred_vel_fp;  // latched at `predict`, consumed by the next `update`

wire signed [20:0] meas_fp = {{(21-11-FP){1'b0}}, meas, {FP{1'b0}}};
wire signed [20:0] innov   = meas_fp - pred_pos_fp;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pos_fp      <= 21'sd0;
        vel_fp      <= 21'sd0;
        pred_pos_fp <= 21'sd0;
        pred_vel_fp <= 21'sd0;
        pred_pos    <= 11'd0;
    end
    else begin
        if (predict) begin
            pred_pos_fp <= pos_fp + vel_fp;
            pred_vel_fp <= vel_fp;
            pred_pos    <= (pos_fp + vel_fp) >>> FP;
        end
        if (update) begin
            if (accept && force_reset) begin
                pos_fp <= meas_fp;
                vel_fp <= 21'sd0;
            end
            else if (accept) begin
                pos_fp <= pred_pos_fp + (innov >>> ALPHA_SHIFT);
                vel_fp <= pred_vel_fp + (innov >>> BETA_SHIFT);
            end
            else begin
                pos_fp <= pred_pos_fp;
                vel_fp <= pred_vel_fp;
            end
        end
    end
end

assign pos = pos_fp[(FP+10):FP];

endmodule
