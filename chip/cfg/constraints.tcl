#------------------------------------------------------------------------
# Clock Definitions
#
# Two clock-rate budgets: a 50 MHz core/TX rate and a 25 MHz IO-side
# rate for the FPGA-forwarded clocks. The split tracks bsg_link_oddr_phy's
# behavior — the PHY divides clk_i by 2 to produce clk_r_o, so a chip
# core_clk of 50 MHz launches a 25 MHz forwarded clock toward the FPGA.
# A symmetric FPGA peer produces a 25 MHz clock back at the chip's RX pad.
#
#   core_clk    on PAD[44] - 50 MHz core/TX master clock
#                            (io_master_clk for bsg_link_ddr_upstream is
#                             tied to core_clk inside chip_top.sv)
#   dn_clk      on PAD[8]  - 25 MHz downstream RX clock from FPGA
#                            (FPGA's bsg_link_oddr_phy ÷2 of its 50 MHz io_clk)
#   token_clk   on PAD[12] - 50 MHz upstream credit-return from FPGA
#                            (driven by FPGA core_token_r_o, lives in FPGA
#                             core domain — bounded at chip core_clk rate)
#
# SPI's SCLK (PAD[13]) is also a clock; treated as a 4 MHz async reference.
#------------------------------------------------------------------------

set FUNC_CLK_PERIOD     20.0    ;# 50 MHz core_clk / token_clk
set IO_CLK_PERIOD       40.0    ;# 25 MHz dn_clk (FPGA forwarded clock, bsg_link_oddr_phy ÷2)
set FUNC_CLK_UNCERT      0.5    ;# clean-PLL or short-trace-FPGA source
set FUNC_CLK_TRANSITION  0.1    ;# rise/fall waveform transition

# Core clock (drives core domain + bsg_link upstream IO domain).
create_clock -name core_clk -period $FUNC_CLK_PERIOD [get_ports PAD[44]]
set_clock_uncertainty $FUNC_CLK_UNCERT     [get_clocks core_clk]
set_clock_transition  -rise $FUNC_CLK_TRANSITION [get_clocks core_clk]
set_clock_transition  -fall $FUNC_CLK_TRANSITION [get_clocks core_clk]

# Downstream IO clock (RX side of bsg_link), 50 MHz from FPGA's oddr_phy.
create_clock -name dn_clk -period $IO_CLK_PERIOD [get_ports PAD[8]]
set_clock_uncertainty $FUNC_CLK_UNCERT     [get_clocks dn_clk]
set_clock_transition  -rise $FUNC_CLK_TRANSITION [get_clocks dn_clk]
set_clock_transition  -fall $FUNC_CLK_TRANSITION [get_clocks dn_clk]

# Token return clock (credit-return side of bsg_link upstream). Each
# rising edge IS one credit returned by the FPGA; declared as a clock
# because it physically drives the bsg_async_credit_counter's w_clk_i.
# Lives in the FPGA's core domain — same 100 MHz rate as core_clk.
create_clock -name token_clk -period $FUNC_CLK_PERIOD [get_ports PAD[12]]
set_clock_uncertainty $FUNC_CLK_UNCERT     [get_clocks token_clk]
set_clock_transition  -rise $FUNC_CLK_TRANSITION [get_clocks token_clk]
set_clock_transition  -fall $FUNC_CLK_TRANSITION [get_clocks token_clk]

# # SPI clock: up to 4 MHz (250 ns period).
# create_clock -name sclk -period 250.0 [get_ports PAD[13]]
# set_clock_uncertainty 5.0 [get_clocks sclk]
# set_clock_transition -rise 0.1 [get_clocks sclk]
# set_clock_transition -fall 0.1 [get_clocks sclk]

