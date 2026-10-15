# EE400 Chip Testing — Zeroscatter bring-up

Bring-up and testing of **Zeroscatter**, the tactile-sensing control SoC taped out in
EE 478 (TSMC 180 nm, top module `chip_top`, project 17896 "tactile #1 ctrl").

The design source here is the final tapeout version: identical to branch `6662026`
(commit `9438d5d`) of `momoka17/EE478-tactile-sensing-control`, which is also what went into
`zeroscatter_submission_clean`.

## Layout

```
chip/                     Hammer project (run make from here)
  Makefile                syn / par / sim-rtl / sim-syn / sim-par / sim-* unit tests
  cfg/                    Hammer yml, SDC, pad ring, power straps, CPF
  zeroscatter/            testbenches, firmware .hex images
    design/tactile-ctrl-chip/v/   RTL (SERV CPU, sensor IF, bsg_link ctl, UART)
    design/tactile-ctrl-chip/c/   firmware source (firmware.c, crt0.S, linker)
  third_party/basejump_stl/       BaseJump STL files used by the design
  klayout/                KLayout layer props + targets for viewing the GDS
ee478-hammer/             Hammer flow (pncel/ee478-hammer @ c89d94a + local edits)
docs/                     final report draft, PCB jumper/pinout notes,
                          ee478-hammer-local-edits.patch
reports/                  final syn/PAR area, timing, power reports; sim-syn/sim-par logs
file/                     EE400 reports (e.g. Oct 2026 "Memory Revival Sims & Layout")
screenshots/              dated layout / simulation screenshots used in reports
artifacts/   (git-ignored, local only)
  gds/                    chip_top.gds (PAR, Jun 6), chip_top_signoff_logo.gds
  netlist/                chip_top.{mapped,sim,lvs}.v, chip_top.{mapped,par}.sdf
  sim/                    novas.fsdb (post-layout sim waveform)
  course-figures/         course tapeout-tutorial screenshots
```

This repo is public. Foundry-derived and lab-private files are **never committed** and must be
copied by hand if you move to another lab machine:

- `artifacts/`
- `chip/cfg/tsmc180_scan.v` (scan-cell models adapted from the TSMC library; only needed for ATPG)
- `ee478-hammer/hammer/src/hammer-vlsi/technology/tsmc180/` (TSMC technology plugin)
- `ee478-hammer/hammer-mentor-plugins/`

## Common commands (from `chip/`)

```
make open-chip-final                   # open taped-out Innovus database (artifacts/innovus)
make -C klayout open-presignoff        # view final PAR GDS in KLayout
make -C klayout open-signoff-logo      # view signoff GDS (seal ring, fill, logo)
make sim-rtl                           # build + run RTL sim (default firmware; ~1 min, TEST_PASS)
make sim-dma-e2e                       # then other tests reuse simv: sim-uart / sim-full / ...
make view-sim-rtl                      # open waveform.fsdb in Verdi (sets license + VERDI_HOME)
                                       # in nWave: File > Restore Signal > sim_overview.rc
make syn | par | sim-syn | sim-par     # full flow (long — run on the lab machine)
```

The flow needs the course lab environment (TSMC 180 nm PDK, Cadence/Synopsys tools).

## Bring-up notes

- `scan_en` (PAD[11]) **must be tied low**, or the chip will not come out of reset.
- Key results to compare against silicon: core_clk 50 MHz / dn_clk 25 MHz targets, setup WNS
  +0.119 ns at WCCOM, 2.80 mm² die (1620 × 1730 µm), UART boot at 115 200 baud.
- Open question: the signoff GDS (`chip_top_signoff_logo.gds`, Jun 2) predates the final PAR
  GDS (Jun 6). Confirm which one was submitted to the foundry.
