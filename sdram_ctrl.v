// sdram_ctrl.v -- SDRAM controller for Winbond W9825G6KH-6 (256Mbit, 16-bit bus).
// Clock 100MHz, burst length 4, CAS latency 2.
//
// Write port: wr_en + wr_data (streaming, 16-bit/clock)
// Read port:  rd_en -> rd_data + rd_valid (streaming)
// Frame sync: wr_frame_start / rd_frame_start reset addresses
//
// Handles init, auto-refresh, and all SDRAM timing internally.
module sdram_ctrl (
    input         clk,              // 100MHz SDRAM clock
    input         rst_n,

    // Write port (from camera DVP / write-side FIFO)
    input         wr_en,            // request: >=4 words available at wr_data
    input  [15:0] wr_data,          // pixel data (RGB565)
    output        wr_ack,           // high during S_WR: consume one word per clk
    output        wr_ready,         // controller can accept data
    input         wr_frame_start,   // pulse: reset write address to 0
    input         wr_buf,           // ping-pong buffer select for write (bank bit)

    // Read port (to LCD / read-side FIFO)
    input         rd_en,            // request one burst (4 words)
    output [15:0] rd_data,          // pixel data output
    output        rd_valid,         // rd_data is valid this cycle
    output        rd_ready,         // controller can supply data
    input         rd_frame_start,   // pulse: reset read address to 0
    input         rd_buf,           // ping-pong buffer select for read (bank bit)

    // SDRAM hardware pins
    output        sdram_clk,
    output reg    sdram_cke,
    output reg    sdram_cs_n,
    output reg    sdram_ras_n,
    output reg    sdram_cas_n,
    output reg    sdram_we_n,
    output reg [12:0] sdram_addr,
    output reg  [1:0] sdram_ba,
    output reg  [1:0] sdram_dqm,
    inout       [15:0] sdram_dq
);

// Timing parameters, in clock cycles @ 100MHz
localparam POWERUP_CLKS = 17'd20000;  // 200us
localparam TRP_CLKS     = 3'd2;       // Precharge time
localparam TRCD_CLKS    = 3'd2;       // RAS-to-CAS delay
localparam TRC_CLKS     = 3'd6;       // Row cycle time (for auto-refresh)
localparam TWR_CLKS     = 3'd2;       // Write recovery
localparam TMRD_CLKS    = 3'd2;       // Mode register delay
localparam CL_CLKS      = 3'd2;       // CAS latency
localparam BURST_LEN    = 3'd4;       // Burst length
localparam INIT_AREF_N  = 4'd8;       // # of auto-refresh during init
localparam AREF_PERIOD  = 10'd780;    // Refresh every 7.8us @ 100MHz

// Frame buffer size: 480x272 pixels = 130,560 words
localparam FRAME_SIZE   = 17'd130560;

// SDRAM commands {CS_n, RAS_n, CAS_n, WE_n}
localparam CMD_NOP       = 4'b0111;
localparam CMD_ACTIVE    = 4'b0011;
localparam CMD_READ      = 4'b0101;
localparam CMD_WRITE     = 4'b0100;
localparam CMD_PRECHARGE = 4'b0010;
localparam CMD_AREF      = 4'b0001;
localparam CMD_MRS       = 4'b0000;  // Mode Register Set

// Mode register: [2:0]=burst length 4 (3'b010), [3]=sequential (0),
// [6:4]=CAS latency 2 (3'b010), [9]=write burst mode (0=programmed burst)
localparam MODE_REG = 13'b000_0_010_0_010;

// State machine
localparam S_POWER_UP    = 5'd0;
localparam S_PRE_ALL     = 5'd1;
localparam S_INIT_AREF   = 5'd2;
localparam S_INIT_WAIT   = 5'd3;
localparam S_MRS         = 5'd4;
localparam S_MRS_WAIT    = 5'd5;
localparam S_IDLE        = 5'd6;
localparam S_AREF        = 5'd7;
localparam S_AREF_WAIT   = 5'd8;
localparam S_ACT_WR      = 5'd9;
localparam S_ACT_WR_WAIT = 5'd10;
localparam S_WR          = 5'd11;
localparam S_WR_WAIT     = 5'd12;
localparam S_PRE_WR      = 5'd13;
localparam S_PRE_WR_WAIT = 5'd14;
localparam S_ACT_RD      = 5'd15;
localparam S_ACT_RD_WAIT = 5'd16;
localparam S_RD          = 5'd17;
localparam S_RD_WAIT     = 5'd18;
localparam S_PRE_RD      = 5'd19;
localparam S_PRE_RD_WAIT = 5'd20;

reg [4:0] state;

// Counters
reg [16:0] power_cnt;    // power-up counter
reg  [9:0] aref_cnt;     // auto-refresh interval counter
reg  [3:0] init_aref_cnt;// init refresh count (0~8)
reg  [3:0] wait_cnt;     // general timing wait counter
reg  [2:0] burst_cnt;    // burst word counter (0~3)
reg        aref_req;     // auto-refresh request flag