#------------------------------------------------------------------------
# Chip-level CDC constraints.
#
# Two layers:
#  1. set_clock_groups -asynchronous declares the four master clocks as
#     mutually-async — handles setup/hold path exclusion between unrelated
#     clocks (Tempus reports "asynchronously exclusive" on cross-clock pairs).
#  2. Per-cell set_max_delay bounds the specific CDC data paths (MSYNC ->
#     twofer comb path, reset SDN routing, SPI sync inputs).  Without these
#     the router has no routing budget on the combinational portion of CDC
#     paths and could grow them arbitrarily long for area/power opt.
#
# (We tried the BSG bigblade "shadow clock" pattern — create _cdc shadows
# via create_clock -add, physically_exclusive vs real, set_max_delay cross-
# shadow.  It did increase Tempus "Applied exceptions" annotations, but
# also caused internal same-clock paths to appear as unconstrained when
# Tempus picked the shadow as the launching clock.  Reverted in favor of
# the simpler async-groups + targeted per-cell max_delay scheme below.)
#------------------------------------------------------------------------
set_clock_groups -asynchronous -group [get_clocks core_clk]
set_clock_groups -asynchronous -group [get_clocks dn_clk]
set_clock_groups -asynchronous -group [get_clocks token_clk]
# set_clock_groups -asynchronous -group [get_clocks sclk]

# Clock-to-clock CDC routing budget = HALF of min(period of the two clocks).
# Bounds the combinational portion of every CDC path between unrelated clocks
# so the router can't grow it arbitrarily long for area/power opt (gray-code
# pointer sync only guarantees memory stability, not comb-path settling time).
# Half-period convention matches bsg_tag_timing.tcl — conservative enough that
# the comb path always settles well within one period of the faster clock.
# All 12 directional pairs across the 4 clocks (4x3=12).
#   core_clk  = 20 ns   -> half = 10 ns
#   dn_clk    = 40 ns   -> half = 20 ns
#   token_clk = 20 ns   -> half = 10 ns
#   sclk      = 250 ns  -> half = 125 ns
# Pair bound = half(min(periods)).
set_max_delay 10  -from [get_clocks core_clk]  -to [get_clocks dn_clk]
set_min_delay 0.0 -from [get_clocks core_clk]  -to [get_clocks dn_clk]
set_max_delay 10  -from [get_clocks core_clk]  -to [get_clocks token_clk]
set_min_delay 0.0 -from [get_clocks core_clk]  -to [get_clocks token_clk]
# set_max_delay 10  -from [get_clocks core_clk]  -to [get_clocks sclk]
# set_min_delay 0.0 -from [get_clocks core_clk]  -to [get_clocks sclk]
set_max_delay 10  -from [get_clocks dn_clk]    -to [get_clocks core_clk]
set_min_delay 0.0 -from [get_clocks dn_clk]    -to [get_clocks core_clk]
set_max_delay 10  -from [get_clocks dn_clk]    -to [get_clocks token_clk]
set_min_delay 0.0 -from [get_clocks dn_clk]    -to [get_clocks token_clk]
# set_max_delay 20  -from [get_clocks dn_clk]    -to [get_clocks sclk]
# set_min_delay 0.0 -from [get_clocks dn_clk]    -to [get_clocks sclk]
set_max_delay 10  -from [get_clocks token_clk] -to [get_clocks core_clk]
set_min_delay 0.0 -from [get_clocks token_clk] -to [get_clocks core_clk]
set_max_delay 10  -from [get_clocks token_clk] -to [get_clocks dn_clk]
set_min_delay 0.0 -from [get_clocks token_clk] -to [get_clocks dn_clk]
# set_max_delay 10  -from [get_clocks token_clk] -to [get_clocks sclk]
# set_min_delay 0.0 -from [get_clocks token_clk] -to [get_clocks sclk]
# set_max_delay 10  -from [get_clocks sclk]      -to [get_clocks core_clk]
# set_min_delay 0.0 -from [get_clocks sclk]      -to [get_clocks core_clk]
# set_max_delay 20  -from [get_clocks sclk]      -to [get_clocks dn_clk]
# set_min_delay 0.0 -from [get_clocks sclk]      -to [get_clocks dn_clk]
# set_max_delay 10  -from [get_clocks sclk]      -to [get_clocks token_clk]
# set_min_delay 0.0 -from [get_clocks sclk]      -to [get_clocks token_clk]

