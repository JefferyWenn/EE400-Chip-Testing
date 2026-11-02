# fullsys.sdc - timing for the full-system emulation (one board), 50 MHz

# Board clock: drives the driver directly (50 MHz)
create_clock -name CLOCK_50 -period 20.0 [get_ports {CLOCK_50}]

# Clocks coming back through the loopback wires (50 MHz)
create_clock -name w_core_clk  -period 20.0 [get_ports {GPIO_1[22]}]   ;# wire 22 -> chip
create_clock -name w_dn_clk    -period 20.0 [get_ports {GPIO_1[8]}]    ;# wire 8  -> chip
create_clock -name w_token_clk -period 20.0 [get_ports {GPIO_1[11]}]   ;# wire 11 -> chip
create_clock -name w_up_clk    -period 20.0 [get_ports {GPIO_0[12]}]   ;# wire 12 -> driver
create_clock -name w_dn_token  -period 20.0 [get_ports {GPIO_0[10]}]   ;# wire 10 -> driver

# All clocks are unrelated to each other (the design synchronizes between them)
set_clock_groups -asynchronous \
    -group {CLOCK_50} -group {w_core_clk} -group {w_dn_clk} \
    -group {w_token_clk} -group {w_up_clk} -group {w_dn_token}

derive_clock_uncertainty

# Pins: board wires are checked on the board, not by Quartus
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
