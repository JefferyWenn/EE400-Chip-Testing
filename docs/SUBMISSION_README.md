# Zeroscatter Tactile-Sensing Control SoC — Source Submission

EE 478B / 526B final project. TSMC 180 nm. Top module: `chip_top`.

## Directory structure

```
cfg/                              Hammer configuration, constraints, tcl
  cfg.yml, src.yml, dft.yml, tb.yml, par.yml   (Hammer config)
  constraints.tcl, scan_mode.sdc               (SDC timing + scan-mode)
  pad.tcl, chip_top_64_pins.io, place_pads.py  (floorplan / pad ring)
  power_straps.tcl, power_spec.cpf             (power delivery + CPF intent)
  tsmc180_scan.v                               (scan cell model)

zeroscatter/design/tactile-ctrl-chip/
  v/                              RTL (the canonical source built by src.yml)
    cpu/        SERV RV32I core + instruction/data RAM
    sensor_interface/  SPI master, I2C init, mux/scan control, ADC buffer
    dla_link/   bsg_link upstream packet builder, CNN result buffer
    uart/       UART boot loader, UART TX, packet framer
    top/        chip_top, ctrl_top, top
  c/                              Firmware source (firmware.c, dla_blob.h, crt0.S, linker, hex)

zeroscatter/                      Testbenches + firmware images
  chip_top_tb_syn.sv              Gate-level (post-syn/par) self-checking TB
  chip_top_tb.sv                  RTL end-to-end TB
  tb_tsmc_io_behav.v              Behavioral pad model
  *.hex                           Firmware images (firmware.hex + per-test images)

third_party/basejump_stl/         BaseJump STL files referenced by src.yml/tb.yml
                                   (Bespoke Silicon Group, UW — external IP, included for build)

Makefile                          Hammer flow entry (make syn / par / sim-syn / formal / drc / lvs)
FINAL_REPORT_DRAFT.md             Final report (convert to PDF)
```

## How to build

```
make syn          # synthesis (Genus)        make par        # place & route (Innovus)
make sim-syn      # gate-level sim + SDF      make formal-syn # LEC (Conformal)
make timing-par   # STA (Tempus)             make drc / lvs  # signoff (Calibre)
```

## External dependencies NOT included (required to build)

1. **TSMC 180 nm PDK** (standard-cell + IO libraries, `tcb018gbwp7t`, `PDDW1216CDG`) — foundry
   IP under NDA; not redistributable. Available in the course lab environment.
2. **ee478-hammer plugins** — the Hammer flow plugins. One required local modification: in
   `hammer-bsg-plugins/vcs-mk/generate_sim_cmd.py`, the gate-sim `noTiming` list must include
   the UART RX synchronizer (`... or "rx_sync_reg" in path:`) so async-input synchronizers do
   not X-propagate during SDF simulation.

## Credits

- **SERV** bit-serial RV32I core — Olof Kindgren (Apache-2.0).
- **BaseJump STL** (`bsg_link`, `bsg_async`, `bsg_dataflow`, `bsg_mem`, `bsg_misc`, `bsg_tag`)
  — Bespoke Silicon Group, University of Washington.