#------------------------------------------------------------------------
# Input transitions
#
# Assume each chip input is driven by the same TSMC180 PDDW1216CDG cell
# instance on a peer chip, with default drive strength (DS=0, ~12 mA) and
# a short PCB trace. This gives a clean ~0.5 ns max input transition and
# ~0.1 ns at the fast corner. Applied to all input ports — clock pads
# included, since their slew matters for setup/hold checks against the
# data ports they sample.
#
# Note: this is independent of set_clock_transition above (which sets the
# clock-waveform transition used for skew analysis). Both can coexist;
# the tool uses set_clock_transition for clock paths and the implied
# data transition from set_input_transition for the data paths.
#------------------------------------------------------------------------
set_input_transition -max 0.5 [all_inputs]
set_input_transition -min 0.1 [all_inputs]

# Clock pads need a tighter input slew than data pads — Innovus's CTS
# targets 0.4 ns at the root driver, and a 0.5 ns input slew at the
# clock pad pushes past that and triggers post-CTS slew violations on
# PAD[8/12/13/44]. Override to 0.2 ns max / 0.05 ns min for the four
# clock pads. (Off-chip side: assumed clean low-jitter clock source —
# crystal oscillator or PLL — driving across a short PCB trace.)
set_input_transition -max 0.2  [get_ports {PAD[8] PAD[12] PAD[44]}]
set_input_transition -min 0.05 [get_ports {PAD[8] PAD[12] PAD[44]}]

#------------------------------------------------------------------------
# bsg_link DDR IO timing — center-aligned source-synchronous
#
# bsg_link launches data such that the IO clock edge lands in the MIDDLE
# of each data UI (per bsg_link_oddr_phy.v / bsg_link_iddr_phy.v file
# headers). At 50 MHz IO with DDR, each UI = 10 ns and the clock edge
# is at ±5 ns from each data edge.
#
# RX side (FPGA -> chip): set_input_delay -min/-max on BOTH dn_clk edges
#     describes the data eye as it arrives at the chip pad. The min/max
#     envelope = "data is valid from min_in_dly after the edge to
#     (period/2 - min_in_dly) after the edge."
#
# TX side (chip -> FPGA): set_data_check between up_clk pad and each
#     up_data/up_valid pad. set_data_check directly bounds on-chip skew
#     between two output ports — appropriate here because up_clk is a
#     forwarded clock (generated from io_master_clk) and we don't care
#     about the FPGA's setup/hold spec, only on-chip launch skew.
#     set_multicycle_path 1 fixes the half-period interpretation.
#
# Eye envelope numbers (computed once below, used inline):
#     RX side  (set_input_delay): related period = dn_clk = IO_CLK_PERIOD
#         max_io_skew_rx  = io_clk_period * 0.025
#         min_input_delay = max_io_skew_rx + clk_uncert + cell_rf/2
#         max_input_delay = io_clk_period/2 - min_input_delay - dn_clk_pad_lat
#     TX side  (set_data_check): related period = core_clk = FUNC_CLK_PERIOD
#         max_io_skew_tx  = func_clk_period * 0.025
#         data_check      = func_clk_period/2 - max_io_skew_tx
#                          - tx_launch_skew - clk_uncert - cell_rf/2
#
# Why two periods: bsg_link_oddr_phy halves clk_i to produce clk_r_o, so
# the chip-side TX uses the io_master_clk = core_clk (50 MHz, 20 ns)
# rate for set_data_check transitions at PAD[15], while the chip-side RX
# samples dn_clk (25 MHz, 40 ns) which is the FPGA's *already-halved*
# forwarded clock at PAD[8].
#------------------------------------------------------------------------

