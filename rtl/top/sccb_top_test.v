module sccb_top_test (
    input        clk,        // 50MHz
    input        rst_n,      // RESET按键
    input        key_start,  // KEY1，用来触发一次SCCB发送
    output       sccb_scl,
    inout        sccb_sda,
    output [3:0] led          // 用LED显示busy/done状态，方便观察
);

// 按键去抖动（复用D4写过的模块思路，这里简化处理）
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

// 检测下降沿（按下瞬间产生一个脉冲）
assign key_start_pulse = key_start_d2 & ~key_start_d1;

wire busy;
wire done;

CameraCapture u_sccb (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (key_start_pulse),
    .dev_addr (8'h78),   // OV5640设备地址
    .reg_addr (8'h31),   // 测试用：随便写一个寄存器地址
    .reg_data (8'h03),   // 测试用：随便写一个数据
    .sccb_scl (sccb_scl),
    .sccb_sda (sccb_sda),
    .busy     (busy),
    .done     (done)
);

assign led = {2'b00, busy, done};  // LED[1]=busy, LED[0]=done

endmodule