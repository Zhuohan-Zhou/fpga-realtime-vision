// sd_ctrl.v -- SD card controller, SPI mode. Init (SDHC) + single-block write.
// Init: 74+ dummy clocks -> CMD0 -> CMD8 -> ACMD41 loop -> CMD58 (check CCS)
// -> fast clock -> ready. Write: CMD24, token 0xFE, 512 bytes, dummy CRC,
// response, busy. Requires SDHC/SDXC (block addressing); error code on 'err'.
//
// Write handshake (same style as sdram_ctrl wr_ack): pulse wr_req with
// wr_block valid, then supply one byte on wr_byte each time byte_req
// pulses (512 total); wr_done pulses when the block is written.
module sd_ctrl (
    input             clk,        // 50MHz
    input             rst_n,

    // user interface
    input             wr_req,     // pulse: write one 512-byte block
    input      [31:0] wr_block,   // block address (SDHC: block number)
    output reg        byte_req,   // pulse: consume wr_byte now
    input       [7:0] wr_byte,
    output reg        wr_done,    // pulse: block written OK
    output reg        init_done,
    output reg  [3:0] err,        // 0=none 1=CMD0 2=CMD8 3=ACMD41 4=wr_resp 5=busy_tmo

    // SD card pins (SPI mode)
    output reg        sd_cs_n,
    output            sd_clk,
    output            sd_mosi,
    input             sd_miso
);

// SPI byte engine
reg        spi_speed;
reg        spi_start;
reg  [7:0] spi_tx;
wire [7:0] spi_rx;
wire       spi_done, spi_busy;

sd_spi u_spi (
    .clk      (clk),
    .rst_n    (rst_n),
    .speed    (spi_speed),
    .start    (spi_start),
    .tx_byte  (spi_tx),
    .rx_byte  (spi_rx),
    .done     (spi_done),
    .busy     (spi_busy),
    .spi_clk  (sd_clk),
    .spi_mosi (sd_mosi),
    .spi_miso (sd_miso)
);

// Main FSM
localparam ST_POWER      = 5'd0;   // wait 10ms after power-up
localparam ST_DUMMY      = 5'd1;   // 10 x 0xFF with CS high (>74 clocks)
localparam ST_CMD_SEND   = 5'd2;   // shared: send 6-byte command
localparam ST_CMD_R1     = 5'd3;   // shared: poll for R1 (up to 16 bytes)
localparam ST_CMD_EXTRA  = 5'd4;   // shared: read extra response bytes
localparam ST_CMD0_CHK   = 5'd5;
localparam ST_CMD8_CHK   = 5'd6;
localparam ST_CMD55_CHK  = 5'd7;
localparam ST_ACMD41_CHK = 5'd8;
localparam ST_CMD58_CHK  = 5'd9;
localparam ST_READY      = 5'd10;  // init done, wait for wr_req
localparam ST_W_CMD_CHK  = 5'd11;  // CMD24 R1 check
localparam ST_W_GAP      = 5'd12;  // one 0xFF gap byte
localparam ST_W_TOKEN    = 5'd13;  // send 0xFE
localparam ST_W_DATA     = 5'd14;  // 512 data bytes
localparam ST_W_CRC      = 5'd15;  // 2 dummy CRC bytes
localparam ST_W_RESP     = 5'd16;  // data response byte
localparam ST_W_BUSY     = 5'd17;  // wait while card pulls MISO low
localparam ST_ERROR      = 5'd18;
localparam ST_CMD_SYNC   = 5'd19;  // clock 0xFF until card reads back 0xFF (ready)
localparam ST_A41_WAIT   = 5'd20;  // 1ms pause between ACMD41 polls
localparam ST_CMD1_CHK   = 5'd21;  // CMD1 fallback init (cards with broken
                                   // SPI ACMD path; FatFs does the same)

reg [4:0] state;
reg [4:0] ret_state;      // where shared CMD engine returns to

// command buffer
reg [7:0]  cmd_buf [0:5];
reg [2:0]  cmd_idx;
reg [4:0]  poll_cnt;
reg [7:0]  r1;
reg [31:0] resp32;
reg [2:0]  extra_cnt;

reg [19:0] delay_cnt;     // power-up delay / busy timeout
reg [15:0] retry_cnt;     // ACMD41 retries
reg [3:0]  dummy_cnt;
reg [9:0]  data_cnt;      // 0..511
reg [7:0]  sync_cnt;      // wait-ready byte counter
reg        use_cmd1;      // 0: CMD55+ACMD41 path, 1: CMD1 fallback path