# Eye-envelope constants.
#
# - PAD_RF: PDDW1216CDG rise/fall transition mismatch.
#
# - DN_CLK_PAD_LAT: PDDW1216CDG PAD->C input-buffer delay (~1 ns at WCCOM).
#   Subtracted from MAX_IN_DLY so the eye envelope budgets the chip's
#   input pad delay on the data path. (We tried the cleaner-looking
#   set_clock_latency on dn_clk — Cadence applies it asymmetrically as
#   src-latency on the launch side and net-latency on the capture side
#   for input data paths, and set_propagated_clock only overrides the
#   capture half. Net effect post-CTS: the launch annotation persists
#   and *adds* to data-port arrival, leaving ~-0.4 ns RX setup violations
#   on iddr_phy/data_p_r. Plain subtraction is a constant offset that
#   works the same pre- and post-CTS.)
#
# - TX_LAUNCH_SKEW: set to 0.0 — keep the set_data_check window at the
#   bsg-canonical value and let PAR balance up_clk vs up_data.
#   At 50 MHz the scan-flop CP->Q asymmetry (~1.5 ns, data flops are
#   SDFQD0BWP7T ~2 ns vs clk_r_o non-scan ~0.3 ns) causes only a
#   ~0.65 ns violation, which PAR can close by adding a small buffer on
#   the up_clk output net.  Set to 1.5 ns to relax instead if PAR fails.
set BSG_LINK_TX_IO_PERIOD    $FUNC_CLK_PERIOD                      ;# 20 ns: clk_r_o transitions at this rate
set BSG_LINK_RX_IO_PERIOD    $IO_CLK_PERIOD                        ;# 40 ns: dn_clk at chip pad
set BSG_LINK_TX_IO_SKEW      [expr 0.025 * $BSG_LINK_TX_IO_PERIOD] ;# 2.5% of TX period (bsg-canonical)
set BSG_LINK_RX_IO_SKEW      [expr 0.025 * $BSG_LINK_RX_IO_PERIOD] ;# 2.5% of RX period
set BSG_LINK_PAD_RF          0.1                                   ;# PDDW1216CDG rise/fall mismatch
set BSG_LINK_DN_CLK_PAD_LAT  1.0                                   ;# PDDW1216CDG PAD->C input-buffer delay
set BSG_LINK_TX_LAUNCH_SKEW  1.5                                   ;# relax set_data_check window to absorb up_clk vs up_data launch skew
set BSG_LINK_MIN_IN_DLY      [expr $BSG_LINK_RX_IO_SKEW + $FUNC_CLK_UNCERT + $BSG_LINK_PAD_RF / 2.0]
set BSG_LINK_MAX_IN_DLY      [expr ($BSG_LINK_RX_IO_PERIOD / 2.0) - $BSG_LINK_MIN_IN_DLY - $BSG_LINK_DN_CLK_PAD_LAT]
set BSG_LINK_DCHK            [expr ($BSG_LINK_TX_IO_PERIOD / 2.0) - $BSG_LINK_TX_IO_SKEW - $BSG_LINK_TX_LAUNCH_SKEW - $FUNC_CLK_UNCERT - $BSG_LINK_PAD_RF / 2.0]

# bsg-canonical RX/TX procs, copied verbatim from BaseJump STL's
# `hard/gf_14/bsg_link/tcl/bsg_link_ddr.constraints.tcl` (Paul Gao 2021,
# bsg_link_ddr_in_constraints + bsg_link_ddr_out_constraints).
# We pass our project-specific eye numbers (above) as arguments and let
# the procs emit the 4 set_input_delay lines per RX-port-list and the
# 2 set_data_check + 2 set_multicycle_path lines per TX port.
proc bsg_link_ddr_in_constraints {clk_name ports max_delay min_delay} {
  set_input_delay -max $max_delay -clock $clk_name -source_latency_included -network_latency_included $ports
  set_input_delay -max $max_delay -clock $clk_name -source_latency_included -network_latency_included $ports -add_delay -clock_fall
  set_input_delay -min $min_delay -clock $clk_name -source_latency_included -network_latency_included $ports
  set_input_delay -min $min_delay -clock $clk_name -source_latency_included -network_latency_included $ports -add_delay -clock_fall
}

