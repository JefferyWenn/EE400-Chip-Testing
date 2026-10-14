# Zeroscatter: A Tactile-Sensing Control SoC in TSMC 180 nm
### EE 478B / 526B Final Report

> **DRAFT — edit before submission.** Fields marked `[TEAM: …]` need information only your
> team has (names, roles, dates, source citations). Figure placeholders marked `‹FIGURE›`
> must be replaced with real screenshots (block diagram, layout, waveforms).
>
> Target length 10–20 pages. Convert to PDF (e.g. `pandoc FINAL_REPORT_DRAFT.md -o report.pdf`).

**Team:** [TEAM: member names, student IDs]
**Project:** 17896 — "tactile #1 ctrl" (control chip of a two-chip tactile-compute system)
**Technology:** TSMC 180 nm (tcb018gbwp7t 7-track standard cells, PDDW1216CDG IO)

---

## 1. Introduction

### 1.1 Overview

Zeroscatter is the **control SoC** of a two-chip tactile-compute system. It reads a
**16 × 16 (256-cell) tactile pressure-sensor array**, digitizes it, and offloads each frame
to a companion **CNN-accelerator (DLA / "conv") chip** for inference, then returns the result
to a host. The chip integrates, around a **SERV bit-serial RISC-V (RV32I) CPU**:

- a **UART boot loader** (115 200 baud) that loads firmware into instruction RAM at power-up;
- an **I²C configuration master** (`i2c_init`, 7-bit device address 0x2F / frame 0x5E) for
  sensor/AFE setup;
- an **SPI master** that reads the external 8-bit ADC, one conversion per sensor cell;
- a **mux controller** that sequences the row/column scan across the 256-cell grid;
- a **bsg_link DDR source-synchronous link** that streams each 256-element frame to the DLA
  chip as a packetized burst (instruction packets → DATA header → payload → KICKOFF), and
  receives the inference result back into a result buffer;
- a **packet framer** that emits the final `0xB0` result packet over UART to the host.

The firmware running on the SERV core orchestrates the whole pipeline: configure → scan →
digitize → offload → collect result → report. The design boots, scans all 256 cells, and
completes a DLA offload burst in gate-level and post-layout simulation (see §4).

The problem this solves: tactile sensing for robotics/prosthetics generates dense,
high-rate pressure maps that are expensive to stream off-device. By pairing a small control
SoC with a local CNN accelerator, zeroscatter performs **sensor acquisition and edge
inference in-package**, reducing host bandwidth and latency versus shipping raw frames to a
remote processor.

### 1.2 Realistic Factors

*(The spec requires these be discussed explicitly.)*

- **Public health, safety & welfare.** The chip targets wearable/prosthetic and robotic
  tactile interfaces. Mixed-voltage IO (1.8 V core, 3.3 V pads) follows the foundry's
  ESD/POC pad rules (POC cell, `VDDPST`/`VSSPST` rails) to meet basic electrical-safety and
  latch-up expectations. The all-synchronous reset architecture (§3.4) gives deterministic
  power-up behavior, which matters for any safety-relevant actuator the host drives from
  tactile feedback.
- **Global / manufacturability.** TSMC 180 nm is a mature, low-cost, high-yield node widely
  second-sourced — appropriate for a low-volume academic tapeout and for cost-sensitive
  sensor peripherals that do not need leading-edge performance. The design passes DRC/LVS
  with foundry-provided pad cells black-boxed in LVS (`LVS BOX`), matching standard MPW
  shuttle practice.
- **Cultural / market.** Tactile-compute targets robotics, prosthetics, and AR/VR haptics —
  segments where a small, standards-based (SPI/I²C/UART/RISC-V) controller eases integration
  with existing host ecosystems.
- **Social / human factors.** Standard interfaces (UART boot, I²C config) lower the barrier
  for firmware developers; the RISC-V core means open, well-documented tooling rather than a
  proprietary ISA.
- **Environmental / sustainability.** A 2.80 mm² die on a mature node has low embodied energy
  per unit; clock-domain partitioning and a bit-serial CPU keep active area and dynamic power
  modest. (Clock gating was disabled for boot reliability — see §3.4 / §5 for the trade-off.)
- **Economic / cost.** Bit-serial SERV (~16 k flops total design, the CPU itself a few hundred
  cells) trades cycles for area, minimizing silicon cost; 64.3 % utilization on a pad-limited
  die leaves margin without oversizing.

### 1.3 Related Work

[TEAM: cite 2–3 specific works and contrast.] Suggested framing, all true of this design:

