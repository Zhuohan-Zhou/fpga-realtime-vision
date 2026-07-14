module CameraCapture (
    input        clk,         // 50MHz System CLK
    input        rst_n,       // Reset Signal (low = reset)
    input        start,       // Start trigger: IDLE --> START
    input  [7:0] dev_addr,    // Device address (OV5640 = 0x78)
    input  [15:0] reg_addr,   // Register address (16-bit for OV5640)
    input  [7:0] reg_data,    // Data to write
    output reg   sccb_scl,
    inout        sccb_sda,
    output reg   busy,
    output reg   done
);

// State definitions
parameter IDLE   = 4'd0;
parameter START  = 4'd1;
parameter ADDR   = 4'd2;
parameter REG_H  = 4'd3;   // reg addr high byte (16-bit addr needs 2 states)
parameter REG_L  = 4'd4;   // reg addr low byte
parameter DATA   = 4'd5;
parameter STOP   = 4'd6;
parameter FINISH = 4'd7;

reg [3:0] state, next_state;
reg [3:0] bit_cnt;
reg [2:0] phase;
reg sda_out;
reg sda_oe;

assign sccb_sda = sda_oe ? sda_out : 1'bz;

// Clock divider
// 8'd4  → 10MHz  (for SignalTap testing)
// 8'd199 → 250kHz (real operation, change back after waveform verified)
reg [7:0] clk_div_cnt;
wire scl_tick;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        clk_div_cnt <= 8'd0;
    else if (clk_div_cnt == 8'd199)
        clk_div_cnt <= 8'd0;
    else
        clk_div_cnt <= clk_div_cnt + 1'b1;
end

assign scl_tick = (clk_div_cnt == 8'd199);

// State register
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

// State transition (combinational)
always @(*) begin
    case (state)
        IDLE:   next_state = start ? START : IDLE;
        START:  next_state = (scl_tick && phase == 3'd3) ? ADDR   : START;
		  ADDR:  next_state = (scl_tick && phase==3'd3 && bit_cnt==4'd8) ? REG_H : ADDR;
		  REG_H: next_state = (scl_tick && phase==3'd3 && bit_cnt==4'd8) ? REG_L : REG_H;
		  REG_L: next_state = (scl_tick && phase==3'd3 && bit_cnt==4'd8) ? DATA  : REG_L;
		  DATA:  next_state = (scl_tick && phase==3'd3 && bit_cnt==4'd8) ? STOP  : DATA;
        STOP:   next_state = (scl_tick && phase == 3'd3) ? FINISH : STOP;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

// Phase and bit_cnt progression -- case list and bit-count condition
// both had to grow to cover REG_H/REG_L once we added the 16-bit addr states
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase   <= 3'd0;
        bit_cnt <= 3'd0;
    end
    else if (scl_tick) begin
        case (state)
            START, ADDR, REG_H, REG_L, DATA, STOP: begin
                if (phase == 3'd3) begin
                    phase <= 3'd0;
                    if (state == ADDR || state == REG_H ||
                        state == REG_L || state == DATA) begin
                        if (bit_cnt == 4'd8)
                            bit_cnt <= 4'd0;
                        else
                            bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                else
                    phase <= phase + 1'b1;
            end
            default: begin
                phase   <= 3'd0;
                bit_cnt <= 3'd0;
            end
        endcase
    end
end

// SCL output -- same REG_H/REG_L addition here
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        sccb_scl <= 1'b1;
    else begin
        case (state)
            IDLE:                      sccb_scl <= 1'b1;
            START:                     sccb_scl <= (phase < 2) ? 1'b1 : 1'b0;
            ADDR, REG_H, REG_L, DATA:  sccb_scl <= (phase < 2) ? 1'b0 : 1'b1;
            STOP:                      sccb_scl <= (phase < 2) ? 1'b0 : 1'b1;
            FINISH:                    sccb_scl <= 1'b1;
            default:                   sccb_scl <= 1'b1;
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sda_out <= 1'b1;
        sda_oe  <= 1'b1;
    end
    else begin
        case (state)
            IDLE: begin
                sda_out <= 1'b1;
                sda_oe  <= 1'b1;
            end

            START: begin
                sda_out <= (phase == 3'd0) ? 1'b1 : 1'b0;
                sda_oe  <= 1'b1;
            end

            ADDR: begin
                if (bit_cnt <= 4'd7) begin
                    sda_out <= dev_addr[3'd7 - bit_cnt[2:0]];
                    sda_oe  <= 1'b1;
                end
                else begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b0;   // bit 8: ACK slot, release SDA
                end
            end

            REG_H: begin
                if (bit_cnt <= 4'd7) begin
                    sda_out <= reg_addr[4'd15 - bit_cnt];
                    sda_oe  <= 1'b1;
                end
                else begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b0;   // ACK slot
                end
            end

            REG_L: begin
                if (bit_cnt <= 4'd7) begin
                    sda_out <= reg_addr[3'd7 - bit_cnt[2:0]];
                    sda_oe  <= 1'b1;
                end
                else begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b0;   // ACK slot
                end
            end

            DATA: begin
                if (bit_cnt <= 4'd7) begin
                    sda_out <= reg_data[3'd7 - bit_cnt[2:0]];
                    sda_oe  <= 1'b1;
                end
                else begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b0;   // ACK slot
                end
            end

            STOP: begin
                sda_out <= (phase == 3'd3) ? 1'b1 : 1'b0;
                sda_oe  <= 1'b1;
            end

            FINISH: begin
                sda_out <= 1'b1;
                sda_oe  <= 1'b1;
            end

            default: begin
                sda_out <= 1'b1;
                sda_oe  <= 1'b1;
            end
        endcase
    end
end

// busy / done
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy <= 1'b0;
        done <= 1'b0;
    end
    else begin
        busy <= (state != IDLE);
        done <= (state == FINISH);
    end
end

endmodule