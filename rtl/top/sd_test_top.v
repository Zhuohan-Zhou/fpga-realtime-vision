module sd_test_top (
    input        clk,          // 50MHz (PIN_E1)
    input        rst_n,        // (PIN_N13)
    output [3:0] led,

    output       sd_cs_n,      // PIN_D11 (SD_NCS)
    output       sd_clk,       // PIN_D12 (SD_CLK)
    output       sd_mosi,      // PIN_F10 (SD_DIN,  FPGA -> card)
    input        sd_miso       // PIN_E15 (SD_DOUT, card -> FPGA)
);

localparam BLOCK_BASE = 32'd2048;
localparam N_BLOCKS   = 4'd8;

wire        byte_req, wr_done, init_done;
wire [3:0]  err;
reg         wr_req;
reg  [31:0] wr_block;
reg  [3:0]  blk_cnt;
reg  [9:0]  byte_cnt;
reg  [1:0]  tstate;    // 0=wait init, 1=writing, 2=done

// test pattern byte
wire [7:0] wr_byte = byte_cnt[7:0] ^ wr_block[7:0];

sd_ctrl u_sd (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_req    (wr_req),
    .wr_block  (wr_block),
    .byte_req  (byte_req),
    .wr_byte   (wr_byte),
    .wr_done   (wr_done),
    .init_done (init_done),
    .err       (err),
    .sd_cs_n   (sd_cs_n),
    .sd_clk    (sd_clk),
    .sd_mosi   (sd_mosi),
    .sd_miso   (sd_miso)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tstate   <= 2'd0;
        wr_req   <= 1'b0;
        wr_block <= BLOCK_BASE;
        blk_cnt  <= 4'd0;
        byte_cnt <= 10'd0;
    end
    else begin
        wr_req <= 1'b0;

        if (byte_req)
            byte_cnt <= byte_cnt + 1'b1;

        case (tstate)
            2'd0: if (init_done) begin
                wr_block <= BLOCK_BASE;
                blk_cnt  <= 4'd0;
                byte_cnt <= 10'd0;
                wr_req   <= 1'b1;
                tstate   <= 2'd1;
            end

            2'd1: if (wr_done) begin
                if (blk_cnt == N_BLOCKS - 1'b1)
                    tstate <= 2'd2;
                else begin
                    blk_cnt  <= blk_cnt + 1'b1;
                    wr_block <= wr_block + 1'b1;
                    byte_cnt <= 10'd0;
                    wr_req   <= 1'b1;
                end
            end

            2'd2: ;  // done, hold

            default: ;
        endcase
    end
end

// heartbeat
reg [25:0] hb;
always @(posedge clk or negedge rst_n)
    if (!rst_n) hb <= 26'd0;
    else        hb <= hb + 1'b1;

assign led = (err != 4'd0) ? err
           : {hb[25], 1'b0, (tstate == 2'd2), init_done};

endmodule
