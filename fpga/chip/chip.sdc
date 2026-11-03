# Chip board. All clocks come from the driver board at 50 MHz.
create_clock -name core_clk  -period 20.0 [get_ports {core_clk}]
create_clock -name dn_clk    -period 20.0 [get_ports {dn_clk}]
create_clock -name token_clk -period 20.0 [get_ports {token_clk}]

set_clock_groups -asynchronous \
    -group {core_clk} \
    -group {dn_clk} \
    -group {token_clk}

derive_clock_uncertainty

set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
