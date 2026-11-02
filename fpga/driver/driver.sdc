# driver.sdc - timing constraints for FPGA B (the "test driver" board), 50 MHz

# Board clock: drives the driver directly
create_clock -name CLOCK_50 -period 20.0 [get_ports {CLOCK_50}]

# Clocks coming back from the chip board
create_clock -name up_clk   -period 20.0 [get_ports {up_clk}]    ;# PAD 15 link data from chip
create_clock -name dn_token -period 20.0 [get_ports {dn_token}]  ;# PAD 10 link credits from chip

# These clocks are not related to each other
set_clock_groups -asynchronous \
    -group {CLOCK_50} \
    -group {up_clk} \
    -group {dn_token}

derive_clock_uncertainty

# Board pins: board-to-board timing is checked on the bench
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
