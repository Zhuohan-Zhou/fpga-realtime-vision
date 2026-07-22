module seq_divider #(
    parameter WIDTH = 32
)(
    input                    clk,
    input                    rst_n,
    input                    start,      // 1-cycle pulse to begin
    input      [WIDTH-1:0]   dividend,
    input      [WIDTH-1:0]   divisor,
    output reg               busy,
    output reg               done,       // 1-cycle pulse, quotient valid
    output reg [WIDTH-1:0]   quotient
);

localparam S_IDLE = 2'd0,
           S_RUN  = 2'd1,
           S_DONE = 2'd2;

reg [1:0]       state;
reg [WIDTH-1:0] rem;
reg [WIDTH-1:0] div_r;      // shifting copy of dividend
reg [WIDTH-1:0] divisor_r;  // latched divisor (stable through S_RUN)
reg [WIDTH-1:0] quot_r;
reg [5:0]       bit_cnt;    // counts WIDTH..1 (WIDTH <= 63)

wire [WIDTH-1:0] rem_shifted = {rem[WIDTH-2:0], div_r[WIDTH-1]};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        busy      <= 1'b0;
        done      <= 1'b0;
        quotient  <= {WIDTH{1'b0}};
        rem       <= {WIDTH{1'b0}};
        div_r     <= {WIDTH{1'b0}};
        divisor_r <= {WIDTH{1'b0}};
        quot_r    <= {WIDTH{1'b0}};
        bit_cnt   <= 6'd0;
    end
    else begin
        done <= 1'b0;
        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    rem       <= {WIDTH{1'b0}};
                    div_r     <= dividend;
                    divisor_r <= divisor;
                    quot_r    <= {WIDTH{1'b0}};
                    bit_cnt   <= WIDTH[5:0];
                    busy      <= 1'b1;
                    state     <= S_RUN;
                end
            end

            S_RUN: begin
                if (rem_shifted >= divisor_r) begin
                    rem    <= rem_shifted - divisor_r;
                    quot_r <= {quot_r[WIDTH-2:0], 1'b1};
                end
                else begin
                    rem    <= rem_shifted;
                    quot_r <= {quot_r[WIDTH-2:0], 1'b0};
                end
                div_r <= {div_r[WIDTH-2:0], 1'b0};

                if (bit_cnt == 6'd1)
                    state <= S_DONE;
                else
                    bit_cnt <= bit_cnt - 6'd1;
            end

            S_DONE: begin
                quotient <= quot_r;
                done     <= 1'b1;
                busy     <= 1'b0;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
