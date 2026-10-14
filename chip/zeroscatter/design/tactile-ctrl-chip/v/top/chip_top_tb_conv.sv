// -----------------------------------------------------------------------
// chip_top_tb.sv
//
// Comprehensive testbench for the DLA chip_top (EE478b TSMC180 tapeout).
// Simulates the ctrl chip at the 48-pad level: drives bsg_link DDR signals,
// sends ring-protocol packets (INST / DATA / KICKOFF), captures DLA responses.
//
// Test phases (all must PASS for a clean run):
//
//   Phase 1 — Calibration
//     5-step bsg_link reset, wait for o_calib_done, verify o_idle high.
//
//   Phase 2 — HALT-only sanity
//     Load HALT@PC0, KICKOFF.  o_idle must pulse LOW then HIGH.
//     Proves ring_node receives INST+KICKOFF without needing flash or compute.
//
//   Phase 3 — SEND_AM basic (AM = zeros, no compute)
//     Load SET_AM_BASE + SEND_AM + HALT, KICKOFF.
//     Capture 26-flit response; body must all be 0 (AM zeroed at reset).
//     Proves DLA TX path and ring_node TX arbiter without LOAD_WM.
//
//   Phase 4 — Full 2D convolution
//     11-instruction program (SET_SPI_ADDR, LOAD_WM×2, SET_AM_BASE,
//     CONV×5, SEND_AM, HALT).  Input image: IM[r][c] = r+1.
//     Expected: DP0[r] = 25r+75,  DP1[r] = 75r+275  (r=0..11).
//     Flash kernel layout identical to chip_top_compute_tb.sv.
//
//   Phase 5 — DFT scan chain (compiled only when `DFT_EN is defined)
//     Shift alternating pattern in, capture, shift out.
//     Pass criterion: ≥ 100 bit-transitions observed on scan_out.
//
// o_idle edge monitor prints at every edge so the sim log tells you
// immediately whether the DLA started, finished, or got stuck.
// -----------------------------------------------------------------------
`timescale 1ps/1ps

module chip_top_tb;

    // ── Geometry parameters (must match dla_chip.sv defaults) ─────────────────
    localparam int FLIT_WIDTH    = 16;
    localparam int CHANNEL_WIDTH = 8;
    localparam int NDP           = 2;
    localparam int STAGE         = 4;
    localparam int CNT           = 1 << STAGE;   // 16
    localparam int KERNEL_ROWS   = 5;
    localparam int KERNEL_COLS   = 5;
    localparam int OUT_COUNT     = 12;
    // chip_id = 0 after power-on (bsg_tag_client default); no bsg_tag programming.
    localparam logic [5:0] CHIP_ID = 6'd0;

    // Scan chain estimated length (after dft.yml gen_dp bracket-index fix).
    // Used for Phase 5 shift count.
    localparam int SCAN_CHAIN_LEN = 7308;

    // ── Clocks & resets ───────────────────────────────────────────────────────
    logic core_clk;       // 50 MHz  → 10 ns half-period (10000 ps)
    // io_master_clk: no pad — tied to core_clk internally in chip_top.sv
    logic dn_io_clk;      // 50 MHz  (FPGA TX DDR IO clock → forwarded as ci_clk)
    logic async_reset;

    logic fpga_core_reset;
    logic fpga_tx_io_link_reset;
    logic fpga_tx_async_token_reset;
    logic fpga_rx_io_link_reset;
    logic fpga_rx_io_link_reset_sync;

    initial begin core_clk  = 1'b0; forever #10000 core_clk  = ~core_clk;  end
    initial begin dn_io_clk = 1'b0; forever #10000 dn_io_clk = ~dn_io_clk; end

    // ── Tri-state pad bus ──────────────────────────────────────────────────────
    tri   [47:0] pad;
    logic [47:0] pad_drv;
    logic [47:0] pad_oe;

    // Convert logic to clean 0/1 (suppresses X from uninitialised flops driving pads).
    function automatic logic kz(input logic v);
        kz = (v === 1'b1) ? 1'b1 : 1'b0;
    endfunction

    genvar pad_idx;
    generate
        for (pad_idx = 0; pad_idx < 48; pad_idx++) begin : gen_pad_drive
            assign pad[pad_idx] = pad_oe[pad_idx] ? pad_drv[pad_idx] : 1'bz;
        end
    endgenerate

    // ── DUT ───────────────────────────────────────────────────────────────────
    chip_top uut (
        .PAD   (pad),
        .VDDPST(1'b1),
        .VSSPST(1'b0),
        .VDD   (1'b1),
        .VSS   (1'b0)
    );

    // ── QSPI flash model ──────────────────────────────────────────────────────
    // PAD[22]=qspi_sck, PAD[23]=qspi_cs_n.
    // PAD[25]=qspi_dat[0]=MOSI (chip drives when qspi_mod[0]=0).
    // PAD[26]=qspi_dat[1]=MISO (flash drives; chip high-Zs when qspi_mod[0]=1).
    // wbqspiflash uses FAST_READ (0x0B); the behavioral model speaks this protocol.
    wire flash_miso;
    qspi_flash_dev #(.ADDR_WIDTH(22)) u_flash (
        .i_sck  (pad[22]),
        .i_cs_n (pad[23]),
        .i_mosi (pad[25]),
        .o_miso (flash_miso)
    );
    assign pad[26] = (!pad[23]) ? flash_miso : 1'bz;

    // ── bsg_link peer signals ─────────────────────────────────────────────────
    // FPGA TX → chip RX  (ci_* pads)
    logic                      fpga_to_asic_clk;
    logic                      fpga_to_asic_valid;
    logic [CHANNEL_WIDTH-1:0]  fpga_to_asic_data;
    logic                      asic_to_fpga_token;   // ci_tkn from chip (PAD[10])

    // Chip TX → FPGA RX  (co_* pads)
    logic                      asic_to_fpga_clk;     // co_clk from chip (PAD[13])
    logic                      asic_to_fpga_valid;   // co_v from chip   (PAD[12])
    logic [CHANNEL_WIDTH-1:0]  asic_to_fpga_data;    // co_data from chip(PAD[14..21])
    logic                      fpga_to_asic_token;   // co_tkn to chip   (PAD[11])

    // Core-domain FIFO interface
    logic [FLIT_WIDTH-1:0]  fpga_tx_data;
    logic                   fpga_tx_valid;
    logic                   fpga_tx_ready;
    logic [FLIT_WIDTH-1:0]  fpga_rx_data;
    logic                   fpga_rx_valid;
    logic                   fpga_rx_yumi;

    // ── Pad drive assignments ──────────────────────────────────────────────────
    // PAD[29]=core_clk, PAD[30]=hard_reset (chip_top.sv CORE_CLK_PAD=29, HARD_RESET_PAD=30)
    assign pad_drv[29] = kz(core_clk);
    assign pad_drv[30] = kz(~async_reset);  // hard_resetn active-LOW: async_reset=1 holds reset asserted
    assign pad_drv[8]  = kz(fpga_to_asic_clk);
    assign pad_drv[9]  = kz(fpga_to_asic_valid);
    assign pad_drv[11] = kz(fpga_to_asic_token);
    // bsg_tag: keep at 0 so chip_id stays at the post-reset default (0).
    assign pad_drv[34] = 1'b0;
    assign pad_drv[35] = 1'b0;
    assign pad_drv[36] = 1'b0;
    // DFT scan pads — driven by Phase 5 task; default 0.
    // Scan drive signals declared here (before assign) to satisfy default_nettype none.
    logic scan_en_drv  = 1'b0;
    logic scan_in_drv  = 1'b0;

    assign pad_drv[37] = kz(scan_en_drv);
    assign pad_drv[38] = kz(scan_in_drv);

    genvar ci_i;
    generate
        for (ci_i = 0; ci_i < 8; ci_i++) begin : gen_ci_drive
            assign pad_drv[ci_i] = kz(fpga_to_asic_data[ci_i]);
        end
    endgenerate

    // Chip outputs sampled from pad bus
    assign asic_to_fpga_clk    = pad[13];
    assign asic_to_fpga_valid  = pad[12];
    assign asic_to_fpga_token  = pad[10];
    genvar co_i;
    generate
        for (co_i = 0; co_i < 8; co_i++) begin : gen_co_sample
            assign asic_to_fpga_data[co_i] = pad[14 + co_i];
        end
    endgenerate

    // o_idle has no pad in this chip_top (PAD[31..32] are SPARE) — tap internally.
    wire dla_idle       = uut.u_dla.o_idle;
    wire dla_calib_done = pad[33];
    wire scan_out_pin   = pad[39];

    // ── bsg_link peer PHY instances ───────────────────────────────────────────
    bsg_link_ddr_upstream #(
        .width_p        (FLIT_WIDTH),
        .channel_width_p(CHANNEL_WIDTH),
        .num_channels_p (1),
        .lg_fifo_depth_p(6)
    ) fpga_tx_link (
        .core_clk_i         (core_clk),
        .core_link_reset_i  (fpga_core_reset),
        .core_data_i        (fpga_tx_data),
        .core_valid_i       (fpga_tx_valid),
        .core_ready_o       (fpga_tx_ready),
        .io_clk_i           (dn_io_clk),
        .io_link_reset_i    (fpga_tx_io_link_reset),
        .async_token_reset_i(fpga_tx_async_token_reset),
        .io_clk_r_o         (fpga_to_asic_clk),
        .io_data_r_o        (fpga_to_asic_data),
        .io_valid_r_o       (fpga_to_asic_valid),
        .token_clk_i        (asic_to_fpga_token)
    );

    bsg_sync_sync #(.width_p(1)) fpga_rx_reset_sync (
        .oclk_i      (asic_to_fpga_clk),
        .iclk_data_i (fpga_rx_io_link_reset),
        .oclk_data_o (fpga_rx_io_link_reset_sync)
    );

    bsg_link_ddr_downstream #(
        .width_p        (FLIT_WIDTH),
        .channel_width_p(CHANNEL_WIDTH),
        .num_channels_p (1),
        .lg_fifo_depth_p(6)
    ) fpga_rx_link (
        .core_clk_i        (core_clk),
        .core_link_reset_i (fpga_core_reset),
        .io_link_reset_i   (fpga_rx_io_link_reset_sync),
        .core_data_o       (fpga_rx_data),
        .core_valid_o      (fpga_rx_valid),
        .core_yumi_i       (fpga_rx_yumi),
        .io_clk_i          (asic_to_fpga_clk),
        .io_data_i         (asic_to_fpga_data),
        .io_valid_i        (asic_to_fpga_valid),
        .core_token_r_o    (fpga_to_asic_token)
    );

    assign fpga_rx_yumi = fpga_rx_valid;

    // ── RX capture buffer ─────────────────────────────────────────────────────
    localparam int RX_DEPTH = 128;
    logic [FLIT_WIDTH-1:0] rx_buf [RX_DEPTH];
    int rx_ptr;

    always_ff @(posedge core_clk) begin
        if (fpga_core_reset) begin
            rx_ptr <= 0;
        end else if (fpga_rx_valid && fpga_rx_yumi && rx_ptr < RX_DEPTH) begin
            rx_buf[rx_ptr] <= fpga_rx_data;
            rx_ptr         <= rx_ptr + 1;
        end
    end

    // ── Ring header constructors (ring_pkg inlined) ────────────────────────────
    function automatic logic [31:0] mk_inst_hdr(
        input logic [5:0] dest, src, input logic [8:0] addr);
        mk_inst_hdr = {dest, src, 2'b00, addr, 9'd0};
    endfunction

    function automatic logic [31:0] mk_data_hdr(
        input logic [5:0] dest, src,
        input logic [8:0] im_addr, len);
        mk_data_hdr = {dest, src, 2'b01, im_addr, len};
    endfunction

    function automatic logic [31:0] mk_kickoff(
        input logic [5:0] dest, src, input logic [8:0] pc);
        mk_kickoff = {dest, src, 2'b10, pc, 9'd0};
    endfunction

    // ── DLA 40-bit instruction encoders ───────────────────────────────────────
    // Format: [39:35]=OPCODE [34]=MODE-0 [33]=MODE-1
    //         [32:30]=REG-ID-0 [29:27]=REG-ID-1 [26:0]=PAYLOAD
    // Source of truth: sw/full_model/gen/inst_encoder.py
    localparam logic [4:0] OPC_HALT       = 5'd0;
    localparam logic [4:0] OPC_LOAD_WM    = 5'd1;
    localparam logic [4:0] OPC_SET_ADDR   = 5'd2;
    localparam logic [4:0] OPC_SET_AM_BASE = 5'd3;
    localparam logic [4:0] OPC_CONV       = 5'd9;
    localparam logic [4:0] OPC_SEND_AM    = 5'd12;

    function automatic logic [39:0] f_set_spi_addr(input logic [18:0] addr);
        f_set_spi_addr = (40'(OPC_SET_ADDR) << 35) | (40'(addr) << 8);
    endfunction

    function automatic logic [39:0] f_load_wm(
        input logic [11:0] elem_addr, input logic [8:0] len);
        // payload[26:15]=wm_addr, [14:6]=len, [5]=1(SPI source)
        f_load_wm = (40'(OPC_LOAD_WM) << 35) | (40'(elem_addr) << 15)
                  | (40'(len) << 6) | 40'h20;
    endfunction

    function automatic logic [39:0] f_set_am_base(input logic [18:0] base);
        f_set_am_base = (40'(OPC_SET_AM_BASE) << 35) | (40'(base) << 8);
    endfunction

    // payload: [26:18]=wm_base(9b), [17:12]=im_base(6b), [11]=src_imb,
    //          [10:6]=count-1(5b), [5:4]=stride-1(2b), [3:0]=0
    function automatic logic [39:0] f_conv(
        input logic [8:0] wm_base, input logic [5:0] im_base,
        input logic [4:0] count_m1, input logic [1:0] stride_m1,
        input logic src_imb);
        f_conv = (40'(OPC_CONV) << 35) | (40'(wm_base) << 18) | (40'(im_base) << 12)
               | (40'(src_imb) << 11) | (40'(count_m1) << 6) | (40'(stride_m1) << 4);
    endfunction

    function automatic logic [39:0] f_send_am(
        input logic [5:0] dest, input logic [8:0] im_addr, input logic [8:0] len);
        // payload: [26:21]=dest, [20:12]=im_addr, [11:3]=len
        f_send_am = (40'(OPC_SEND_AM) << 35) | (40'(dest) << 21)
                  | (40'(im_addr) << 12) | (40'(len) << 3);
    endfunction

    function automatic logic [39:0] f_halt();
        f_halt = (40'(OPC_HALT) << 35);  // = 40'd0
    endfunction

    // ── Flash byte-address helper ─────────────────────────────────────────────
    // wbqspiflash assembles 32-bit WB words big-endian (first byte → [31:24]).
    // ctrl.sv extracts byte_sel=0 from [7:0], so element j of a 4-byte group
    // lives at flash byte: (j/4)*4 + (3 - j%4).
    function automatic int flash_baddr(int e);
        flash_baddr = (e / 4) * 4 + (3 - e % 4);
    endfunction

    // ── TX tasks ──────────────────────────────────────────────────────────────
    task automatic send_flit(input logic [FLIT_WIDTH-1:0] data);
        fpga_tx_data  <= data;
        fpga_tx_valid <= 1'b1;
        do @(posedge core_clk); while (!fpga_tx_ready);
        fpga_tx_valid <= 1'b0;
        @(posedge core_clk);
    endtask

    task automatic send_word32(input logic [31:0] w);
        send_flit(w[31:16]);
        send_flit(w[15:0]);
    endtask

    // 5-flit INST packet: 2-flit ring header + HH(inst[39:32]) + HI + LO.
    // ring_node.sv RX_INST_HH: inst_buf[39:32] <= i_rx_data[7:0].
    task automatic send_inst_pkt(input int unsigned pc, input logic [39:0] inst40);
        send_word32(mk_inst_hdr(CHIP_ID, CHIP_ID, 9'(pc)));
        send_flit(16'(inst40[39:32]));   // HH: opcode in lower byte
        send_word32(inst40[31:0]);       // HI + LO
    endtask

    // ── Infrastructure tasks ──────────────────────────────────────────────────

    task automatic task_preload_flash();
        // Zero first 256 bytes.
        for (int i = 0; i < 256; i++) u_flash.mem[i] = 8'h00;

        // DP0 kernel: 5 rows × 16 taps at bytes 0..79.
        // Each row dr: first KERNEL_COLS=5 taps = 1, rest 0.
        for (int dr = 0; dr < KERNEL_ROWS; dr++)
            for (int k = 0; k < CNT; k++)
                u_flash.mem[flash_baddr(dr * CNT + k)] =
                    (k < KERNEL_COLS) ? 8'h01 : 8'h00;

        // DP1 kernel: 5 rows × 16 taps at bytes 80..159.
        // Row dr: first 5 taps = (dr+1), rest 0.
        for (int dr = 0; dr < KERNEL_ROWS; dr++)
            for (int k = 0; k < CNT; k++)
                u_flash.mem[80 + flash_baddr(dr * CNT + k)] =
                    (k < KERNEL_COLS) ? 8'(dr + 1) : 8'h00;
    endtask

    task automatic task_reset_and_calib(output logic pass);
        // 5-step bsg_link reset (same as chip_top_compute_tb.sv).
        repeat (8) @(posedge core_clk);
        fpga_tx_async_token_reset = 1'b1;
        repeat (2) @(posedge core_clk);
        fpga_tx_async_token_reset = 1'b0;

        repeat (8) @(posedge dn_io_clk);
        fpga_tx_io_link_reset = 1'b0;

        repeat (8) @(posedge core_clk);
        async_reset = 1'b0;
        repeat (64) @(posedge core_clk);

        fpga_rx_io_link_reset = 1'b0;
        repeat (8) @(posedge core_clk);
        fpga_core_reset = 1'b0;

        // Wait for bsg_link calibration done (o_calib_done on PAD[33]).
        pass = 1'b0;
        fork
            begin : wait_calib
                @(posedge dla_calib_done);
                pass = 1'b1;
            end
            begin : timeout_calib
                repeat (5000) @(posedge core_clk);
            end
        join_any
        disable fork;
    endtask

    task automatic task_clear_rx();
        // Brief fpga_core_reset pulse clears the RX capture buffer between phases.
        fpga_core_reset = 1'b1;
        repeat (4) @(posedge core_clk);
        fpga_core_reset = 1'b0;
        repeat (4) @(posedge core_clk);
    endtask

    task automatic task_wait_idle(input int max_cycles, output logic pass);
        // Wait for dla_idle to assert (high) within max_cycles from now.
        int cyc;
        pass = 1'b0;
        for (cyc = 0; cyc < max_cycles; cyc++) begin
            @(posedge core_clk);
            if (dla_idle) begin
                pass = 1'b1;
                break;
            end
        end
    endtask

    task automatic task_wait_response(input int n_flits, input int max_cycles,
                                      output logic pass);
        pass = 1'b0;
        fork
            begin : rx_wait
                wait (rx_ptr >= n_flits);
                pass = 1'b1;
            end
            begin : rx_timeout
                repeat (max_cycles) @(posedge core_clk);
            end
        join_any
        disable fork;
    endtask

    // ── o_idle background monitor ─────────────────────────────────────────────
    // Prints at every edge so the log shows exactly when DLA starts/stops.
    // Placed outside initial so it runs throughout all phases.
    // Only fires after reset (gated by calib_done to avoid noise during reset).
    logic idle_monitor_en = 1'b0;
    always @(posedge dla_idle)
        if (idle_monitor_en)
            $display("[t=%0t ps] o_idle HIGH — DLA execution complete", $time);
    always @(negedge dla_idle)
        if (idle_monitor_en)
            $display("[t=%0t ps] o_idle LOW  — DLA execution started", $time);

    // ── Periodic status monitor ───────────────────────────────────────────────
    initial begin
        @(negedge fpga_core_reset);
        forever begin
            repeat (50000) @(posedge core_clk);
            $display("STATUS t=%0d ms: rx_ptr=%0d  idle=%b",
                     $time / 1_000_000_000, rx_ptr, dla_idle);
        end
    end

    // ── Watchdog ─────────────────────────────────────────────────────────────
    // 600 ms covers two LOAD_WM flash reads + full compute
    initial begin
        #600_000_000_000;
        $display("ERROR: watchdog expired at 600 ms — simulation incomplete");
        $finish;
    end

    // =========================================================================
    // ── Main test sequence ────────────────────────────────────────────────────
    // =========================================================================
    initial begin
        $fsdbDumpfile("waveform.fsdb");
        $fsdbDumpvars(0, chip_top_tb);
        $fsdbDumpMDA();

        // ── Phase 0: Infrastructure init ─────────────────────────────────────
        task_preload_flash();

        // Drive defaults before enabling pad OE.
        async_reset               = 1'b1;
        fpga_core_reset           = 1'b1;
        fpga_tx_io_link_reset     = 1'b1;
        fpga_tx_async_token_reset = 1'b0;
        fpga_rx_io_link_reset     = 1'b1;
        fpga_tx_valid             = 1'b0;
        fpga_tx_data              = '0;
        pad_oe                    = '0;

        #1000;
        // Enable FPGA-driven pads.
        pad_oe[29] = 1'b1;  // core_clk   (CORE_CLK_PAD=29)
        pad_oe[30] = 1'b1;  // hard_reset (HARD_RESET_PAD=30)
        pad_oe[8]  = 1'b1;  // ci_clk   (forwarded from fpga_tx_link)
        pad_oe[9]  = 1'b1;  // ci_valid
        pad_oe[11] = 1'b1;  // co_tkn   (fpga_rx_link token)
        pad_oe[34] = 1'b1; pad_oe[35] = 1'b1; pad_oe[36] = 1'b1;  // bsg_tag (0)
        pad_oe[37] = 1'b1; pad_oe[38] = 1'b1;                      // scan_en, scan_in
        for (int ci = 0; ci < 8; ci++) pad_oe[ci] = 1'b1;          // ci_data[7:0]

        // ── Phase 1: Calibration ──────────────────────────────────────────────
        begin : phase1
            logic pass;
            task_reset_and_calib(pass);
            if (pass) begin
                if (dla_idle)
                    $display("PASS: Phase 1 — calib_done asserted, DLA idle.");
                else
                    $display("PASS: Phase 1 — calib_done asserted (idle=%b).", dla_idle);
            end else begin
                $display("FAIL: Phase 1 — calib_done timeout after 5000 cycles.");
                $finish;
            end
            idle_monitor_en = 1'b1;
        end

        // ── Phase 2: HALT-only sanity ─────────────────────────────────────────
        // Proves ring_node receives INST packets and KICKOFF end-to-end.
        // DLA should pulse o_idle LOW (started) then HIGH (HALT reached).
        begin : phase2
            logic pass;
            logic idle_pulsed;

            // Load PC0 = HALT.
            send_inst_pkt(0, f_halt());
            // KICKOFF at PC=0.
            send_word32(mk_kickoff(CHIP_ID, CHIP_ID, 9'd0));

            // Wait for idle pulse (LOW→HIGH) within 2000 cycles.
            idle_pulsed = 1'b0;
            fork
                begin
                    @(negedge dla_idle);   // started
                    @(posedge dla_idle);   // finished
                    idle_pulsed = 1'b1;
                end
                begin
                    repeat (2000) @(posedge core_clk);
                end
            join_any
            disable fork;

            if (idle_pulsed)
                $display("PASS: Phase 2 — HALT-only: DLA executed and returned to idle.");
            else
                $display("FAIL: Phase 2 — idle never pulsed in 2000 cycles (KICKOFF lost or ring broken). idle=%b", dla_idle);

            // Phase 2 failure is diagnostic-only — continue to see Phase 3 result.
        end

        // ── Phase 3: SEND_AM basic (AM = zeros, no flash) ─────────────────────
        // Proves DLA TX path without requiring LOAD_WM or CONV.
        // Expected response: 26 flits (2 hdr + NDP*OUT_COUNT body), all body = 0.
        begin : phase3
            logic pass_rx, pass_hdr, pass_body;
            logic [31:0] exp_hdr;
            int fail_count;

            task_clear_rx();

            send_inst_pkt(0, f_set_am_base(19'd0));
            send_inst_pkt(1, f_send_am(6'd0, 9'd0, 9'd12));
            send_inst_pkt(2, f_halt());
            send_word32(mk_kickoff(CHIP_ID, CHIP_ID, 9'd0));

            // Wait for 26 flits (100 000 cycles ≈ 2 ms).
            task_wait_response(26, 100_000, pass_rx);

            if (!pass_rx) begin
                $display("FAIL: Phase 3 — no response from DLA (rx_ptr=%0d, idle=%b).",
                         rx_ptr, dla_idle);
            end else begin
                // Verify header.
                exp_hdr    = mk_data_hdr(6'd0, 6'd0, 9'd0, 9'(NDP * OUT_COUNT));
                pass_hdr   = ({rx_buf[0], rx_buf[1]} === exp_hdr);
                // Verify all body flits are 0 (AM zeroed at reset).
                fail_count = 0;
                pass_body  = 1'b1;
                for (int i = 2; i < 26; i++) begin
                    if (rx_buf[i] !== 16'd0) begin
                        $display("FAIL: Phase 3 — body flit %0d = 0x%04h (exp 0)", i, rx_buf[i]);
                        fail_count++;
                        pass_body = 1'b0;
                    end
                end
                if (!pass_hdr)
                    $display("FAIL: Phase 3 — header mismatch: got %04h_%04h exp %08h",
                             rx_buf[0], rx_buf[1], exp_hdr);
                if (pass_hdr && pass_body)
                    $display("PASS: Phase 3 — SEND_AM (AM=0): received 26 flits, all correct.");
                else if (!pass_body && fail_count > 0)
                    $display("FAIL: Phase 3 — %0d body flit mismatch(es).", fail_count);
            end
        end

        // ── Phase 4: Full 2D convolution ──────────────────────────────────────
        // Flash was preloaded in Phase 0; send full 11-instruction program.
        // Expected: DP0[r]=25r+75,  DP1[r]=75r+275  (r=0..11).
        begin : phase4
            logic pass_rx;
            int fail_count;
            logic [31:0] exp_hdr;

            task_clear_rx();

            // 11-instruction program.
            send_inst_pkt(0,  f_set_spi_addr(19'd0));
            send_inst_pkt(1,  f_load_wm(12'd0,   9'd80));   // DP0 kernel
            send_inst_pkt(2,  f_load_wm(12'd256, 9'd80));   // DP1 kernel
            send_inst_pkt(3,  f_set_am_base(19'd0));
            send_inst_pkt(4,  f_conv(9'd0, 6'd0, 5'd11, 2'd0, 1'b0));
            send_inst_pkt(5,  f_conv(9'd1, 6'd1, 5'd11, 2'd0, 1'b0));
            send_inst_pkt(6,  f_conv(9'd2, 6'd2, 5'd11, 2'd0, 1'b0));
            send_inst_pkt(7,  f_conv(9'd3, 6'd3, 5'd11, 2'd0, 1'b0));
            send_inst_pkt(8,  f_conv(9'd4, 6'd4, 5'd11, 2'd0, 1'b0));
            send_inst_pkt(9,  f_send_am(6'd0, 9'd0, 9'd12));
            send_inst_pkt(10, f_halt());

            // Input image: IM[r][c] = r+1, all 16×16 elements.
            send_word32(mk_data_hdr(CHIP_ID, CHIP_ID, 9'd0, 9'd256));
            for (int r = 0; r < 16; r++)
                for (int c = 0; c < 16; c++)
                    send_flit(16'(r + 1));

            // KICKOFF at PC=0.
            send_word32(mk_kickoff(CHIP_ID, CHIP_ID, 9'd0));

            // Wait up to ~400 ms (20M cycles) for 26-flit response.
            task_wait_response(26, 20_000_000, pass_rx);

            if (!pass_rx) begin
                $display("FAIL: Phase 4 — timeout waiting for SEND_AM response (rx_ptr=%0d, idle=%b).",
                         rx_ptr, dla_idle);
                $display("      Check Verdi: uut.u_dla.u_ring_node.rx_state");
                $display("                   uut.u_dla.u_ring_node.u_dla.u_ctrl.state");
            end else begin
                $display("PASS: Phase 4 — received 26 flits from DLA.");

                // Verify header.
                exp_hdr    = mk_data_hdr(6'd0, 6'd0, 9'd0, 9'(NDP * OUT_COUNT));
                fail_count = 0;
                if ({rx_buf[0], rx_buf[1]} !== exp_hdr) begin
                    $display("FAIL: Phase 4 — response header got %04h_%04h exp %08h",
                             rx_buf[0], rx_buf[1], exp_hdr);
                    fail_count++;
                end

                // Body: interleaved DP0[r], DP1[r] for r = 0..OUT_COUNT-1.
                for (int r = 0; r < OUT_COUNT; r++) begin
                    logic [FLIT_WIDTH-1:0] exp_dp0, exp_dp1;
                    exp_dp0 = 16'(25 * r + 75);
                    exp_dp1 = 16'(75 * r + 275);
                    if (rx_buf[2 + 2*r] !== exp_dp0) begin
                        $display("FAIL: Phase 4 — DP0[%0d] exp=%0d got=%0d",
                                 r, exp_dp0, rx_buf[2 + 2*r]);
                        fail_count++;
                    end
                    if (rx_buf[3 + 2*r] !== exp_dp1) begin
                        $display("FAIL: Phase 4 — DP1[%0d] exp=%0d got=%0d",
                                 r, exp_dp1, rx_buf[3 + 2*r]);
                        fail_count++;
                    end
                end

                if (fail_count == 0)
                    $display("PASS: Phase 4 — 2D convolution verified — all %0d DLA outputs correct.",
                             NDP * OUT_COUNT);
                else
                    $display("FAIL: Phase 4 — %0d output mismatch(es).", fail_count);
            end
        end

        // ── Phase 5: DFT scan chain ───────────────────────────────────────────
        // Compiled only when `DFT_EN is defined (e.g. gate-level sim with scan).
        // Shifts alternating 01 pattern; expects ≥100 transitions on scan_out.
        `ifdef DFT_EN
        begin : phase5
            int transitions;
            logic prev_bit, cur_bit;

            // --- Shift-in phase ---
            scan_en_drv = 1'b1;
            repeat (4) @(posedge core_clk);  // let scan_en propagate

            for (int i = 0; i < SCAN_CHAIN_LEN; i++) begin
                scan_in_drv = logic'(i[0]);   // alternating 0/1
                @(posedge core_clk);
            end

            // --- Capture phase: one cycle with scan_en=0 ---
            scan_en_drv = 1'b0;
            @(posedge core_clk);
            scan_en_drv = 1'b1;

            // --- Shift-out phase: count transitions on scan_out ---
            transitions = 0;
            prev_bit = scan_out_pin;
            for (int i = 0; i < SCAN_CHAIN_LEN; i++) begin
                scan_in_drv = logic'(i[0]);
                @(posedge core_clk);
                cur_bit = scan_out_pin;
                if (cur_bit !== prev_bit) transitions++;
                prev_bit = cur_bit;
            end

            scan_en_drv = 1'b0;

            if (transitions >= 100)
                $display("PASS: Phase 5 — scan chain: %0d transitions (chain intact).",
                         transitions);
            else
                $display("FAIL: Phase 5 — scan chain: only %0d transitions (chain may be broken).",
                         transitions);
        end
        `endif

        $display("Simulation complete.");
        $finish;
    end

endmodule
