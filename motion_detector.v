// motion_detector.v -- block-based frame differencing, v2 (block-averaged).
//
// Frame split into BLOCK x BLOCK cells (default 16x16 -> 30x17 grid, 510
// cells for the 480x272 panel). Each cell's "changed" decision uses the
// AVERAGE luma of all 256 pixels in the cell instead of one sample --
// averaging cuts sensor/AEC/flicker noise by ~sqrt(256)=16x, so DIFF_THRESH
// can be tight (sensitive to real motion) without false triggers. 256 = 2^8
// so the average is a free bit-shift, no divider.
//
// Implementation: while a block-row's 16 lines are being scanned, 30
// per-column accumulators (one per cell in that row) sum luma as pixels
// stream by. When the row's last line finishes (pixel_y[3:0]==15,
// pixel_x==479), a flush sequencer spends 30 clk_9m cycles walking the 30
// columns: average = accumulator>>8, compare vs stored previous average,
// update storage, clear the accumulator. 30 cycles fits well inside the
// ~45-cycle horizontal blanking gap.
//
// Storage: 30 x 17-bit column accumulators (~4.5Kbit) + 510 x 8-bit luma
// mem + 510 x 1-bit changed mem (~4.5Kbit) -- tiny against the EP4CE10's
// ~414Kbit of embedded RAM.
//
// Latency: a block average is only known once the whole cell is scanned, so
// a cell's "changed" flag can't affect the display until the start of the
// NEXT frame at that screen position. Uniform <1 frame latency, not visible
// at video rate.
//
// Tuning: point the camera at a static scene, watch changed_blocks (e.g.
// via SignalTap) -- noise floor should sit much lower than the old
// single-sample version. Raise MIN_BLOCKS/DIFF_THRESH only if it doesn't.
module motion_detector #(
    parameter integer BLOCK      = 16,
    parameter integer GRID_W     = 30,   // 480 / BLOCK
    parameter integer GRID_H     = 17,   // 272 / BLOCK
    parameter [7:0]   DIFF_THRESH = 8'd12,  // avg-luma delta to call a cell "changed"
    parameter [8:0]   MIN_BLOCKS  = 9'd4     // changed cells needed for motion_detected
)(
    input             clk,          // clk_9m
    input             rst_n,

    input             de,           // pixel valid strobe (lcd_de_w)
    input             frame_pulse,  // 1-cycle pulse, start of each LCD frame
    input      [7:0]  y8,           // luma of the pixel at pixel_x/pixel_y now
    input      [10:0] pixel_x,      // 0..479
    input      [10:0] pixel_y,      // 0..271

    output            highlight,       // 1 if this pixel's cell is flagged changed
    output reg        motion_detected, // latched once per frame
    output reg [8:0]  changed_blocks   // debug: changed-cell count, last frame
);

localparam integer NUM_BLOCKS   = GRID_W * GRID_H;      // 510
localparam integer LAST_COL_PX = GRID_W * BLOCK - 1;   // 479 at default sizing

// per-cell result storage
(* ramstyle = "M9K" *) reg [7:0] luma_mem    [0:NUM_BLOCKS-1];  // force block RAM, see sobel_edge.v
(* ramstyle = "M9K" *) reg       changed_mem [0:NUM_BLOCKS-1];  // same reason

// per-column (current block-row) running sum, 0..255*256.
// Left as plain distributed logic: only 30 entries, and it's a
// read-modify-write against a computed address every cycle rather than a
// simple store/fetch, not a great fit for block RAM anyway. Negligible
// LE cost at this size.
reg [16:0] col_sum [0:GRID_W-1];

integer init_i;
initial begin
    for (init_i = 0; init_i < NUM_BLOCKS; init_i = init_i + 1) begin
        luma_mem[init_i]    = 8'd0;
        changed_mem[init_i] = 1'b0;
    end
    for (init_i = 0; init_i < GRID_W; init_i = init_i + 1)
        col_sum[init_i] = 17'd0;
end

// pixel -> cell coordinates
wire [10:0] block_x = pixel_x >> 4;    // 0..29
wire [10:0] block_y = pixel_y >> 4;    // 0..16

