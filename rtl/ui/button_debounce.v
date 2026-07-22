module button_debounce #(
    parameter integer CLK_HZ  = 9_000_000,
    parameter integer TICK_HZ = 1_000
)(
    input      clk,      // clk_9m
    input      rst_n,
    input      raw_n,    // raw active-low button pin
    output reg pressed   // 1-cycle pulse when a debounced press is detected
);

localparam integer TICK_DIV = CLK_HZ / TICK_HZ;   // 9000 @ 9MHz/1kHz
localparam integer DIVW     = 14;                  // covers TICK_DIV up to 16384

reg [DIVW-1:0] div_cnt;
wire tick = (div_cnt == TICK_DIV - 1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)      div_cnt <= {DIVW{1'b0}};
    else if (tick)   div_cnt <= {DIVW{1'b0}};
    else             div_cnt <= div_cnt + 1'b1;
end

// 2-flop synchronizer for the async button pin
reg [1:0] sync_ff;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync_ff <= 2'b11;   // idle = released = high (active-low)
    else        sync_ff <= {sync_ff[0], raw_n};
end

reg [7:0] hist;        // 8 samples @ 1kHz = 8ms debounce window
reg       stable_low;
wire [7:0] next_hist = {hist[6:0], sync_ff[1]};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hist        <= 8'hFF;
        stable_low  <= 1'b0;
        pressed     <= 1'b0;
    end
    else begin
        pressed <= 1'b0;
        if (tick) begin
            hist <= next_hist;
            if (next_hist == 8'h00 && !stable_low) begin
                stable_low <= 1'b1;
                pressed    <= 1'b1;   // released -> pressed transition
            end
            else if (next_hist == 8'hFF && stable_low) begin
                stable_low <= 1'b0;
            end
        end
    end
end

endmodule
