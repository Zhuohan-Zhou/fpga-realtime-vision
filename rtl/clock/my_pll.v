// The clock generator for the whole board.

module my_pll (
    input  inclk0,
    output c0,      // 100MHz          (system / SDRAM logic)
    output c1,      // 24MHz           (camera XCLK)
    output c2,      // 8.955MHz        (LCD pixel clock, ~9MHz; exact 9M
                    //                  infeasible with one VCO @600MHz)
    output c3,      // 100MHz, -75deg  (SDRAM chip clock)
    output locked
);

altpll #(
    .bandwidth_type          ("AUTO"),
    .clk0_divide_by          (1),
    .clk0_multiply_by        (2),
    .clk1_divide_by          (25),
    .clk1_multiply_by        (12),
    .clk2_divide_by          (67),   // 50M x 12/67 = 8.955MHz
    .clk2_multiply_by        (12),   // (VCO=600M: C0=6,C1=25,C2=67,C3=6 all integer)
    .clk3_divide_by          (1),
    .clk3_multiply_by        (2),
    .clk3_phase_shift        ("7917"),  // -75deg @ 100MHz (= -2083ps, expressed as +7917ps)
    .compensate_clock        ("CLK0"),
    .inclk0_input_frequency  (20000),
    .intended_device_family  ("Cyclone IV E"),
    .lpm_hint                ("CBX_MODULE_PREFIX=my_pll"),
    .lpm_type                ("altpll"),
    .operation_mode          ("NORMAL"),
    .pll_type                ("AUTO"),
    .port_activeclock        ("PORT_UNUSED"),
    .port_areset             ("PORT_UNUSED"),
    .port_clkbad0            ("PORT_UNUSED"),
    .port_clkbad1            ("PORT_UNUSED"),
    .port_clkloss            ("PORT_UNUSED"),
    .port_clkswitch          ("PORT_UNUSED"),
    .port_fbin               ("PORT_UNUSED"),
    .port_inclk0             ("PORT_USED"),
    .port_inclk1             ("PORT_UNUSED"),
    .port_locked             ("PORT_USED"),
    .port_pfdena             ("PORT_UNUSED"),
    .port_phasecounterselect ("PORT_UNUSED"),
    .port_phasedone          ("PORT_UNUSED"),
    .port_phasestep          ("PORT_UNUSED"),
    .port_phaseupdown        ("PORT_UNUSED"),
    .port_pllena             ("PORT_UNUSED"),
    .port_scandataout        ("PORT_UNUSED"),
    .port_scanread           ("PORT_UNUSED"),
    .port_scanwrite          ("PORT_UNUSED"),
    .port_clk0               ("PORT_USED"),
    .port_clk1               ("PORT_USED"),
    .port_clk2               ("PORT_USED"),
    .port_clk3               ("PORT_USED"),
    .port_clk4               ("PORT_UNUSED"),
    .port_clk5               ("PORT_UNUSED"),
    .self_reset_on_loss_of_lock ("OFF"),
    .width_clock             (5)
) altpll_component (
    .inclk  ({1'b0, inclk0}),
    .clk    ({1'b0, c3, c2, c1, c0}),
    .locked (locked)
);

endmodule