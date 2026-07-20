`timescale 1ns/1ps
// Functional testbench for bnn_demo_top.v. Confirms: (1) it auto-classifies
// image 0 right after reset with no button press, (2) each KEY1 press
// (modeled as a clean level change here -- debounce timing itself isn't
// the thing under test) advances through all 7 images in order and wraps
// back to 0 after image 6, and (3) led always ends up equal to the known
// expected prediction for whichever image is currently selected, matching
// tb_bnn_core.v's expected_pred table exactly.
module tb_bnn_demo_top;

reg clk = 0;
reg rst_n;
reg key1_n;

wire [3:0] led;

bnn_demo_top dut (
    .clk    (clk),
    .rst_n  (rst_n),
    .key1_n (key1_n),
    .led    (led)
);

always #10 clk = ~clk;   // 50MHz-equivalent period for readability, not timing-critical here

reg [3:0] expect_pred [0:6];
integer errors = 0;
integer i;

initial begin
    expect_pred[0] = 4'd7; expect_pred[1] = 4'd1; expect_pred[2] = 4'd0;
    expect_pred[3] = 4'd4; expect_pred[4] = 4'd9; expect_pred[5] = 4'd3;
    expect_pred[6] = 4'd6;   // deliberate misclassification, true label is 2
end

// press_key: since the debounce logic requires the synced level to stay
// changed for 16'hFFFF cycles before "stable" moves, and this testbench
// would take forever to wait out a real 65536-cycle debounce at this
// timescale, temporarily force key1_stable/db_cnt via hierarchical
// deposit is avoided here -- instead we just drive key1_n low long enough
// to clear the debounce counter for real, which is the honest way to
// exercise the exact RTL path (no shortcuts into internal state).
task press_key;
begin
    key1_n = 1'b0;
    repeat (32'd70000) @(posedge clk);   // outlast the 16-bit (65536-cycle) debounce counter + 2-cycle sync, with margin
    key1_n = 1'b1;
    repeat (32'd70000) @(posedge clk);
end
endtask

initial begin
    rst_n  = 0;
    key1_n = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1;

    // wait for the auto-boot classification of image 0 to finish
    wait (dut.fsm == 2'd1 && dut.img_idx == 3'd0);   // F_IDLE with img_idx still 0
    #1;
    $display("img[0] (auto-boot): led=%0d expected=%0d", led, expect_pred[0]);
    if (led !== expect_pred[0]) begin
        $display("FAIL: img[0] expected %0d got %0d", expect_pred[0], led);
        errors = errors + 1;
    end

    for (i = 1; i < 7; i = i + 1) begin
        press_key;
        wait (dut.fsm == 2'd1 && dut.img_idx == i[2:0]);
        #1;
        $display("img[%0d]: led=%0d expected=%0d", i, led, expect_pred[i]);
        if (led !== expect_pred[i]) begin
            $display("FAIL: img[%0d] expected %0d got %0d", i, expect_pred[i], led);
            errors = errors + 1;
        end
    end

    // one more press should wrap back around to image 0
    press_key;
    wait (dut.fsm == 2'd1 && dut.img_idx == 3'd0);
    #1;
    $display("img[0] (wrap-around): led=%0d expected=%0d", led, expect_pred[0]);
    if (led !== expect_pred[0]) begin
        $display("FAIL: wrap-around expected %0d got %0d", expect_pred[0], led);
        errors = errors + 1;
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

initial begin
    #100000000;   // generous timeout
    $display("TIMEOUT");
    $finish;
end

endmodule