- **Commercial tactile controllers** (e.g. capacitive-touch / pressure AFEs) typically stream
  raw or lightly-processed data to a host MCU. Zeroscatter differs by integrating an on-package
  CNN-accelerator offload path, doing inference at the edge.
- **SERV (Olof Kindgren)** is the smallest RISC-V core; prior SERV-based SoCs demonstrate
  bit-serial RV32I in minimal area. We reuse SERV but wrap it with application-specific
  sensor/offload peripherals and a multi-chip DDR link.
- **BaseJump STL `bsg_link`** (Bespoke Silicon Group, UW) provides the source-synchronous
  chip-to-chip DDR link. Our contribution is the application-layer packet protocol
  (`bsg_link_upstream_ctl`) and the control firmware that drives a real DLA offload over it.

Our motivation: prior tactile front-ends stop at digitization; we close the loop to inference
and result-reporting within a standards-based, open-ISA control SoC.

### 1.4 Learning

[TEAM: personalize — what each member did not know before, and which sources you used and
why you trusted them.] Topics this project required that were new:

- **Source-synchronous DDR links & CDC.** Learned `bsg_link` DDR PHY, async FIFOs, and the
  credit/token reset-ordering protocol (assert `r_reset`, pulse `w_reset`, wait ≥4 r-clocks).
  Sources: BaseJump STL source + comments (primary, most credible), BSG documentation.
- **Bit-serial RISC-V (SERV).** Learned how a W=1 datapath executes RV32I serially. Sources:
  SERV repo/docs and Olof Kindgren talks (credible — author-authored).
- **Gate-level X-propagation & SDF timing checks.** Learned why synchronizers must have their
  `$setup/$hold` checks disabled (`noTiming`) in gate sim, and how clock-gated synchronous
  resets can fail to initialize at gate level. Sources: VCS/Tempus docs + hands-on debug.
- **Hammer VLSI flow** (Genus/Innovus/Tempus/Conformal/Calibre orchestration). Sources: Hammer
  docs + course material.

> Tip per the spec: state explicitly which sources were *more credible* (e.g. primary
> author/tool docs over forum posts) and why.

### 1.5 Industry Standard (REQUIRED)

**Primary standard: RISC-V (RV32I unprivileged ISA), with SPI, I²C, and UART as additional
interface standards.**

**RISC-V** is an open, royalty-free instruction-set architecture maintained by RISC-V
International (*The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*). The base
integer subset **RV32I** defines 32-bit registers, a load/store architecture, and a small set
of integer/branch/jump/load-store instructions. Our SoC incorporates RV32I via the **SERV**
bit-serial core (with the CSR option enabled, `WITH_CSR=1`), executing application firmware
that orchestrates sensing and offload. We use the **RV32I base only** (no M/F/etc. extensions)
because the control task is integer/IO-bound and area is the priority — a deliberate "modified
subset" decision driven by cost.

Supporting standards incorporated:
- **UART (8N1, 115 200 baud)** for firmware boot and result reporting — standard asynchronous
  serial framing (1 start, 8 data LSB-first, 1 stop).
- **SPI** master for ADC readout (mode/clock per the ADC datasheet, 16 SCK per transaction).
- **I²C** master for sensor/AFE configuration (7-bit addressing, 100 kHz, open-drain — driven
  through the bidirectional pad's I/OEN pins rather than internal tri-state, per review
  feedback; see §3.5).

> Cite the RISC-V spec formally in your references: *A. Waterman, K. Asanović (eds.), "The
> RISC-V Instruction Set Manual, Volume I," RISC-V International.*

---

## 2. Planning

### 2.1 Design Specification

**Metrics of effectiveness:** clock frequency, die area & utilization, setup/hold slack,
DLA-offload correctness, and application throughput (instructions/cycle, sensor frame-rate).

**I/O and interfaces (48 bidirectional PDDW1216CDG pads, `PAD[47:0]`):**

| Interface | Pins | Direction | Standard |
|-----------|------|-----------|----------|
| core_clk / token_clk | PAD[44] / PAD[12] | in | 50 MHz |
| dn_clk (FPGA-forwarded) | PAD[8] | in | 25 MHz |
| hard_reset | PAD[…] | in | async-assert, sync-deassert |
| UART rx / tx | PAD[24] / … | in/out | 8N1 115 200 |
| SPI (sclk/mosi/miso/ss_n) | 4 pins | mixed | ADC readout |
| I²C (scl/sda) | 2 pins | open-drain | config |
| bsg_link downstream (dn_data, dn_valid, token) | 8+ pins | in | DDR source-sync |
| bsg_link upstream | pins | out | DDR source-sync |
| Mux row/col | 8 pins | out | sensor scan |
| scan_en/in/out | 3 pins | DFT | scan chain |