// flush sequencer: fires once per block-row, 16 lines apart
reg        flushing;
reg [4:0]  flush_col;   // 0..29
reg [10:0] flush_by;    // block-row just completed

wire flush_trigger = de && !flushing &&
                      (pixel_x == LAST_COL_PX[10:0]) && (pixel_y[3:0] == 4'd15);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        flushing  <= 1'b0;
        flush_col <= 5'd0;
        flush_by  <= 11'd0;
    end
    else if (!flushing) begin
        if (flush_trigger) begin
            flushing  <= 1'b1;
            flush_col <= 5'd0;
            flush_by  <= block_y;
        end
    end
    else begin
        if (flush_col == GRID_W - 1)
            flushing <= 1'b0;
        else
            flush_col <= flush_col + 5'd1;
    end
end

// column accumulator: accumulate while scanning, clear on flush
always @(posedge clk) begin
    if (flushing)
        col_sum[flush_col] <= 17'd0;
    else if (de)
        col_sum[block_x] <= col_sum[block_x] + {9'd0, y8};
end

// flush-time compare/update. luma_mem's read here used to be a
// combinational `wire = luma_mem[flush_addr]`, same problem as
// sobel_edge.v's line buffers: M9K's read port is synchronous-only, so an
// async read can't map to it no matter what ramstyle says, and Quartus
// falls back to LE. Registering the read costs one cycle -- flush_addr_d1/
// cur_avg_d1/flushing_d1 carry the matching column's address and running
// average forward by that same cycle so the compare+write below stays
// aligned with the delayed read. Adds 1 cycle to the 30-cycle flush
// sequence (31 total), still comfortably inside the ~45-cycle h-blank gap.
wire [8:0] flush_addr = flush_by * GRID_W + flush_col;
wire [7:0] cur_avg    = col_sum[flush_col][16:8];   // /256, exact (max sum 65280)

reg        flushing_d1;
reg [8:0]  flush_addr_d1;
reg [7:0]  cur_avg_d1;
reg [7:0]  old_avg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        flushing_d1   <= 1'b0;
        flush_addr_d1 <= 9'd0;
        cur_avg_d1    <= 8'd0;
        old_avg       <= 8'd0;
    end
    else begin
        flushing_d1 <= flushing;
        if (flushing) begin
            old_avg       <= luma_mem[flush_addr];
            flush_addr_d1 <= flush_addr;
            cur_avg_d1    <= cur_avg;
        end
    end
end

wire signed [8:0] fd    = $signed({1'b0, cur_avg_d1}) - $signed({1'b0, old_avg});
wire        [7:0] fabsd = fd[8] ? (~fd[7:0] + 8'd1) : fd[7:0];
wire              changed_now = (fabsd > DIFF_THRESH);

always @(posedge clk) begin
    if (flushing_d1) begin
        luma_mem[flush_addr_d1]    <= cur_avg_d1;
        changed_mem[flush_addr_d1] <= changed_now;
    end
end

// display-side highlight: current pixel's cell, latest verdict. Also a
// registered read now -- shifts the highlight tint about 1 pixel column
// behind the actual image, same order of magnitude as the 1-pixel latency
// yuv422_to_rgb888 already has, not visible at video rate.
wire [8:0] disp_addr = block_y * GRID_W + block_x;
reg        highlight_r;
always @(posedge clk) highlight_r <= changed_mem[disp_addr];
assign highlight = highlight_r;

// frame-level changed-cell count / motion flag
reg [8:0] block_change_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        block_change_cnt <= 9'd0;
        changed_blocks   <= 9'd0;
        motion_detected  <= 1'b0;
    end
    else if (frame_pulse) begin
        changed_blocks   <= block_change_cnt;
        motion_detected  <= (block_change_cnt >= MIN_BLOCKS);
        block_change_cnt <= 9'd0;
    end
    else if (flushing_d1 && changed_now) begin
        block_change_cnt <= block_change_cnt + 9'd1;
    end
end

endmodule
