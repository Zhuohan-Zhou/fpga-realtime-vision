// ov5640_init.v -- init sequence controller. Walks the register table ROM
// and shoots each entry out over the SCCB master. Output: 480x272 @ ~30fps.
module ov5640_init (
    input        clk,          // 50MHz system clock
    input        rst_n,        // system reset (active low)

    // SCCB master interface
    output reg        sccb_start,   // pulse: start one SCCB write
    output reg [7:0]  sccb_dev,     // device address (0x78)
    output reg [15:0] sccb_reg,      // register address
    output reg [7:0]  sccb_data,    // register data
    input             sccb_done,    // pulse: SCCB write complete
    input             sccb_busy,    // SCCB master busy

    // Control outputs
    output reg        cam_rst_n,    // OV5640 RESET pin (active low)
    output reg        cam_pwdn,     // OV5640 PWDN  pin (active high = power down)

    // Status
    output reg        init_done     // high when all registers written
);

// timing constants @ 50MHz
localparam DELAY_20MS  = 22'd1_000_000;  // 20ms
localparam DELAY_10MS  = 22'd500_000;    // 10ms
localparam DELAY_5MS   = 22'd250_000;    // 5ms

// state machine
localparam S_PWDN_HIGH   = 4'd0;   // Assert power-down first
localparam S_WAIT_PWDN   = 4'd1;   // Wait 20ms
localparam S_PWDN_LOW    = 4'd2;   // Release power-down
localparam S_RST_LOW     = 4'd3;   // Assert reset
localparam S_WAIT_RST    = 4'd4;   // Wait 20ms
localparam S_RST_HIGH    = 4'd5;   // Release reset
localparam S_WAIT_BOOT   = 4'd6;   // Wait 10ms for OV5640 to boot
localparam S_SEND_REG    = 4'd7;   // Send one register via SCCB
localparam S_WAIT_DONE   = 4'd8;   // Wait for SCCB done
localparam S_NEXT_REG    = 4'd9;   // Advance to next register
localparam S_DONE        = 4'd10;  // All registers written
localparam S_SWRST_DLY   = 4'd11;  // Delay after software reset (0x3008=0x82)

reg [3:0]  state;
reg [21:0] delay_cnt;
reg [8:0]  reg_idx;      // index into register table (up to 512 entries)
wire [23:0] reg_entry;    // current {reg_addr[15:0], data[7:0]} entry

wire [8:0] reg_total;    // total number of entries (driven from ROM)

// register table ROM
ov5640_reg_table u_reg_table (
    .addr  (reg_idx),
    .data  (reg_entry),
    .total (reg_total)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= S_PWDN_HIGH;
        delay_cnt   <= 22'd0;
        reg_idx     <= 9'd0;
        sccb_start  <= 1'b0;
        sccb_dev    <= 8'h78;
        sccb_reg    <= 16'h0000;
        sccb_data   <= 8'h00;
        cam_rst_n   <= 1'b0;
        cam_pwdn    <= 1'b1;
        init_done   <= 1'b0;
    end
    else begin
        sccb_start <= 1'b0;  // default: no start pulse

        case (state)

            // Step 1: assert PWDN (power down mode)
            S_PWDN_HIGH: begin
                cam_pwdn  <= 1'b1;
                cam_rst_n <= 1'b0;
                delay_cnt <= DELAY_20MS;
                state     <= S_WAIT_PWDN;
            end

            // Step 2: wait 20ms
            S_WAIT_PWDN: begin
                if (delay_cnt == 22'd0)
                    state <= S_PWDN_LOW;
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // Step 3: release PWDN
            S_PWDN_LOW: begin
                cam_pwdn  <= 1'b0;
                delay_cnt <= DELAY_5MS;
                state     <= S_RST_LOW;
            end

            // Step 4: assert RESET (hold low)
            S_RST_LOW: begin
                cam_rst_n <= 1'b0;
                delay_cnt <= DELAY_20MS;
                state     <= S_WAIT_RST;
            end

            // Step 5: wait 20ms
            S_WAIT_RST: begin
                if (delay_cnt == 22'd0)
                    state <= S_RST_HIGH;
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // Step 6: release RESET
            S_RST_HIGH: begin
                cam_rst_n <= 1'b1;
                delay_cnt <= DELAY_10MS;
                state     <= S_WAIT_BOOT;
            end

            // Step 7: wait 10ms for OV5640 to boot
            S_WAIT_BOOT: begin
                if (delay_cnt == 22'd0)
                    state <= S_SEND_REG;
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // Step 8: send one register entry
            S_SEND_REG: begin
                if (!sccb_busy) begin
                    sccb_dev   <= 8'h78;
                    sccb_reg   <= reg_entry[23:8];  // 16-bit reg addr high byte
                    sccb_data  <= reg_entry[7:0];   // data byte
                    sccb_start <= 1'b1;
                    state      <= S_WAIT_DONE;
                end
            end

            // Step 9: wait for SCCB to finish
            // If the register just written was software reset (0x3008=0x82),
            // OV5640 needs >=5ms before accepting further writes.
            S_WAIT_DONE: begin
                if (sccb_done) begin
                    if (sccb_reg == 16'h3008 && sccb_data == 8'h82) begin
                        delay_cnt <= DELAY_10MS;
                        state     <= S_SWRST_DLY;
                    end
                    else
                        state <= S_NEXT_REG;
                end
            end

            // Step 9b: 10ms delay after software reset
            S_SWRST_DLY: begin
                if (delay_cnt == 22'd0)
                    state <= S_NEXT_REG;
                else
                    delay_cnt <= delay_cnt - 1'b1;
            end

            // Step 10: advance to next register
            S_NEXT_REG: begin
                if (reg_idx == reg_total - 1'b1)
                    state <= S_DONE;
                else begin
                    reg_idx <= reg_idx + 1'b1;
                    state   <= S_SEND_REG;
                end
            end

            // Step 11: done
            S_DONE: begin
                init_done <= 1'b1;
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule