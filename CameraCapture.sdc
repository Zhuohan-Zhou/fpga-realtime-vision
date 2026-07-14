create_clock -name clk -period 20.000 [get_ports clk]
create_clock -name cam_pclk -period 37.037 [get_ports cam_pclk]
derive_pll_clocks
derive_clock_uncertainty
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {cam_pclk}] -group [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}] -group [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[2]}]