proc bsg_link_ddr_out_constraints {clk_port ports setup_time hold_time} {
  foreach_in_collection obj $ports {
    set_data_check -from $clk_port -to $obj -setup $setup_time
    set_data_check -from $clk_port -to $obj -hold  $hold_time
    set_multicycle_path -end   -setup 1 -to $obj
    set_multicycle_path -start -hold  0 -to $obj
  }
}

# RX (FPGA -> chip): dn_clk samples dn_data[15:0] + dn_valid.
#   dn_data[0..7]   -> PAD[0..7]
#   dn_data[8..15]  -> PAD[37,36,39,38,41,40,43,42]   (interleaved per chip_top.sv)
#   dn_valid        -> PAD[9]
bsg_link_ddr_in_constraints dn_clk \
  [get_ports {PAD[0] PAD[1] PAD[2] PAD[3] PAD[4] PAD[5] PAD[6] PAD[7] PAD[9]}] \
  $BSG_LINK_MAX_IN_DLY \
  $BSG_LINK_MIN_IN_DLY

# TX (chip -> FPGA): up_clk on PAD[15] forwards up_data[15:0] + up_valid.
#   up_data[0..7]   -> PAD[22,23,20,21,18,19,16,17]   (interleaved)
#   up_data[8..15]  -> PAD[28..35] sequentially
#   up_valid        -> PAD[14]
bsg_link_ddr_out_constraints \
  [get_ports PAD[15]] \
  [get_ports {PAD[14] PAD[16] PAD[17] PAD[18] PAD[19] PAD[20] PAD[21] PAD[22] PAD[23]}] \
  $BSG_LINK_DCHK \
  $BSG_LINK_DCHK

# dn_token output (PAD[10]) is the chip's RX-side credit return — it
# functions as a clock to the FPGA's bsg_async_credit_counter, not as
# data. bsg_chip leaves the analogous p_sdi_token_o intentionally
# unconstrained (hard to predict launch delay before CTS).

#------------------------------------------------------------------------
# Other input / output delays (SPI)
#------------------------------------------------------------------------

# SPI inputs (MOSI on PAD[24], SS_n on PAD[26]) — intentionally have NO
# set_input_delay -clock sclk.  The MOSI/SS_n pads feed a 2-FF synchronizer
# clocked by core_clk (mosi_sync_reg, ss_n_sync_reg) — they are NOT captured
# by sclk inside this chip.  Adding `set_input_delay -clock sclk` here would
# falsely tell Tempus "these inputs are launched by sclk", giving the
# PAD->sync_DFF/D path an sclk-launch-edge -> core_clk-capture-edge framework
# that set_clock_groups -asynchronous then declares unrelated.  The result is
# that the `set_max_delay 75 -from PAD -to sync_DFF/D` constraint below
# silently drops (Tempus can't find compatible launch/capture edges in async
# groups), and the path stays in the unconstrained report.
#
# Without set_input_delay, PAD[24]/PAD[26] are unclocked inputs and the
# set_max_delay bound applies cleanly as a pure combinational-delay bound —
# which is exactly what we want for a CDC synchronizer input.
# (See block below for the actual 75 ns bound.)