// Frame address counters
reg [16:0] wr_addr;      // write pixel address (0~130559)
reg [16:0] rd_addr;      // read  pixel address (0~130559)

// Flat pixel address -> {bank, row, col}. W9825G6KH: 4 banks x 8192 rows x
// 512 cols x 16 bit. One frame = 130,560 words = 255 rows x 512 cols, fits
// in one bank. bank[0] = ping-pong buffer select, bank[1] = 0.
// row = addr[16:9] (0~254), col = {addr[8:2], 2'b00} burst-4 aligned

wire [1:0]  wr_bank = {1'b0, wr_buf};
wire [12:0] wr_row  = {5'd0, wr_addr[16:9]};
wire [8:0]  wr_col  = {wr_addr[8:2], 2'b00};

wire [1:0]  rd_bank = {1'b0, rd_buf};
wire [12:0] rd_row  = {5'd0, rd_addr[16:9]};
wire [8:0]  rd_col  = {rd_addr[8:2], 2'b00};

// DQ tri-state control
reg        dq_oe;        // 1 = FPGA drives DQ (write), 0 = SDRAM drives DQ (read)
reg [15:0] dq_out;
assign sdram_dq = dq_oe ? dq_out : 16'bz;

// Read data capture
reg [15:0] rd_data_reg;
reg        rd_valid_reg;
assign rd_data  = rd_data_reg;
assign rd_valid = rd_valid_reg;

// SDRAM clock: pass-through (Quartus places it in a GCLK buffer)
assign sdram_clk = clk;

// Status outputs. wr_ready/rd_ready: true when idle, no refresh pending.
assign wr_ready = (state == S_IDLE) && !aref_req;
assign rd_ready = (state == S_IDLE) && !aref_req;

// wr_ack: high on each of the 4 write burst beats. Connect to write-FIFO
// rdreq (FIFO in show-ahead mode): pops one word/clk.
assign wr_ack = (state == S_WR);

// Issue command helper: drives {cs_n, ras_n, cas_n, we_n}
task issue_cmd;
    input [3:0] cmd;
    input [12:0] addr;
    input  [1:0] ba;
    input  [1:0] dqm;
    begin
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= cmd;
        sdram_addr <= addr;
        sdram_ba   <= ba;
        sdram_dqm  <= dqm;
    end
endtask

// Auto-refresh request generation
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aref_cnt <= 10'd0;
        aref_req <= 1'b0;
    end
    else if (state == S_AREF) begin
        // Refresh being serviced, clear request and reset counter
        aref_cnt <= 10'd0;
        aref_req <= 1'b0;
    end
    else if (aref_cnt == AREF_PERIOD - 1'b1) begin
        aref_cnt <= 10'd0;
        aref_req <= 1'b1;
    end
    else begin
        aref_cnt <= aref_cnt + 1'b1;
    end
end

// Frame address management
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_addr <= 17'd0;
        rd_addr <= 17'd0;
    end
    else begin
        // Reset write address at start of each camera frame
        if (wr_frame_start)
            wr_addr <= 17'd0;
        else if (state == S_WR)
            wr_addr <= wr_addr + 1'b1;  // advance on all 4 burst beats

        // Reset read address at start of each LCD frame
        if (rd_frame_start)
            rd_addr <= 17'd0;
        else if (rd_valid_reg)
            rd_addr <= rd_addr + 1'b1;  // advance when data is output
    end
end

// Main state machine
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_POWER_UP;
        power_cnt      <= 17'd0;
        init_aref_cnt  <= 4'd0;
        wait_cnt       <= 4'd0;
        burst_cnt      <= 3'd0;
        sdram_cke      <= 1'b1;
        sdram_cs_n     <= 1'b1;
        sdram_ras_n    <= 1'b1;
        sdram_cas_n    <= 1'b1;
        sdram_we_n     <= 1'b1;
        sdram_addr     <= 13'd0;
        sdram_ba       <= 2'd0;
        sdram_dqm      <= 2'b11;
        dq_oe          <= 1'b0;
        dq_out         <= 16'd0;
        rd_data_reg    <= 16'd0;
        rd_valid_reg   <= 1'b0;
    end
    else begin
        // Default: clear valid pulse each cycle
        rd_valid_reg <= 1'b0;

        case (state)

            // INIT 1: wait 200us after power-up
            S_POWER_UP: begin
                sdram_cke <= 1'b1;
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (power_cnt == POWERUP_CLKS - 1'b1) begin
                    power_cnt <= 17'd0;
                    state     <= S_PRE_ALL;
                end
                else
                    power_cnt <= power_cnt + 1'b1;
            end

            // INIT 2: precharge all banks
            S_PRE_ALL: begin
                // A10=1 means "precharge all banks"
                issue_cmd(CMD_PRECHARGE, 13'b0_0100_0000_0000, 2'd0, 2'b11);
                wait_cnt <= TRP_CLKS - 1'b1;
                state    <= S_INIT_WAIT;
            end

            // INIT 3/4/5: 8x auto-refresh with waits
            S_INIT_AREF: begin
                issue_cmd(CMD_AREF, 13'd0, 2'd0, 2'b11);
                wait_cnt <= TRC_CLKS - 1'b1;
                state    <= S_INIT_WAIT;
            end

            S_INIT_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0) begin
                    if (init_aref_cnt < INIT_AREF_N) begin
                        init_aref_cnt <= init_aref_cnt + 1'b1;
                        state         <= S_INIT_AREF;
                    end
                    else
                        state <= S_MRS;
                end
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            // INIT 6: mode register set
            S_MRS: begin
                issue_cmd(CMD_MRS, MODE_REG, 2'd0, 2'b11);
                wait_cnt <= TMRD_CLKS - 1'b1;
                state    <= S_MRS_WAIT;
            end

            S_MRS_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_IDLE;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            // IDLE: arbitrate between refresh, write, read (priority: refresh > write > read)
            S_IDLE: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                dq_oe <= 1'b0;
                if (aref_req)
                    state <= S_AREF;
                else if (wr_en)
                    state <= S_ACT_WR;
                else if (rd_en)
                    state <= S_ACT_RD;
            end

          
            S_AREF: begin
                issue_cmd(CMD_AREF, 13'd0, 2'd0, 2'b11);
                wait_cnt <= TRC_CLKS - 1'b1;
                state    <= S_AREF_WAIT;
            end

            S_AREF_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_IDLE;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

       
            S_ACT_WR: begin
                // Activate the row that contains wr_addr
                issue_cmd(CMD_ACTIVE, wr_row, wr_bank, 2'b11);
                wait_cnt  <= TRCD_CLKS - 1'b1;
                burst_cnt <= 3'd0;
                state     <= S_ACT_WR_WAIT;
            end

            S_ACT_WR_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_WR;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            S_WR: begin
                // Issue WRITE command on first word, then NOP with data
                dq_oe  <= 1'b1;
                dq_out <= wr_data;
                sdram_dqm <= 2'b00;  // enable both bytes
                if (burst_cnt == 3'd0) begin
                    // First beat: send WRITE command with column address
                    issue_cmd(CMD_WRITE,
                              {4'b0000, wr_col},   // A10=0: no auto-precharge
                              wr_bank, 2'b00);
                end
                else begin
                    issue_cmd(CMD_NOP, 13'd0, sdram_ba, 2'b00);
                end
                burst_cnt <= burst_cnt + 1'b1;
                if (burst_cnt == BURST_LEN - 1'b1) begin
                    wait_cnt <= TWR_CLKS - 1'b1;
                    state    <= S_WR_WAIT;
                end
            end

            S_WR_WAIT: begin
                dq_oe <= 1'b0;
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_PRE_WR;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            S_PRE_WR: begin
                issue_cmd(CMD_PRECHARGE, 13'b0_0100_0000_0000, sdram_ba, 2'b11);
                wait_cnt <= TRP_CLKS - 1'b1;
                state    <= S_PRE_WR_WAIT;
            end

            S_PRE_WR_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_IDLE;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

  
            S_ACT_RD: begin
                issue_cmd(CMD_ACTIVE, rd_row, rd_bank, 2'b11);
                wait_cnt  <= TRCD_CLKS - 1'b1;
                burst_cnt <= 3'd0;
                state     <= S_ACT_RD_WAIT;
            end

            S_ACT_RD_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_RD;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            S_RD: begin
                dq_oe     <= 1'b0;
                sdram_dqm <= 2'b00;
                issue_cmd(CMD_READ,
                          {4'b0000, rd_col},
                          rd_bank, 2'b00);
                // After READ command, wait CL cycles before data appears
                wait_cnt  <= CL_CLKS + BURST_LEN - 1'b1;
                state     <= S_RD_WAIT;
            end

            S_RD_WAIT: begin
                // Keep DQM low during the whole read burst!
                // (DQM high here would mask the later data beats)
                issue_cmd(CMD_NOP, 13'd0, rd_bank, 2'b00);
                // Data arrives CL cycles after READ command
                // Capture exactly BURST_LEN beats (wait_cnt = 3,2,1,0)
                if (wait_cnt <= BURST_LEN - 1'b1) begin
                    rd_data_reg  <= sdram_dq;
                    rd_valid_reg <= 1'b1;
                end
                if (wait_cnt == 4'd0) begin
                    state <= S_PRE_RD;
                end
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            S_PRE_RD: begin
                issue_cmd(CMD_PRECHARGE, 13'b0_0100_0000_0000, sdram_ba, 2'b11);
                wait_cnt <= TRP_CLKS - 1'b1;
                state    <= S_PRE_RD_WAIT;
            end

            S_PRE_RD_WAIT: begin
                issue_cmd(CMD_NOP, 13'd0, 2'd0, 2'b11);
                if (wait_cnt == 4'd0)
                    state <= S_IDLE;
                else
                    wait_cnt <= wait_cnt - 1'b1;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule