# chip.sdc - timing constraints for FPGA A (the "chip" board)
#
# All clocks come in from the driver board through the GPIO headers.
# Start slow: 10 MHz (period 100 ns). Change the periods here if you
# run the driver at a different speed.

# Clocks coming in on header pins
create_clock -name core_clk  -period 100.0 [get_ports {GPIO_1[8]}]   ;# PAD 44
create_clock -name dn_clk    -period 100.0 [get_ports {GPIO_0[8]}]   ;# PAD 8  (link data in)
create_clock -name token_clk -period 100.0 [get_ports {GPIO_0[12]}]  ;# PAD 12 (link credits in)

# The three clocks are not related to each other
set_clock_groups -asynchronous \
    -group {core_clk} \
    -group {dn_clk} \
    -group {token_clk}

derive_clock_uncertainty

# Header pins: don't check board-to-board timing for now.
# At 10 MHz there is plenty of margin. Revisit when going faster.
set_false_path -from [get_ports {GPIO_0[*] GPIO_1[*]}]
set_false_path -to   [get_ports {GPIO_0[*] GPIO_1[*] LEDR[*]}]