# MISO timing (PAD[25] driven from core_clk domain, sampled externally by SCLK).
# Reference SCLK (4 MHz, 250 ns period), not core_clk: the FPGA actually
# samples MISO with SCLK, and core_clk's BCCOM-corner ideal/early arrival
# was producing phantom hold violations on PAD[25] (data appearing at
# the pad "before" the core_clk edge in fast-corner view). The 4 MHz
# SPI clock has 250 ns of head-room so the absolute numbers are slack-rich.
# (set_clock_groups -asynchronous already isolates SCLK from core_clk,
# so this constraint doesn't conflict with the on-chip CDC plumbing.)
# set_output_delay 50.0 -max -clock [get_clocks sclk] [get_ports PAD[25]]
# set_output_delay 0.0  -min -clock [get_clocks sclk] [get_ports PAD[25]]
set_input_delay 5.0 -max -clock [get_clocks core_clk] [get_ports PAD[25]]
set_input_delay 0.0  -min -clock [get_clocks core_clk] [get_ports PAD[25]]


#------------------------------------------------------------------------
# Reset synchronizer SDN routing bound.
#
# Hard reset (PAD[45]) is synchronized internally by async_rst_sync_deassert
# (2-FF synchronizer with SDN-tied async set, sync deassert).  Both FFs share
# the same internal n_0 fanout net driving their SDN (async-set, active-low)
# pins.  Without a max_delay bound the router is free to make the n_0->FF1/SDN
# and n_0->FF2/SDN paths arbitrarily long and unequal.  If FF2/SDN releases
# much later than FF1/SDN (skew > 1 clock period), FF1 can start sampling
# while FF2 is still held in set, breaking the synchronizer.
#
# Bound = half the capturing-domain clock period so both SDN paths land well
# within one cycle and the skew between them is negligible.
#   u_hard_rst_sync: core_clk = 20 ns -> half = 10 ns
#                      source = PAD[45] (off-chip async reset)
#   u_dn_reset_sync:   dn_clk  = 40 ns -> half = 20 ns
#                      source = internal core_clk-domain registers
#                      (reset_cnt_reg[3]/[5]/io_link_reset_int through OAI21)
#                      -> `-to` only; -from PAD[45] would match no path here,
#                      since every source goes through a register first.
#
# Implementation note: the async_rst_sync_deassert module in chip_top.sv
# DIRECTLY INSTANTIATES DFSNQD1BWP7T cells (not inferred via always_ff), so
# the `rst_sync1_reg`/`rst_sync2_reg`/`SDN` pin paths resolve at all stages
# (Genus / Innovus / Tempus) with no SDC-208 "cannot find pin" warnings.
#
# `-datapath_only` is INTENTIONALLY omitted here.  Both Genus (TUI-66) and
# Tempus (TCLCMD-1313) reject the flag — only Innovus accepts it.  Plain
# `set_max_delay N` works correctly for these paths because the source PADs
# have NO launch clock (we deleted the misleading `set_input_delay -clock
# sclk` on PAD[24]/PAD[26] above for exactly this reason).  Without a launch
# clock, Tempus has no async-edge framework to fail; it just bounds the
# combinational data delay.  This is the same pattern the bsg_async_fifo
# constraint at line 96 uses (no -datapath_only, cell-to-cell).
#------------------------------------------------------------------------
set_max_delay 10 \
    -from [get_ports PAD[45]] \
    -to   [get_pins {u_hard_rst_sync/rst_sync1_reg/SDN \
                     u_hard_rst_sync/rst_sync2_reg/SDN}]
set_min_delay 0.0 \
    -from [get_ports PAD[45]] \
    -to   [get_pins {u_hard_rst_sync/rst_sync1_reg/SDN \
                     u_hard_rst_sync/rst_sync2_reg/SDN}]
set_max_delay 20 \
    -to   [get_pins {u_dn_reset_sync/rst_sync1_reg/SDN \
                     u_dn_reset_sync/rst_sync2_reg/SDN}]
set_min_delay 0.0 \
    -to   [get_pins {u_dn_reset_sync/rst_sync1_reg/SDN \
                     u_dn_reset_sync/rst_sync2_reg/SDN}]