// helper: load a command into cmd_buf
task set_cmd;
    input [5:0]  idx;
    input [31:0] arg;
    input [7:0]  crc;
    input [2:0]  extra;
    input [4:0]  chk_state;
    begin
        cmd_buf[0] <= {2'b01, idx};
        cmd_buf[1] <= arg[31:24];
        cmd_buf[2] <= arg[23:16];
        cmd_buf[3] <= arg[15:8];
        cmd_buf[4] <= arg[7:0];
        cmd_buf[5] <= crc;
        cmd_idx    <= 3'd0;
        poll_cnt   <= 5'd0;
        extra_cnt  <= extra;
        ret_state  <= chk_state;
        sync_cnt   <= 8'd0;
        state      <= ST_CMD_SYNC;   // wait until card is ready, then send
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= ST_POWER;
        sd_cs_n    <= 1'b1;
        spi_speed  <= 1'b0;
        spi_start  <= 1'b0;
        spi_tx     <= 8'hFF;
        init_done  <= 1'b0;
        err        <= 4'd0;
        byte_req   <= 1'b0;
        wr_done    <= 1'b0;
        delay_cnt  <= 20'd500_000;   // 10ms @50MHz
        retry_cnt  <= 16'd0;
        dummy_cnt  <= 4'd0;
        data_cnt   <= 10'd0;
        sync_cnt   <= 8'd0;
        use_cmd1   <= 1'b0;
        cmd_idx    <= 3'd0;
        poll_cnt   <= 5'd0;
        extra_cnt  <= 3'd0;
        ret_state  <= ST_ERROR;
        r1         <= 8'hFF;
        resp32     <= 32'd0;
    end
    else begin
        spi_start <= 1'b0;
        byte_req  <= 1'b0;
        wr_done   <= 1'b0;

        case (state)

            // power-up wait
            ST_POWER: begin
                if (delay_cnt == 20'd0) begin
                    dummy_cnt <= 4'd0;
                    state     <= ST_DUMMY;
                end
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // >=74 clocks with CS high
            ST_DUMMY: begin
                sd_cs_n <= 1'b1;
                if (spi_done) begin
                    if (dummy_cnt == 4'd9) begin
                        sd_cs_n <= 1'b0;
                        set_cmd(6'd0, 32'h0, 8'h95, 3'd0, ST_CMD0_CHK);
                    end
                    else
                        dummy_cnt <= dummy_cnt + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            // shared command engine
            ST_CMD_SYNC: begin
                // FatFs-style deselect/select before every command:
                // byte 0 = CS high + 0xFF (deselect, resyncs card decoder),
                // byte 1 = CS low + 0xFF (select), byte 2+ = 0xFF until card
                // reads back 0xFF (wait ready)
                if (spi_done) begin
                    if (sync_cnt == 8'd0) begin
                        sd_cs_n  <= 1'b0;            // deselect done -> select
                        sync_cnt <= 8'd1;
                    end
                    else if (spi_rx == 8'hFF || sync_cnt == 8'd255)
                        state <= ST_CMD_SEND;
                    else
                        sync_cnt <= sync_cnt + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    if (sync_cnt == 8'd0)
                        sd_cs_n <= 1'b1;             // first byte with CS high
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_CMD_SEND: begin
                if (spi_done) begin
                    if (cmd_idx == 3'd5)
                        state <= ST_CMD_R1;
                    else
                        cmd_idx <= cmd_idx + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= cmd_buf[cmd_idx];
                    spi_start <= 1'b1;
                end
            end

            ST_CMD_R1: begin
                if (spi_done) begin
                    if (!spi_rx[7]) begin        // valid R1 (bit7=0)
                        r1     <= spi_rx;
                        resp32 <= 32'd0;
                        state  <= (extra_cnt != 3'd0) ? ST_CMD_EXTRA : ret_state;
                    end
                    else if (poll_cnt == 5'd31) begin   // widened window (was 16)
                        r1    <= 8'hFF;          // no response
                        state <= ret_state;
                    end
                    else
                        poll_cnt <= poll_cnt + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_CMD_EXTRA: begin                  // R3/R7 trailing 4 bytes
                if (spi_done) begin
                    resp32 <= {resp32[23:0], spi_rx};
                    if (extra_cnt == 3'd1)
                        state <= ret_state;
                    extra_cnt <= extra_cnt - 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            // init sequence checks
            ST_CMD0_CHK: begin
                if (r1 == 8'h01)
                    set_cmd(6'd8, 32'h000001AA, 8'h87, 3'd4, ST_CMD8_CHK);
                else begin
                    err   <= 4'd1;
                    state <= ST_ERROR;
                end
            end

            ST_CMD8_CHK: begin
                if (r1 == 8'h01 && resp32[11:0] == 12'h1AA) begin
                    retry_cnt <= 16'd0;
                    use_cmd1  <= 1'b0;
                    set_cmd(6'd55, 32'h0, 8'h65, 3'd0, ST_CMD55_CHK);
                end
                else begin
                    err   <= 4'd2;   // old (V1) card or no card
                    state <= ST_ERROR;
                end
            end

            ST_CMD55_CHK: begin
                // ACMD41 with HCS=1 (announce SDHC support), real CRC
                set_cmd(6'd41, 32'h40000000, 8'h77, 3'd0, ST_ACMD41_CHK);
            end

            ST_ACMD41_CHK: begin
                if (r1 == 8'h00)
                    set_cmd(6'd58, 32'h0, 8'hFD, 3'd4, ST_CMD58_CHK);  // real CRC
                else if (retry_cnt == 16'd300) begin
                    // ~0.5s of ACMD41 with no luck -> this card's SPI ACMD
                    // path is broken, fall back to CMD1 init (like FatFs)
                    use_cmd1  <= 1'b1;
                    retry_cnt <= 16'd0;
                    delay_cnt <= 20'd50_000;
                    state     <= ST_A41_WAIT;
                end
                else begin
                    retry_cnt <= retry_cnt + 1'b1;
                    delay_cnt <= 20'd50_000;     // 1ms between polls
                    state     <= ST_A41_WAIT;
                end
            end

            ST_A41_WAIT: begin
                if (delay_cnt == 20'd0) begin
                    if (use_cmd1)
                        set_cmd(6'd1, 32'h40000000, 8'h6B, 3'd0, ST_CMD1_CHK);
                    else
                        set_cmd(6'd55, 32'h0, 8'h65, 3'd0, ST_CMD55_CHK);
                end
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // CMD1 fallback: poll until card leaves idle
            ST_CMD1_CHK: begin
                if (r1 == 8'h00)
                    set_cmd(6'd58, 32'h0, 8'hFD, 3'd4, ST_CMD58_CHK);
                else if (retry_cnt == 16'd2000) begin   // ~3s then report
                    //  12 (1100): CMD1 also silent (r1==FF)
                    //  13 (1101): CMD1 answers but stuck idle (r1==01)
                    //   9 (1001): anything else
                    if      (r1 == 8'hFF) err <= 4'd12;
                    else if (r1 == 8'h01) err <= 4'd13;
                    else                  err <= 4'd9;
                    state <= ST_ERROR;
                end
                else begin
                    retry_cnt <= retry_cnt + 1'b1;
                    delay_cnt <= 20'd50_000;
                    state     <= ST_A41_WAIT;
                end
            end

            ST_CMD58_CHK: begin
                // resp32[30] = CCS: 1 = SDHC block addressing (required)
                spi_speed <= 1'b1;               // switch to 12.5MHz
                init_done <= 1'b1;
                state     <= ST_READY;
            end

            // ready / write flow
            ST_READY: begin
                if (wr_req)
                    set_cmd(6'd24, wr_block, 8'h01, 3'd0, ST_W_CMD_CHK);
            end

            ST_W_CMD_CHK: begin
                if (r1 == 8'h00)
                    state <= ST_W_GAP;
                else begin
                    err   <= 4'd4;
                    state <= ST_ERROR;
                end
            end

            ST_W_GAP: begin                      // one 0xFF before token
                if (spi_done)
                    state <= ST_W_TOKEN;
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_W_TOKEN: begin
                if (spi_done) begin
                    data_cnt <= 10'd0;
                    state    <= ST_W_DATA;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFE;          // single-block start token
                    spi_start <= 1'b1;
                end
            end

            ST_W_DATA: begin
                if (spi_done) begin
                    if (data_cnt == 10'd511)
                        state <= ST_W_CRC;
                    data_cnt <= data_cnt + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= wr_byte;        // consume user byte
                    byte_req  <= 1'b1;
                    spi_start <= 1'b1;
                end
            end

            ST_W_CRC: begin                      // 2 dummy CRC bytes
                if (spi_done) begin
                    if (data_cnt[0])             // reuse counter low bit
                        state <= ST_W_RESP;
                    data_cnt <= data_cnt + 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_W_RESP: begin
                if (spi_done) begin
                    if (spi_rx[4:0] == 5'b00101) begin  // data accepted
                        delay_cnt <= 20'hFFFFF;         // busy timeout ~21ms
                        state     <= ST_W_BUSY;
                    end
                    else begin
                        err   <= 4'd4;
                        state <= ST_ERROR;
                    end
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_W_BUSY: begin
                if (spi_done) begin
                    if (spi_rx == 8'hFF) begin   // card released busy
                        wr_done <= 1'b1;
                        state   <= ST_READY;
                    end
                    else if (delay_cnt == 20'd0) begin
                        err   <= 4'd5;
                        state <= ST_ERROR;
                    end
                    else
                        delay_cnt <= delay_cnt - 1'b1;
                end
                else if (!spi_busy && !spi_start) begin
                    spi_tx    <= 8'hFF;
                    spi_start <= 1'b1;
                end
            end

            ST_ERROR: begin
                sd_cs_n <= 1'b1;                 // park; err holds the code
            end

            default: state <= ST_ERROR;
        endcase
    end
end

endmodule