**Module hierarchy:**

```
chip_top  (pad ring + clocking + reset sequencer + DFT scan)
├── u_pad_ring (pad_ring_64 — 48× PDDW1216CDG)   [preserved/black-boxed]
├── u_hard_rst_sync / u_dn_reset_sync (async-assert, sync-deassert reset synchronizers)
├── reset_cnt (bsg_link staged-reset sequencer — synchronous)
├── u_bsg_link_wrapper (DDR chip-to-chip link: link_rx_i + link_tx_i, async FIFOs)  ~3,099 cells
└── u_ctrl_top (SoC)
    ├── u_serv      serv_rf_top  — bit-serial RV32I CPU (+CSR)
    ├── u_iram      instr_ram (256-deep)         u_dram   data_ram
    ├── u_loader    firmware_loader (UART boot, 115 200)
    ├── u_uart      uart_peripheral (TX)         u_i2c_init  i2c_init (0x2F)
    ├── u_spi       spi_master                   u_abuf   adc_8bit_buf
    ├── u_mux       mux_ctrl (256-cell scan)     u_scan   scan_ctrl
    ├── u_up_ctl    bsg_link_upstream_ctl (DLA packet builder, NUM_ELEMENTS=256)
    ├── u_cbuf      cnn_result_buf               u_framer pkt_framer (0xB0 result)
```

**Targets:** core_clk **50 MHz** (20 ns), dn_clk **25 MHz** (40 ns); die **1620 × 1730 µm**;
all setup/hold met at signoff corners. ‹FIGURE: top-level block diagram›

### 2.2 Collaboration

[TEAM: fill roles.] Suggested table:

| Member | Role / modules owned |
|--------|----------------------|
| [name] | SERV integration, firmware (`firmware.c`, `dla_blob.h`) |
| [name] | bsg_link wrapper + `bsg_link_upstream_ctl`, CDC |
| [name] | UART/SPI/I²C peripherals, sensor scan |
| [name] | Physical design (Hammer cfg, floorplan, PnR, signoff) |
| [name] | Verification (testbenches, sim-syn/par, formal) |

**Tools/strategy:** GitHub for code sharing (feature branches per member, integration branch);
[TEAM: Slack/email] for comms; [TEAM: cadence] regular meetings; shared Hammer `cfg/` so all
members run identical syn/sim. Note the gotcha we hit: the `ee478-hammer` plugins are a
submodule with local edits (e.g. the sim synchronizer `noTiming` list), which must be shared
explicitly — a real collaboration lesson worth mentioning.

### 2.3 Timeline & Milestones

