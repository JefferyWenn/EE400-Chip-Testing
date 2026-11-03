# Driver board, 50 MHz.
create_clock -name CLOCK_50 -period 20.0 [get_ports {CLOCK_50}]

# clocks coming back from the chip board
create_clock -name up_clk   -period 20.0 [get_ports {up_clk}]
create_clock -name dn_token -period 20.0 [get_ports {dn_token}]

set_clock_groups -asynchronous \
    -group {CLOCK_50} \
    -group {up_clk} \
    -group {dn_token}

derive_clock_uncertainty

set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
