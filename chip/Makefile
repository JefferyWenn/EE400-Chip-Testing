# Makefile for Module 0 clk_gen design

TOP_DIR := $(realpath ../ee478-hammer)
OBJ_DIR := build
INPUT_CFGS := cfg/cfg.yml cfg/src.yml
TB_CFGS := cfg/tb.yml
export OBJ_DIR

# Pin VERDI_HOME to the version Hammer's vcs build is linked against
# (Q-2020.03-SP2-8 has libsscore_vcs202003.so, matching VCS Q-2020.03-SP1).
# Some lab shell profiles default VERDI_HOME to a newer Verdi which is
# missing this lib — and simv silently fails to dump FSDB at run time
# with "Cannot load libsscore_vcs202003.so". Exporting here cascades to
# all sub-make recipes including the ./simv invocation in vcs-mk/include.mk.
override VERDI_HOME := /home/projects/ee477.2025wtr/cad/synopsys/verdi/Q-2020.03-SP2-8
export VERDI_HOME

# BaseJump STL location (for bsg_link DDR upstream/downstream cores).
# Tracked as a git submodule at third_party/basejump_stl, so a fresh clone
# of this repo gets it via `git submodule update --init --recursive`.
# Students who copy this directory from the shared filesystem already have
# the populated checkout, so no extra step is needed.
# Override module_top.mk's default of $(TOP_DIR)/../basejump_stl so the
# repo-local checkout takes precedence. module_top.mk wraps this in
# $(realpath ...) when writing paths.yml, so the path must exist by the
# time `make par` / `make syn` etc. run.
BASEJUMP_STL_PATH := third_party/basejump_stl

# Optional DFT scan chain insertion.
# Toggle below: set DFT to 1 to enable, 0 to disable. Can still be
# overridden on the command line: `make DFT=0 par` or `make DFT=1 par`.
DFT ?= 1

ifeq ($(DFT),1)
INPUT_CFGS += cfg/dft.yml
endif

include $(TOP_DIR)/module_top.mk

# Force $(OBJ_DIR)/paths.yml to regenerate whenever this Makefile changes.
# module_top.mk's rule has only an order-only prerequisite ($(OBJ_DIR)),
# so a stale paths.yml — e.g. left behind when this directory is copied
# from another user — survives until manually deleted. Adding Makefile
# as a real prereq kicks the `bsg_root: $(realpath ...)` regen any time
# BASEJUMP_STL_PATH is edited or the Makefile is otherwise touched.
$(OBJ_DIR)/paths.yml: Makefile

TEMPUS_BIN ?= /home/projects/ee477.2025wtr/cad/cadence/SSV/SSV211/bin/tempus
CDS_LIC_FILE ?= 27006@cadencels.s.uw.edu

# ── ASIC-level unit test targets ─────────────────────────────────────────────
# Each target runs simv with a specific firmware hex and checks per-test criteria.
# Requires 'make sim-rtl' to have been run first (builds the simv binary).
SIMV         := $(OBJ_DIR)/sim-rtl-rundir/simv
SIM_LOG_DIR  := $(OBJ_DIR)/sim-rtl-rundir

.PHONY: sim-uart sim-scan sim-dma sim-dma-e2e sim-rx sim-uart-boot sim-bsg-tx sim-full sim-all-asic finishing sealring arrow project_number dummy logo signoff_drc signoff_lvs clean atpg atpg-sim timing-par-dft timing-par-removal

sim-uart: $(SIMV)
	@echo "==> Running ASIC test: test_uart"
	$(SIMV) +TEST=test_uart 2>&1 | tee $(SIM_LOG_DIR)/run_test_uart.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_uart.log && \
	    echo "RESULT: test_uart PASS" || echo "RESULT: test_uart FAIL"

sim-scan: $(SIMV)
	@echo "==> Running ASIC test: test_scan"
	$(SIMV) +TEST=test_scan 2>&1 | tee $(SIM_LOG_DIR)/run_test_scan.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_scan.log && \
	    echo "RESULT: test_scan PASS" || echo "RESULT: test_scan FAIL"

sim-dma: $(SIMV)
	@echo "==> Running ASIC test: test_dma"
	$(SIMV) +TEST=test_dma 2>&1 | tee $(SIM_LOG_DIR)/run_test_dma.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_dma.log && \
	    echo "RESULT: test_dma PASS" || echo "RESULT: test_dma FAIL"

sim-bsg-tx: $(SIMV)
	@echo "==> Running ASIC test: test_bsg_tx"
	$(SIMV) +TEST=test_bsg_tx 2>&1 | tee $(SIM_LOG_DIR)/run_test_bsg_tx.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_bsg_tx.log && \
	    echo "RESULT: test_bsg_tx PASS" || echo "RESULT: test_bsg_tx FAIL"

# Full scan -> DMA -> BSG link -> DLA mock -> RX -> cnn_buf -> 0xB0 loop.
# This is the highest-risk silicon path, proven end to end.
sim-dma-e2e: $(SIMV)
	@echo "==> Running ASIC test: test_dma_e2e"
	$(SIMV) +TEST=test_dma_e2e 2>&1 | tee $(SIM_LOG_DIR)/run_test_dma_e2e.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_dma_e2e.log && \
	    echo "RESULT: test_dma_e2e PASS" || echo "RESULT: test_dma_e2e FAIL"

