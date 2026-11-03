# Everything runs at 50 MHz.
create_clock -name CLOCK_50 -period 20.0 [get_ports {CLOCK_50}]

# clocks that come back through the loopback wires
create_clock -name w_core_clk  -period 20.0 [get_ports {GPIO_1[22]}]
create_clock -name w_dn_clk    -period 20.0 [get_ports {GPIO_1[8]}]
create_clock -name w_token_clk -period 20.0 [get_ports {GPIO_1[11]}]
create_clock -name w_up_clk    -period 20.0 [get_ports {GPIO_0[12]}]
create_clock -name w_dn_token  -period 20.0 [get_ports {GPIO_0[10]}]

# the design syncs between these clocks itself
set_clock_groups -asynchronous \
    -group {CLOCK_50} -group {w_core_clk} -group {w_dn_clk} \
    -group {w_token_clk} -group {w_up_clk} -group {w_dn_token}

derive_clock_uncertainty

# the wires themselves are tested on the board
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
