module sccb_top_test (
    input        clk,        
    input        rst_n,     
    input        key_start,  
    output       sccb_scl,
    inout        sccb_sda,
    output [3:0] led          
);


reg key_start_d1, key_start_d2;
wire key_start_pulse;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_start_d1 <= 1'b1;
        key_start_d2 <= 1'b1;
    end
    else begin
        key_start_d1 <= key_start;
        key_start_d2 <= key_start_d1;
    end
end


assign key_start_pulse = key_start_d2 & ~key_start_d1;

wire busy;
wire done;

sccb_master u_sccb (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (key_start_pulse),
    .dev_addr (8'h78), 
    .reg_addr (8'h31),  
    .reg_data (8'h03),  
    .sccb_scl (sccb_scl),
    .sccb_sda (sccb_sda),
    .busy     (busy),
    .done     (done)
);

assign led = {2'b00, busy, done};  // LED[1]=busy, LED[0]=done

endmodule