// pixel_fifo.v -- dual-clock FIFO, 16-bit x 512, show-ahead mode
// (q shows current word before rdreq; rdreq pops to next word).
// Used for both camera->SDRAM and SDRAM->LCD crossings.
module pixel_fifo (
    input         aclr,
    // write side
    input         wrclk,
    input         wrreq,
    input  [15:0] data,
    output  [8:0] wrusedw,
    // read side
    input         rdclk,
    input         rdreq,
    output [15:0] q,
    output  [8:0] rdusedw
);

dcfifo #(
    .intended_device_family ("Cyclone IV E"),
    .lpm_numwords           (512),
    .lpm_showahead          ("ON"),
    .lpm_type               ("dcfifo"),
    .lpm_width              (16),
    .lpm_widthu             (9),
    .overflow_checking      ("ON"),
    .underflow_checking     ("ON"),
    .rdsync_delaypipe       (4),
    .wrsync_delaypipe       (4),
    .use_eab                ("ON")
) dcfifo_inst (
    .aclr    (aclr),
    .wrclk   (wrclk),
    .wrreq   (wrreq),
    .data    (data),
    .wrusedw (wrusedw),
    .rdclk   (rdclk),
    .rdreq   (rdreq),
    .q       (q),
    .rdusedw (rdusedw),
    .rdempty (),
    .rdfull  (),
    .wrempty (),
    .wrfull  (),
    .eccstatus ()
);

endmodule
