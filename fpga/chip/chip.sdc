# chip.sdc - timing constraints for FPGA A (the "chip" board)
#
# All clocks come in from the driver board through the GPIO headers.
# Driver board supplies 12.5 MHz (period 80 ns). Change the periods here if you
# run the driver at a different speed.

# Clocks coming in on header pins
create_clock -name core_clk  -period 80.0 [get_ports {core_clk}]   ;# PAD 44
create_clock -name dn_clk    -period 80.0 [get_ports {dn_clk}]     ;# PAD 8  (link data in)
create_clock -name token_clk -period 80.0 [get_ports {token_clk}]  ;# PAD 12 (link credits in)

# The three clocks are not related to each other
set_clock_groups -asynchronous \
    -group {core_clk} \
    -group {dn_clk} \
    -group {token_clk}

derive_clock_uncertainty

# Board pins: don't check board-to-board timing for now.
# At 12.5 MHz there is plenty of margin. Revisit when going faster.
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