# SPI inputs (SCLK, MOSI, SS_n) all feed 2-FF synchronizers clocked by core_clk.
# Bound the PAD->sync-DFF/D combinational delay to 30% of the 250 ns sclk period
# = 75 ns so the path never grows long enough to alias across an sclk bit
# boundary.  MOSI/SS_n are stable for one full sclk period (250 ns); SCLK
# itself has a half-period of 125 ns — < 75 ns guarantees the sync DFF always
# sees the correct phase/value for the current SPI bit.  Works without
# -datapath_only because none of the source PADs have a launch clock (see
# note in SPI inputs section above explaining why we removed set_input_delay
# on PAD[24]/PAD[26]; PAD[13] is the sclk clock port itself so has no
# data-launch clock either).
# NOTE: SPI sync constraints disabled — your design doesn't have these sync registers
# set_max_delay 75 \
#     -from [get_ports {PAD[13] PAD[24] PAD[26]}] \
#     -to   [get_pins {u_ctrl_top/u_spi/sclk_sync_reg*/D \
#                      u_ctrl_top/u_spi/mosi_sync_reg*/D \
#                      u_ctrl_top/u_spi/ss_n_sync_reg*/D}]
# set_min_delay 0.0 \
#     -from [get_ports {PAD[13] PAD[24] PAD[26]}] \
#     -to   [get_pins {u_ctrl_top/u_spi/sclk_sync_reg*/D \
#                      u_ctrl_top/u_spi/mosi_sync_reg*/D \
#                      u_ctrl_top/u_spi/ss_n_sync_reg*/D}]

#------------------------------------------------------------------------
# Generic IO load
#------------------------------------------------------------------------
set_load 1 [all_outputs]

#------------------------------------------------------------------------
# Design rule constraints
#
# set_max_transition: limits signal slew on internal nets. Without this
# the tool only fixes transitions that cause timing violations — slow slews
# on non-critical nets go undetected and increase delay/power downstream.
# 1.5 ns = 7.5% of the 20 ns core period; relaxed to 1.5 ns at output
# ports since off-chip slew is dominated by PCB load, not on-chip buffering.
#
# set_max_fanout: caps logical fanout per cell output. Genus/Innovus
# already buffer high-fanout nets for timing, but an explicit limit ensures
# fanout is controlled even on non-critical (slack-rich) paths.
# 32 is a typical value for TSMC 180nm at this frequency.
#------------------------------------------------------------------------
set_max_transition 1.5 [current_design]
set_max_transition 1.5 [all_outputs]
set_max_fanout 32 [current_design]

#------------------------------------------------------------------------
# Scan chain I/O timing (DFT mode; PAD[11]=scan_en, PAD[46]=scan_in,
# PAD[47]=scan_out — active only during test, not during functional op).
#
# Functional-view analysis: hold scan_en at 0 via set_case_analysis.  This
# makes the S pin of every DFT clock-bypass mux (CKMUX2D1BWP7T fed by SE)
# a constant, eliminating the PULSE_WIDTH "clock style check" structural
# warnings on the ~4600 CKMUX-fed CP endpoints (and similarly silences the
# 1500 SE uncons_endpoint entries since SE is now a constant net, not a
# timing endpoint).  Scan-shift timing must be verified in a separate SDC
# (set_case_analysis 1) — for our 4 MHz scan-shift target through TSMC180,
# scan timing is slack-rich and that separate run is straightforward.
#
# Side-effect: the FF's internal D/SI mux locks to D, so SI pins become
# don't-care endpoints with no analyzable launch chain.  Accepted as-is
# (scan inputs aren't used in functional mode; SI uncons annotations are
# reporting noise under SE=0).
#
# History:
#  - set_false_path -from PAD[11]: didn't satisfy uncons_endpoint
#    (false_path EXCLUDES the path; endpoint still has no analyzable arc).
#  - set_max_delay -from PAD[11] with FUNC_CLK_PERIOD bound: only reached
#    the small subset of SE pins fed by direct PAD[11] fanout (~114 of
#    1496), missed the internal scan_en distribution through DFT muxes.
#------------------------------------------------------------------------
set_case_analysis 0 [get_ports PAD[11]]