# Inbound DLA-response / 0xB0 framing path in isolation (DLA mock fires early,
# decoupled from the outbound DMA burst).
sim-rx: $(SIMV)
	@echo "==> Running ASIC test: test_rx"
	$(SIMV) +TEST=test_rx 2>&1 | tee $(SIM_LOG_DIR)/run_test_rx.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_rx.log && \
	    echo "RESULT: test_rx PASS" || echo "RESULT: test_rx FAIL"

# Real UART firmware boot via the on-chip firmware_loader (FAST_LOAD=0).
sim-uart-boot: $(SIMV)
	@echo "==> Running ASIC test: test_uart_boot"
	$(SIMV) +TEST=test_uart_boot 2>&1 | tee $(SIM_LOG_DIR)/run_test_uart_boot.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_uart_boot.log && \
	    echo "RESULT: test_uart_boot PASS" || echo "RESULT: test_uart_boot FAIL"

sim-full: $(SIMV)
	@echo "==> Running ASIC test: test_full"
	$(SIMV) +TEST=test_full 2>&1 | tee $(SIM_LOG_DIR)/run_test_full.log
	@grep -q "TEST_PASS" $(SIM_LOG_DIR)/run_test_full.log && \
	    echo "RESULT: test_full PASS" || echo "RESULT: test_full FAIL"

sim-all-asic: sim-rtl sim-uart sim-scan sim-dma sim-dma-e2e sim-rx sim-uart-boot sim-bsg-tx sim-full
	@echo ""
	@echo "=== ASIC TEST SUMMARY ==="
	@for log in $(SIM_LOG_DIR)/run_test_*.log $(SIM_LOG_DIR)/run.log; do \
	    test=$$(basename $$log .log | sed 's/run_//'); \
	    if grep -q "TEST_PASS" $$log 2>/dev/null; then \
	        echo "  PASS: $$test"; \
	    else \
	        echo "  FAIL: $$test"; \
	    fi; \
	done

.PHONY: finishing sealring arrow project_number dummy logo signoff_drc signoff_lvs clean atpg atpg-sim

finishing: sealring arrow project_number dummy logo signoff_drc signoff_lvs

# Run Modus ATPG on the synthesized + scan-stitched netlist.
# Requires `make syn` (with DFT=1) to have completed; reads
# build/syn-rundir/atpg_setup/runmodus.atpg.tcl that write_dft_atpg
# generated. After it finishes, check coverage in
# build/syn-rundir/atpg_setup/testresults/logs/log_create_logic_tests_FULLSCAN_chip_top_atpg
# (look for the final TDA-220 line; healthy designs hit >=95%).
MODUS ?= /home/lab.apps/vlsiapps_new/modus/current/bin/modus
atpg:
	@if [ ! -f $(OBJ_DIR)/syn-rundir/atpg_setup/runmodus.atpg.tcl ]; then \
		echo "ERROR: $(OBJ_DIR)/syn-rundir/atpg_setup/runmodus.atpg.tcl not found."; \
		echo "       Run 'make syn' with DFT=1 first."; \
		exit 1; \
	fi
	cd $(OBJ_DIR)/syn-rundir && $(MODUS) -file atpg_setup/runmodus.atpg.tcl

# Back-simulate the Modus-generated ATPG patterns against the gate-level
# netlist using Xcelium. Sanity check that the patterns produce the
# expected outputs before trusting them. Requires `make atpg` first.
# A successful run ends with no FAILSET mismatches; the log lands in
# build/syn-rundir/atpg_setup/ncverilog_FULLSCAN.log.
atpg-sim:
	@if [ ! -x $(OBJ_DIR)/syn-rundir/atpg_setup/run_fullscan_sim ]; then \
		echo "ERROR: $(OBJ_DIR)/syn-rundir/atpg_setup/run_fullscan_sim not found."; \
		echo "       Run 'make atpg' first."; \
		exit 1; \
	fi
	cd $(OBJ_DIR)/syn-rundir && ./atpg_setup/run_fullscan_sim

