module sdram_test_top (
    input         clk,          // 50MHz (PIN_E1)
    input         rst_n,        // reset (PIN_N13)
    output [3:0]  led,

    // SDRAM hardware pins
    output        sdram_clk,
    output        sdram_cke,
    output        sdram_cs_n,
    output        sdram_ras_n,
    output        sdram_cas_n,
    output        sdram_we_n,
    output [12:0] sdram_addr,
    output  [1:0] sdram_ba,
    output  [1:0] sdram_dqm,
    inout  [15:0] sdram_dq
);

// PLL
wire clk_100m, clk_24m, clk_9m, clk_sdram, pll_locked;

my_pll u_pll (
    .inclk0 (clk),
    .c0     (clk_100m),   // controller logic clock
    .c1     (clk_24m),    // unused here
    .c2     (clk_9m),     // unused here
    .c3     (clk_sdram),  // 100MHz -75deg for SDRAM chip
    .locked (pll_locked)
);

wire sys_rst_n = rst_n & pll_locked;

// SDRAM chip clock: phase-shifted PLL output, NOT the logic clock
assign sdram_clk = clk_sdram;

// Test parameters
localparam N_WORDS = 18'd130560;   // one full frame (480x272)

// Test pattern: unique-ish data per address, different per buffer
function [15:0] pat;
    input [17:0] i;
    input        b;
    begin
        pat = i[15:0] ^ {16{i[16]}} ^ (b ? 16'h5A5A : 16'h0000);
    end
endfunction

// SDRAM controller
reg         wr_fs, rd_fs;      // frame start pulses
reg         cur_buf;           // buffer under test
reg  [17:0] w_cnt, r_cnt;      // written / read word counters

wire        wr_ack, wr_ready, rd_valid, rd_ready;
wire [15:0] rd_data;

reg  [2:0]  tstate;
localparam T_WAIT_INIT = 3'd0;
localparam T_WR_START  = 3'd1;
localparam T_WRITE     = 3'd2;
localparam T_RD_START  = 3'd3;
localparam T_READ      = 3'd4;
localparam T_DONE      = 3'd5;

wire wr_en = (tstate == T_WRITE) && (w_cnt < N_WORDS);
wire rd_en = (tstate == T_READ)  && (r_cnt < N_WORDS);
wire [15:0] wr_data = pat(w_cnt, cur_buf);

sdram_ctrl u_sdram (
    .clk            (clk_100m),
    .rst_n          (sys_rst_n),

    .wr_en          (wr_en),
    .wr_data        (wr_data),
    .wr_ack         (wr_ack),
    .wr_ready       (wr_ready),
    .wr_frame_start (wr_fs),
    .wr_buf         (cur_buf),

    .rd_en          (rd_en),
    .rd_data        (rd_data),
    .rd_valid       (rd_valid),
    .rd_ready       (rd_ready),
    .rd_frame_start (rd_fs),
    .rd_buf         (cur_buf),

    .sdram_clk      (),            // pin driven by PLL c3 instead
    .sdram_cke      (sdram_cke),
    .sdram_cs_n     (sdram_cs_n),
    .sdram_ras_n    (sdram_ras_n),
    .sdram_cas_n    (sdram_cas_n),
    .sdram_we_n     (sdram_we_n),
    .sdram_addr     (sdram_addr),
    .sdram_ba       (sdram_ba),
    .sdram_dqm      (sdram_dqm),
    .sdram_dq       (sdram_dq)
);

// Test FSM
reg [17:0] err_cnt /* synthesis noprune */;

always @(posedge clk_100m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        tstate  <= T_WAIT_INIT;
        cur_buf <= 1'b0;
        w_cnt   <= 18'd0;
        r_cnt   <= 18'd0;
        err_cnt <= 18'd0;
        wr_fs   <= 1'b0;
        rd_fs   <= 1'b0;
    end
    else begin
        wr_fs <= 1'b0;
        rd_fs <= 1'b0;

        case (tstate)
            // Wait for controller init (wr_ready first goes high)
            T_WAIT_INIT: begin
                if (wr_ready)
                    tstate <= T_WR_START;
            end

            // Reset write address, start writing
            T_WR_START: begin
                wr_fs  <= 1'b1;
                w_cnt  <= 18'd0;
                tstate <= T_WRITE;
            end

            // Stream pattern; w_cnt advances one word per wr_ack
            T_WRITE: begin
                if (wr_ack)
                    w_cnt <= w_cnt + 1'b1;
                if (w_cnt == N_WORDS && wr_ready)
                    tstate <= T_RD_START;
            end

            // Reset read address, start reading
            T_RD_START: begin
                rd_fs  <= 1'b1;
                r_cnt  <= 18'd0;
                tstate <= T_READ;
            end

            // Compare each returned word against expected pattern
            T_READ: begin
                if (rd_valid) begin
                    if (rd_data != pat(r_cnt, cur_buf))
                        err_cnt <= err_cnt + 1'b1;
                    r_cnt <= r_cnt + 1'b1;
                end
                if (r_cnt == N_WORDS && rd_ready) begin
                    if (!cur_buf) begin
                        cur_buf <= 1'b1;       // test second buffer
                        tstate  <= T_WR_START;
                    end
                    else
                        tstate <= T_DONE;
                end
            end

            T_DONE: begin
                // stay here; result on LEDs
            end

            default: tstate <= T_DONE;
        endcase
    end
end

// Heartbeat
reg [26:0] hb_cnt;
always @(posedge clk_100m or negedge sys_rst_n) begin
    if (!sys_rst_n)
        hb_cnt <= 27'd0;
    else
        hb_cnt <= hb_cnt + 1'b1;
end

// LEDs
assign led[0] = (tstate != T_WAIT_INIT);                    // init done
assign led[1] = (tstate == T_DONE) && (err_cnt == 18'd0);   // PASS
assign led[2] = (tstate == T_DONE) && (err_cnt != 18'd0);   // FAIL
assign led[3] = hb_cnt[26];                                 // heartbeat

endmodule
