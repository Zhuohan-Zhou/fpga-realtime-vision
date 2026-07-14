// sd_spi.v -- SPI mode-0 byte transceiver for SD card.
// speed=0: ~390kHz (init phase, spec requires 100-400kHz), speed=1: 12.5MHz
// (data phase). One byte per 'start' pulse, MSB first, full duplex.
module sd_spi (
    input            clk,       // 50MHz
    input            rst_n,
    input            speed,     // 0 = slow (init), 1 = fast
    input            start,     // pulse: begin one byte transfer
    input      [7:0] tx_byte,
    output reg [7:0] rx_byte,
    output reg       done,      // pulse: byte finished, rx_byte valid
    output           busy,

    output reg       spi_clk,
    output reg       spi_mosi,
    input            spi_miso
);

// half-period lengths (system clocks): slow 64 -> 390kHz, fast 2 -> 12.5MHz
wire [6:0] half_max = speed ? 7'd1 : 7'd63;

reg        running;
reg  [6:0] div_cnt;
reg  [3:0] bit_cnt;      // 0..7
reg  [7:0] tx_sr, rx_sr;

assign busy = running;

wire tick = (div_cnt == half_max);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        running  <= 1'b0;
        div_cnt  <= 7'd0;
        bit_cnt  <= 4'd0;
        tx_sr    <= 8'hFF;
        rx_sr    <= 8'h00;
        rx_byte  <= 8'h00;
        done     <= 1'b0;
        spi_clk  <= 1'b0;
        spi_mosi <= 1'b1;
    end
    else begin
        done <= 1'b0;

        if (!running) begin
            div_cnt <= 7'd0;
            spi_clk <= 1'b0;
            if (start) begin
                running  <= 1'b1;
                tx_sr    <= tx_byte;
                spi_mosi <= tx_byte[7];   // present MSB before first rising edge
                bit_cnt  <= 4'd0;
            end
        end
        else begin
            if (tick) begin
                div_cnt <= 7'd0;
                spi_clk <= ~spi_clk;

                if (!spi_clk) begin
                    // rising edge: sample MISO
                    rx_sr <= {rx_sr[6:0], spi_miso};
                end
                else begin
                    // falling edge: shift out next bit / finish
                    if (bit_cnt == 4'd7) begin
                        running <= 1'b0;
                        rx_byte <= rx_sr;        // already contains 8 bits
                        done    <= 1'b1;
                        spi_mosi<= 1'b1;         // idle high
                    end
                    else begin
                        bit_cnt  <= bit_cnt + 1'b1;
                        tx_sr    <= {tx_sr[6:0], 1'b1};
                        spi_mosi <= tx_sr[6];
                    end
                end
            end
            else
                div_cnt <= div_cnt + 1'b1;
        end
    end
end

endmodule