# Run scan-mode Tempus timing analysis (DFT sign-off).
# scan_clk = 20 ns (50 MHz), scan_en=1, scan_in modeled as changing at falling edge.
# dont_scan clock domains (dn_clk/token_clk/sclk) are false-pathed.
# Reports land in $(OBJ_DIR)/timing-par-rundir/chip_top_timing_scan_*.rpt.
#
# Requires `make timing-par` to have run first — reuses its rundir, SPEF, netlist.
# scan_mode.sdc is sourced from cfg/scan_mode.sdc (versioned in repo).
# timing_scan.tcl and scan_mmmc.tcl are auto-generated from Hammer's timing.tcl /
# mmmc.tcl so absolute paths stay correct for any user.
SCAN_SDC := $(abspath cfg/scan_mode.sdc)
timing-par-dft:
	@[ -f $(OBJ_DIR)/timing-par-rundir/timing.tcl ] || \
	  { echo "ERROR: $(OBJ_DIR)/timing-par-rundir/timing.tcl not found."; \
	    echo "       Run 'make timing-par' first."; exit 1; }
	sed -e 's|[^[:space:]]*chip_top\.par\.sdc|$(SCAN_SDC)|g' \
	    -e 's|my_constraint_mode|scan_constraint_mode|g' \
	    $(OBJ_DIR)/timing-par-rundir/mmmc.tcl \
	    > $(OBJ_DIR)/timing-par-rundir/scan_mmmc.tcl
	sed -e 's|read_mmmc [^[:space:]]*mmmc\.tcl|read_mmmc scan_mmmc.tcl|g' \
	    -e 's|chip_top_timing_setup\.rpt|chip_top_timing_scan_setup.rpt|g' \
	    -e 's|chip_top_timing_hold\.rpt|chip_top_timing_scan_hold.rpt|g' \
	    -e 's|chip_top_timing_unconstrained\.rpt|chip_top_timing_scan_unconstrained.rpt|g' \
	    -e 's|write_db -overwrite pre_run_sta|write_db -overwrite pre_scan_sta|g' \
	    -e 's|write_db -overwrite post_run_sta|write_db -overwrite post_scan_sta|g' \
	    -e 's|ln -sfn pre_run_sta latest|ln -sfn pre_scan_sta latest|g' \
	    -e 's|ln -sfn post_run_sta latest|ln -sfn post_scan_sta latest|g' \
	    $(OBJ_DIR)/timing-par-rundir/timing.tcl \
	    > $(OBJ_DIR)/timing-par-rundir/timing_scan.tcl
	sed -i 's|^exit$$|report_timing -check_type removal  -retime path_slew_propagation -max_paths 100 > chip_top_timing_scan_removal.rpt\nreport_timing -check_type recovery -retime path_slew_propagation -max_paths 100 > chip_top_timing_scan_recovery.rpt\nexit|' \
	    $(OBJ_DIR)/timing-par-rundir/timing_scan.tcl
	cd $(OBJ_DIR)/timing-par-rundir && \
	  CDS_LIC_FILE=$(CDS_LIC_FILE) $(TEMPUS_BIN) \
	    -no_gui -stylus -files timing_scan.tcl > timing_scan_run.log 2>&1
	@echo "==> Scan setup    : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_scan_setup.rpt"
	@echo "==> Scan hold     : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_scan_hold.rpt"
	@echo "==> Scan removal  : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_scan_removal.rpt"
	@echo "==> Scan recovery : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_scan_recovery.rpt"

# Run removal/recovery checks on the functional post-PAR timing database.
# Reloads post_run_sta saved by `make timing-par` — no full re-analysis needed.
timing-par-removal:
	@[ -d $(OBJ_DIR)/timing-par-rundir/post_run_sta ] || \
	  { echo "ERROR: post_run_sta not found. Run 'make timing-par' first."; exit 1; }
	printf 'read_db post_run_sta\n\
report_timing -check_type removal  -retime path_slew_propagation -max_paths 100 > chip_top_timing_removal.rpt\n\
report_timing -check_type recovery -retime path_slew_propagation -max_paths 100 > chip_top_timing_recovery.rpt\n\
exit\n' > $(OBJ_DIR)/timing-par-rundir/removal_check.tcl
	cd $(OBJ_DIR)/timing-par-rundir && \
	  CDS_LIC_FILE=$(CDS_LIC_FILE) $(TEMPUS_BIN) \
	    -no_gui -stylus -files removal_check.tcl > removal_check_run.log 2>&1
	@echo "==> Removal  : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_removal.rpt"
	@echo "==> Recovery : $(OBJ_DIR)/timing-par-rundir/chip_top_timing_recovery.rpt"

sealring:
	$(MAKE) -C ./sealring

arrow:
	$(MAKE) -C ./arrow

project_number:
	$(MAKE) -C ./project_number

dummy:
	$(MAKE) -C ./dummy

logo:
	$(MAKE) -C ./logo

signoff_drc:
	$(MAKE) -C ./signoff_drc

# Calibre signoff LVS uses the SPICE netlist Hammer's lvs step writes to
# build/lvs-rundir/chip_top.include.sp. If that file isn't there yet,
# trigger Hammer's `make lvs` first so users don't have to remember.
LVS_INCLUDE_SP := $(OBJ_DIR)/lvs-rundir/chip_top.include.sp
signoff_lvs: $(LVS_INCLUDE_SP)
	$(MAKE) -C ./signoff_lvs

$(LVS_INCLUDE_SP):
	@echo "==> $(LVS_INCLUDE_SP) not found; running Hammer 'make lvs' first"
	$(MAKE) lvs

open-signoff:
	$(MAKE) -C ./klayout open-signoff-logo

clean:
	$(MAKE) -C ./sealring clean
	$(MAKE) -C ./arrow clean
	$(MAKE) -C ./dummy clean
	$(MAKE) -C ./logo clean
	$(MAKE) -C ./signoff_drc clean
	$(MAKE) -C ./signoff_lvs clean