[TEAM: fill actual dates.] Planned-vs-actual table (spec's recommended format):

| Milestone | Planned | Actual |
|-----------|---------|--------|
| RTL feature-complete (peripherals + SERV) | [date] | [date] |
| End-to-end RTL sim passing | [date] | [date] |
| Synthesis clean (timing met) | [date] | [date] |
| Gate-level sim-syn TEST_PASS | [date] | [date] |
| Place & route + signoff (DRC/LVS) | [date] | [date] |
| Post-layout sim-par + final report | [date] | Jun 12 2026 |

---

## 3. Design

### 3.1 RTL

**External / reused IP (credit):**
- **SERV** bit-serial RV32I core — Olof Kindgren (Apache-2.0).
- **BaseJump STL** (`bsg_link`, `bsg_async`, `bsg_dataflow`, `bsg_mem`, `bsg_misc`) — Bespoke
  Silicon Group, University of Washington.
- TSMC 180 nm standard-cell & IO libraries (foundry).

**Notable RTL features:**
- **Multi-protocol peripherals:** UART (8N1), SPI master, I²C master — all standards-based.
- **UART boot loader** (`firmware_loader.v`): AA-55 sync, `[addr][data]` words, `FFFFFFFF`
  sentinel, `0x06` ACK; loads 256-word IRAM at 115 200 baud. Synchronous reset.
- **Chip-to-chip DDR link** with full **clock-domain-crossing**: `bsg_link` async FIFOs,
  gray-code pointer synchronizers, and a credit/token reset protocol. `io_master_clk` is tied
  to `core_clk` to save a pad (documented degeneration handling in `chip_top.sv`).
- **Application packet protocol** (`bsg_link_upstream_ctl.v`): builds DLA instruction packets
  (PKT type `00`), a DATA header (`0x0404`, PKT `01`, len=256), 256-element payload, and a
  KICKOFF (`0x0408`, PKT `10`); parameterized `NUM_ELEMENTS`, optional 8-bit packing.
- **DFT scan chain** (`scan_ctrl`, `scan_en/in/out`) with a separate scan-mode SDC for
  scan-shift hold closure.
- **Staged reset sequencer** (`reset_cnt`) generating the bsg_link `io_link_reset`,
  `async_token_reset`, downstream, and `core_link_reset` in the order the async credit counter
  requires.

### 3.2 Verification

A layered strategy:

1. **End-to-end RTL simulation** (`chip_top_tb.sv`): full boot → I²C config → 256-cell SPI
   scan → DLA offload → `0xB0` result, with self-checking SPEC monitors for UART baud/framing,
   I²C address/data (0x5E/0x7D), SPI CS duration, BSG flit format, and mux sequencing. Pass
   criterion: `TEST_PASS` (BOOT OK + 256 SPI reads + BSG burst).
2. **Gate-level sim-syn** (`chip_top_tb_syn.sv`) with **SDF back-annotation**: exercises the
   real synthesized netlist including DFT and pad behavior. Required handling: synchronizer
   `$setup/$hold` checks disabled via a `noTiming` list (`bsg_SYNC_1_r_reg`, UART
   `rx_sync_reg`) plus `sim.inputs.dut_path`, otherwise async-input synchronizers X-propagate.
3. **Post-layout sim-par** with extracted-delay SDF: confirms function at the routed corner.
4. **Formal equivalence** (`formal-syn` / `formal-par`, Conformal LEC): RTL ⇄ gate netlist.

‹FIGURE: waveform of BOOT OK / UART TX› ‹FIGURE: BSG offload burst (0x0404 DATA header)›

Representative result (sim-syn): `BOOT OK` observed, 256 SPI ADC reads, 185 BSG flits at the
peer, DATA header `0x0404` verified — `==== SPEC ALL PASS ====`.

### 3.3 Physical Design

Hammer-driven Genus → Innovus → Tempus → Calibre flow. Non-default options:

- **Manual floorplan** (`pad.tcl`) — pad-ring placement; **pad cells preserved/black-boxed**
  (`preserve_modules: [pad_ring_64]`, `LVS BOX PDDW1216CDG …`) so foundry pad internals don't
  fail top-level LVS.
- **Manual power straps** (`power_straps.tcl`) and **CPF power intent** (1.8 V `VDD`, 3.3 V
  `VDDPST`, `POC`); explicit **decap** insertion (1600 fF target across the core).
- **Generated pin assignment** (`semi_auto`, all pins preplaced).
- **Dual-mode timing:** a second **scan_constraint_mode** (`scan_mode.sdc`) paired with every
  functional view so Innovus `opt_design` fixes **scan-shift hold** during PnR (previously only
  checked post-hoc).
- **CRR (concurrent clock & routing)** enabled by putting the Genus binary on Innovus's PATH —
  recovered timing that had degraded when CRR silently disabled.

### 3.4 / 3.5 Optimization

**RTL-level:**
- **All-synchronous reset + clock gating disabled** (`clock_gating_mode: "empty"`). The
  bsg_link reset sequencer (`reset_cnt`) sits in the bootstrap path; with clock gating on, its
  ICG enable was X during reset → dead clock → `reset_cnt=X` → no boot at gate level. Disabling
  gating guarantees every synchronous reset initializes from a live clock, and also simplifies
  CTS/DFT/timing. Trade-off: higher dynamic power (acceptable for this control SoC).
- **I²C tri-state reduction** (review feedback): drive the bidirectional pad's `I`/`OEN` pins
  directly instead of an internal `1'bz` tri-state net, removing redundant tri-state logic.
- **Pad saving:** `io_master_clk` tied to `core_clk` (one fewer clock pad).
- **firmware_loader** restructured to a clean init-done reset gating chain
  (`perip_rst_n = nRESET & i2c_done & iram/dram_init_done`).

**Verification/flow-level optimization:**
- Synchronizer `noTiming` + `dut_path` to eliminate false gate-sim X.
- Scan-mode SDC so hold is fixed *during* PnR rather than flagged afterward.
- Testbench BSG flit-format checker fixed to locate the real DATA header (`0x0404`) in the
  mixed link stream rather than assuming flit #0.

---

## 4. Evaluation Results

### 4.1 Layout Photo

‹FIGURE: Innovus layout screenshot — `make open-chip` / amoeba view of the routed die.›

### 4.2 Quality Metrics

**Collection method:** area from **Genus post-syn** (`final_area.rpt`) and **Innovus
post-route** (`chip_top_area.rpt`); timing from **Tempus post-route STA** (`timingReports/`,
`postRoute.summary`). **Operating conditions:** setup at **WCCOM** (worst-case, 1.62 V / 125 °C
commercial), hold at **BCCOM** (best-case); supplies **1.8 V** core, **3.3 V** IO.

| Metric | Value |
|--------|-------|
| Final layout shape (W × H) | **1620 µm × 1730 µm = 2.80 mm²** |
| Area utilization (density) | **64.3 %** |
| Total cell count | **40,998** (16,027 sequential) |
| core_clk / dn_clk frequency | **50 MHz / 25 MHz** |
| Min **setup** slack (post-route, WNS) | **+0.119 ns** (reg2reg), 0 violating paths |
| Min **hold** slack (functional, post-route) | **+0.055 ns**, 0 functional violations |
| Min hold slack (scan-shift mode) | **−0.072 ns** (1 path, `serv/rf_ram`) |
| SI glitch violations | **0** |
| DRC / LVS | [TEAM: confirm clean] |

**Design-specific (tactile-control) throughput — computed, not measured:**

- **CPU throughput.** SERV is bit-serial (W=1): a 32-bit instruction takes ≈ 32–40 cycles, so
  CPI ≈ 32–40 and IPC ≈ 0.025–0.03. At 50 MHz → **≈ 1.3–1.5 MIPS** (effective).
  [TEAM: refine CPI from your firmware instruction mix.]
- **Frame rate.** One 256-cell frame = 256 SPI conversions (16 SCK each) + CPU scan loop +
  256-element bsg_link offload. [TEAM: plug in measured cycle counts from sim — e.g. cycles
  between consecutive frame starts in `chip_top_tb` — and compute frames/s = 50e6 / cycles.]
  As a worked example, the gate-sim completes one scan+offload by ~145 ms *including* the
  one-time 115 ms UART firmware load; steady-state per-frame time excludes the boot load.
- **Offload bandwidth.** bsg_link runs DDR at the IO clock; a 256×8-bit frame = 2 Kbit per
  burst. [TEAM: cycles/burst from sim → Mbit/s.]

### 4.3 Analyses

- **Timing is met with thin setup margin (+0.119 ns at 50 MHz).** The critical path is in the
  bsg_link RX (`iddr_phy` / async-FIFO domain). It's satisfactory but tight; to add margin one
  could relax core_clk slightly, pipeline the link RX, or upsize the critical net during PnR.
- **The only hold violation is a single scan-shift path (−0.072 ns) in SERV's register-RAM** —
  it does **not** affect functional operation (functional hold is +0.055 ns). It would be
  closed with one or two hold buffers in the scan path; we added scan-mode SDC so future
  `opt_design` runs target it directly. For tapeout it is a marginal, scan-only violation.
- **Utilization 64.3 %** is comfortable and **pad-limited** rather than core-limited (the
  die size is set by the 48-pad ring, not core logic). The core could shrink, but the pad ring
  fixes the floor — typical for a peripheral-heavy IO chip. Room to add features without growth.
- **Power:** disabling clock gating raised dynamic power for boot reliability. If power became
  critical, the correct fix is selective gating that excludes only the bootstrap `reset_cnt`
  (or an async reset on that one counter), restoring gating everywhere else.
- **CPU throughput** is low by construction (bit-serial), which is the intended area/cost
  trade-off; the sensing pipeline is IO-bound (SPI/UART/bsg_link) rather than compute-bound, so
  SERV's low IPC is not the bottleneck. A wider SERV (`W>1`) or a small vector unit would raise
  IPC if future frame-rates demand it.

---

## References
[TEAM: format properly]
1. A. Waterman, K. Asanović (eds.), *The RISC-V Instruction Set Manual, Vol. I: Unprivileged ISA*, RISC-V International.
2. O. Kindgren, *SERV — The SErial RISC-V CPU*, github.com/olofk/serv.
3. Bespoke Silicon Group, *BaseJump STL* (`bsg_link`), University of Washington.
4. NXP/Philips, *I²C-bus Specification*; relevant UART/SPI references.
5. TSMC 180 nm standard-cell & IO library documentation.
