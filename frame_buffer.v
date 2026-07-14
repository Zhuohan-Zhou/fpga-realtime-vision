// frame_buffer.v -- ping-pong buffer: camera (pclk) -> SDRAM (100M) -> LCD (9M).
// Camera writes buffer A while LCD reads B; wr_buf toggles each camera frame,
// rd_buf follows (~wr_buf) latched at LCD frame start.
module frame_buffer (
    input         clk_100m,      // SDRAM logic clock
    input         rst_n,

    // Camera write side (pclk domain)
    input         pclk,
    input  [15:0] cam_data,
    input         cam_valid,
    input         cam_frame,     // 1-pclk pulse at camera frame start

    // LCD read side (lclk domain)
    input         lclk,          // 9MHz LCD pixel clock
    input         lcd_req,       // pop one pixel (connect lcd_de)
    input         lcd_frame,     // 1-lclk pulse at LCD frame start
    output [15:0] lcd_data,      // RGB565 pixel (show-ahead FIFO q)

    // SDRAM hardware pins
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

localparam FRAME_WORDS = 18'd130560;   // 480 x 272

// CDC: bring frame pulses into the 100MHz domain (toggle + sync)
reg cam_tog;
always @(posedge pclk or negedge rst_n)
    if (!rst_n)         cam_tog <= 1'b0;
    else if (cam_frame) cam_tog <= ~cam_tog;

reg lcd_tog;
always @(posedge lclk or negedge rst_n)
    if (!rst_n)         lcd_tog <= 1'b0;
    else if (lcd_frame) lcd_tog <= ~lcd_tog;

reg [2:0] cam_sync, lcd_sync;
always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n) begin
        cam_sync <= 3'b000;
        lcd_sync <= 3'b000;
    end
    else begin
        cam_sync <= {cam_sync[1:0], cam_tog};
        lcd_sync <= {lcd_sync[1:0], lcd_tog};
    end
end

wire cam_fp = cam_sync[2] ^ cam_sync[1];   // camera frame pulse @100M
wire lcd_fp = lcd_sync[2] ^ lcd_sync[1];   // LCD    frame pulse @100M

// Ping-pong buffer selection
reg wr_buf, rd_buf;
always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n) begin
        wr_buf <= 1'b0;
        rd_buf <= 1'b1;
    end
    else begin
        if (cam_fp) wr_buf <= ~wr_buf;
        if (lcd_fp) rd_buf <= cam_fp ? wr_buf : ~wr_buf; // always the idle buffer
    end
end

// FIFO clear pulses (stretched to 4 clks for async aclr)
reg [3:0] wclr_sr, rclr_sr;
always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n) begin
        wclr_sr <= 4'hF;
        rclr_sr <= 4'hF;
    end
    else begin
        wclr_sr <= cam_fp ? 4'hF : {wclr_sr[2:0], 1'b0};
        rclr_sr <= lcd_fp ? 4'hF : {rclr_sr[2:0], 1'b0};
    end
end
wire wfifo_clr = |wclr_sr;
wire rfifo_clr = |rclr_sr;

// Per-frame word counters (bound SDRAM traffic to one frame)
wire        wr_ack, wr_ready, rd_valid, rd_ready;
wire [15:0] wr_fifo_q, rd_sdram_data;

reg [17:0] wr_words, rd_words;
always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n) begin
        wr_words <= 18'd0;
        rd_words <= 18'd0;
    end
    else begin
        if (cam_fp)       wr_words <= 18'd0;
        else if (wr_ack)  wr_words <= wr_words + 1'b1;

        if (lcd_fp)       rd_words <= 18'd0;
        else if (rd_valid) rd_words <= rd_words + 1'b1;
    end
end

// FIFOs
wire [8:0] wfifo_used;   // words waiting on 100M side of write FIFO
wire [8:0] rfifo_used;   // words already in read FIFO (100M side)

pixel_fifo u_wr_fifo (
    .aclr    (wfifo_clr | ~rst_n),
    .wrclk   (pclk),
    .wrreq   (cam_valid),
    .data    (cam_data),
    .wrusedw (),
    .rdclk   (clk_100m),
    .rdreq   (wr_ack),        // controller pops 1 word/clk during burst
    .q       (wr_fifo_q),
    .rdusedw (wfifo_used)
);

pixel_fifo u_rd_fifo (
    .aclr    (rfifo_clr | ~rst_n),
    .wrclk   (clk_100m),
    .wrreq   (rd_valid),
    .data    (rd_sdram_data),
    .wrusedw (rfifo_used),
    .rdclk   (lclk),
    .rdreq   (lcd_req),
    .q       (lcd_data),
    .rdusedw ()
);

// Request policy:
//   write burst when >=4 pixels waiting and frame not fully written
//   read  burst when read FIFO has room and frame not fully read
wire wr_en = (wfifo_used >= 9'd4)   && (wr_words < FRAME_WORDS);
wire rd_en = (rfifo_used <  9'd400) && (rd_words < FRAME_WORDS);

// SDRAM controller
sdram_ctrl u_sdram (
    .clk            (clk_100m),
    .rst_n          (rst_n),

    .wr_en          (wr_en),
    .wr_data        (wr_fifo_q),
    .wr_ack         (wr_ack),
    .wr_ready       (wr_ready),
    .wr_frame_start (cam_fp),
    .wr_buf         (wr_buf),

    .rd_en          (rd_en),
    .rd_data        (rd_sdram_data),
    .rd_valid       (rd_valid),
    .rd_ready       (rd_ready),
    .rd_frame_start (lcd_fp),
    .rd_buf         (rd_buf),

    .sdram_clk      (),           // chip clock driven by PLL c3 at top level
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

endmodule
