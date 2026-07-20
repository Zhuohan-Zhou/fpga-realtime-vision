// kalman_1d.v -- 1D steady-state Kalman ("alpha-beta") filter for one axis
// of the color-blob centroid (x or y). Two instances run side by side in
// color_blob_tracker.v, one per axis.
//
// Full Kalman filtering carries a 2x2 covariance matrix and recomputes the
// gain every step from it (needs a divide by the innovation covariance).
// An alpha-beta filter is what that gain converges to once the covariance
// reaches steady state for roughly-constant process/measurement noise --
// mathematically the same idea, but the gains are fixed constants instead
// of something recomputed every frame, so there's no covariance bookkeeping
// and, if ALPHA/BETA are powers of two, no division at all -- just the
// shift/add style already used everywhere else in this pipeline.
//
// State is [pos, vel] in fixed point (FRAC_BITS fractional bits), updated
// once per LCD frame, not per pixel:
//
//   predict (pulsed at the start of a new frame, before this frame's color
//   measurement is even known yet -- pred_pos is latched and held for the
//   whole frame so color_blob_tracker.v's search window can be centered on
//   "where the target should be now" while pixels stream in):
//       pred_pos = pos + vel
//       pred_vel = vel
//
//   update (pulsed once the frame that just finished has been fully
//   scanned and its raw color centroid, if any, is known):
//       if accept:      innovation = meas - pred_pos
//                        pos = pred_pos + innovation >> ALPHA_SHIFT
//                        vel = pred_vel + innovation >> BETA_SHIFT
//       elif force_reset: pos = meas, vel = 0   -- fresh lock-on after being
//                          lost: snap straight to the new measurement
//                          instead of slowly blending in from a stale
//                          prediction (same reasoning the old EMA code used)
//       else (coast):    pos = pred_pos, vel = pred_vel
//
// Rejecting an implausible measurement (a different, distant object) is
// NOT decided in here -- color_blob_tracker.v computes that gate using
// both axes together (real-world distance, not per-axis), then just tells
// each instance whether to accept or coast this frame.
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