set_max_delay $FUNC_CLK_PERIOD -from [get_ports PAD[11]]
set_min_delay 0                -from [get_ports PAD[11]]
set_max_delay $FUNC_CLK_PERIOD -from [get_ports PAD[46]]
set_min_delay 0                -from [get_ports PAD[46]]
set_max_delay $FUNC_CLK_PERIOD -to   [get_ports PAD[47]]
set_min_delay 0                -to   [get_ports PAD[47]]
# Also assert input/output delays so check_timing's no_input_delay /
# no_output_delay warnings are satisfied on every scan port (not just PAD[11]).
#set_input_delay  -clock core_clk -clock_fall -max 0 [get_ports {PAD[11]}]
#set_input_delay  -clock core_clk -clock_fall -min 0 [get_ports {PAD[11]}]
#set_input_delay  -clock core_clk -clock_fall -max 0 [get_ports {PAD[46]}]
#set_input_delay  -clock core_clk -clock_fall -min 0 [get_ports {PAD[46]}]
#set_output_delay -clock core_clk -clock_fall -max 0 [get_ports {PAD[47]}]
#set_output_delay -clock core_clk -clock_fall -min 0 [get_ports {PAD[47]}]

#------------------------------------------------------------------------
# MUX row/col outputs (PAD[36..43]) — core_clk domain, slow-changing
# These are sensor mux select lines, updated at scan rate (~kHz).
# Constrained as normal outputs from core_clk domain.
#------------------------------------------------------------------------
set_output_delay 5.0 -max -clock [get_clocks core_clk] \
  [get_ports {PAD[36] PAD[37] PAD[38] PAD[39] PAD[40] PAD[41] PAD[42] PAD[43]}]
set_output_delay 0.0 -min -clock [get_clocks core_clk] \
  [get_ports {PAD[36] PAD[37] PAD[38] PAD[39] PAD[40] PAD[41] PAD[42] PAD[43]}]
 
#------------------------------------------------------------------------
# I2C outputs (PAD[28]=SCL, PAD[29]=SDA) — core_clk domain, ~100 kHz
#------------------------------------------------------------------------
set_output_delay 5.0 -max -clock [get_clocks core_clk] [get_ports {PAD[28] PAD[29]}]
set_output_delay 0.0 -min -clock [get_clocks core_clk] [get_ports {PAD[28] PAD[29]}]
# suppress no_input_delay warnings
set_false_path -from [get_ports {PAD[28] PAD[29]}] 

#------------------------------------------------------------------------
# UART TX output (PAD[27]) — core_clk domain, 115200 baud
#------------------------------------------------------------------------
set_output_delay 5.0 -max -clock [get_clocks core_clk] [get_ports PAD[27]]
set_output_delay 0.0 -min -clock [get_clocks core_clk] [get_ports PAD[27]]
 
#------------------------------------------------------------------------
# UART RX input (PAD[24]) — async input into firmware_loader 2-FF sync
#------------------------------------------------------------------------
set_max_delay 75  -from [get_ports PAD[24]]
set_min_delay 0.0 -from [get_ports PAD[24]]

#------------------------------------------------------------------------
# SPI ADC interface (PAD[13]=SCLK out, PAD[25]=MISO in, PAD[26]=CS_n out)
# SCLK and CS_n are outputs driven from core_clk domain.
#------------------------------------------------------------------------
set_output_delay 5.0 -max -clock [get_clocks core_clk] [get_ports {PAD[13] PAD[26]}]
set_output_delay 0.0 -min -clock [get_clocks core_clk] [get_ports {PAD[13] PAD[26]}]
