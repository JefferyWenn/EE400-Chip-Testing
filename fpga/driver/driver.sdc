# driver.sdc - timing constraints for FPGA B (the "test driver" board)

# Board clock
create_clock -name CLOCK_50 -period 20.0 [get_ports {CLOCK_50}]

# Our 12.5 MHz clock = CLOCK_50 / 4 (made by a counter in driver_top.v)
create_generated_clock -name clk -source [get_ports {CLOCK_50}] -divide_by 4 [get_registers {div[1]}]

# Clocks coming back from the chip board
create_clock -name up_clk   -period 80.0 [get_ports {up_clk}]    ;# PAD 15 link data from chip
create_clock -name dn_token -period 80.0 [get_ports {dn_token}]  ;# PAD 10 link credits from chip

# These clocks are not related to each other
set_clock_groups -asynchronous \
    -group {CLOCK_50 clk} \
    -group {up_clk} \
    -group {dn_token}

derive_clock_uncertainty

# Board pins: don't check board-to-board timing for now (12.5 MHz has plenty of margin)
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
