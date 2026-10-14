// =============================================================================
// ctrl_top.v — Tactile Glove SoC, single SERV core
//
// Clock : 50 MHz (CLK_IN). All CLK_HZ parameters derive from this.
// Reset : nRESET active-low async assert, sync release (two-flop).
//
// Reset domains:
//   perip_rst_n  = rst_n_sync & i2c_done & iram_ack_done
//                  → peripherals (UART, pkt_framer, cnn_buf)
//                  → live only AFTER loader completes
//   serv_rst_n   = perip_rst_n
//                  → SERV core only
//
// Memory:
//   instr_ram : 256 words × 32 bit (1 KB)  — addr range 0x0000–0x03FF
//   data_ram  : 64 words × 32 bit (256 B)  — addr range 0x0000–0x00FF (dbus)
//
// Boot sequence:
//   1. nRESET released → rst_n_sync rises one cycle later
//   2. i2c_init runs, programs MCP4018, asserts i2c_done
//   3. firmware_loader receives firmware over raw UART protocol
//      (AA 55 [addr][data]... FFFFFFFF [dummy], replies 0x06 ACK)
//   4. Loader asserts iram_ack_done
//   5. perip_rst_n rises → UART/pkt_framer/cnn_buf come alive
//   6. serv_rst_n rises → SERV starts executing firmware at PC=0
//
// UART output flow:
//   CNN flits arrive over BSG → cnn_result_buf parses and asserts ready
//   → pkt_framer wraps 12 flits as a 0xB0 packet → uart_peripheral → host
//   → pkt_framer pulses cnn_buf_clear → buffer accepts next CNN result
//
// No runtime command protocol. To reload firmware, chip must be reset.
//
// (bsg_tag retired — chip_id / tx_pack_8bit / rx_pack_8bit are now pin-
//  strapped at chip_top via direct PADs; 0xB000 is unmapped.)
//
// BSG_LINK MMIO map:
//   0xC000  BSG_TX          [W]   write 16-bit flit (firmware direct)
//   0xC004  BSG_TX_ST       [R]   bit[0]=NOT ready (FIFO full)
//   0xC008  BSG_RX          [R]   read 16-bit flit (auto-pop)
//   0xC00C  BSG_RX_ST       [R]   bit[0]=flit available
//   0xC010  BSG_LINK_CALIB  [R]   reserved in ctrl_top; hard reset is in chip_top
//   0xC030  BSG_UP_CFG      [RW]    bit[0]=pack_8bit, bit[1]=full_stream_en
//   0xC034  BSG_UP_GO       [W]     write 1 → start DMA send
//   0xC038  BSG_UP_ST       [R/W1C] bit[0]=busy  bit[1]=done  bit[2]=pkt_ack
//   0xC03C  BSG_UP_DST      [RW]    bits[5:0]=dest_chip_id
//   0xC040  BSG_UP_INTVL    [RW]    timer interval in clk cycles (0=manual mode)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module ctrl_top
(
    input  wire        CLK_IN,
    input  wire        nRESET,

    // BSG_LINK flit interface (core-side, driven by bsg_link_wrapper in chip_top)
    input  wire [15:0] bsg_rx_data_i,
    input  wire        bsg_rx_valid_i,
    output wire        bsg_rx_yumi_o,

    output wire [15:0] bsg_tx_data_o,
    output wire        bsg_tx_valid_o,
    input  wire        bsg_tx_ready_i,

    // UART
    output wire        uart_tx_o,
    input  wire        uart_rx_i,

    // I2C
    output wire        i2c_sda_out,
    output wire        i2c_scl_out,
    output wire        i2c_sda_oen,
    output wire        i2c_sda_ie ,
    output wire        i2c_scl_oen,
    output wire        i2c_scl_ie ,

    // SPI — AD7466 ADC
    output wire        spi_clk_o,
    input  wire        spi_miso_i,
    output wire        spi_cs_n_o,

    // Sensor MUX
    output wire [3:0]  mux_row_o,
    output wire [3:0]  mux_col_o
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam CLK_HZ           = 50_000_000;
    localparam UART_BAUD        = 115_200;
    localparam I2C_CLK_HZ       = CLK_HZ;
    localparam I2C_SCL_HZ       = 100_000;
    localparam I2C_DEV_ADDR     = 7'h2F;
    localparam I2C_WIPER_VAL    = 8'h7D;

    localparam BSG_WIDTH_P      = 16;
    localparam BSG_CH_WIDTH_P   = 8;
    localparam BSG_NUM_CH_P     = 1;
    localparam BSG_LG_FIFO_P    = 6;
    localparam BSG_LG_TOK_DEC_P = 3;

    localparam ADC_FRAME_SIZE   = 256;  // 16×16 sensor elements

    // // -------------------------------------------------------------------------
    // // Reset synchroniser
    // // -------------------------------------------------------------------------
    // reg rst_ff1, rst_n_sync;
    // always_ff @(posedge CLK_IN or negedge nRESET) begin
    //     if (!nRESET) begin rst_ff1 <= 1'b0; rst_n_sync <= 1'b0; end
    //     else         begin rst_ff1 <= 1'b1; rst_n_sync <= rst_ff1; end
    // end
    // wire rst_sync = !rst_n_sync;

    // -------------------------------------------------------------------------
    // i2c_init — one-shot boot I2C
    // -------------------------------------------------------------------------
    wire i2c_init_scl, i2c_init_sda, i2c_done;

    i2c_init #(
        .CLK_HZ    (I2C_CLK_HZ),
        .SCL_HZ    (I2C_SCL_HZ),
        .DEV_ADDR  (I2C_DEV_ADDR),
        .WIPER_VAL (I2C_WIPER_VAL)
    ) u_i2c_init (
        .clk     (CLK_IN),
        .rst     (!nRESET),
        .scl_out (i2c_init_scl),
        .sda_out (i2c_init_sda),
        .done    (i2c_done)
    );

    assign i2c_sda_out = i2c_init_sda;
    assign i2c_sda_oen = i2c_done ? 1'b1 : 1'b0;  // 0 = drive, 1 = release
    assign i2c_sda_ie  = 1'b0;  // output-only: never read SDA

    assign i2c_scl_out = i2c_init_scl;
    assign i2c_scl_oen = i2c_done ? 1'b1 : 1'b0;
    assign i2c_scl_ie  = 1'b0;

    // -------------------------------------------------------------------------
    // firmware_loader — boot-time firmware loader
    // -------------------------------------------------------------------------
    wire        iram_load_done;
    wire        iram_ack_done;
    wire        loader_uart_tx;
    wire [3:0]  loader_iram_we;
    wire [8:0]  loader_iram_waddr;
    wire [31:0] loader_iram_wdata;

    firmware_loader #(
        .CLK_HZ  (CLK_HZ),
        .BAUD_HZ (UART_BAUD)
    ) u_loader (
        .clk          (CLK_IN),
        .rst          (!nRESET),
        .i_uart_rx    (uart_rx_i),
        .o_uart_tx    (loader_uart_tx),
        .o_iram_we    (loader_iram_we),
        .o_iram_waddr (loader_iram_waddr),
        .o_iram_wdata (loader_iram_wdata),
        .o_load_done  (iram_load_done),
        .o_ack_done   (iram_ack_done)
    );

    // -------------------------------------------------------------------------
    // Split reset domains
    // -------------------------------------------------------------------------
    // Peripherals (UART, I2C, etc.) can only run AFTER:
    //  - nRESET is released AND
    //  - I2C initialization is done AND
    //  - Firmware is loaded
    // CPU(SERV) wakes up when peripherials are ready
    // Changes:
    // Split reset domains — perip_rst_n includes iram_init_done /
    // dram_init_done so SERV stays in reset until the RAMs are fully
    // walked (POR zero-init). Sim TBs that backdoor-load mem[] via
    // $readmemh must wait on those init_done signals first.
    wire        iram_init_done;
    wire        dram_init_done;
    wire rf_init_done;  // 1 once serv_rf_ram POR walk completes
    wire perip_rst_n = nRESET & i2c_done & iram_ack_done
                              & iram_init_done & dram_init_done;
    wire serv_rst_n  = perip_rst_n & rf_init_done;

    // -------------------------------------------------------------------------
    // CPU buses
    // -------------------------------------------------------------------------
     // SERV uses MINI reset (only PC clears, not the regfile / bus output
    // flops). Consequently the raw dbus outputs can carry X bits in two
    // windows:
    //   (1) Pre-reset-release: serv_rst_n=0, all SERV state is X.
    //   (2) Post-reset transient: SERV reads from an X-valued regfile entry
    //       (uninitialised x4..x29) into its address/we/wdata pipeline,
    //       producing X bits on the dbus for a cycle or three.
    //
    // Peripheral selects like cbuf_sel = dbus_cyc & (dbus_addr[15:6] ==
    // 10'h380) propagate any X in dbus_addr/we/cyc through the comparison
    // under xprop=xmerge, X-tainting the peripheral's i_wb_cyc/we, which
    // then leaks into the case statements that drive state / wr_ptr /
    // etc. flops. The whole cbuf gets X-poisoned the moment SERV touches
    // any address with an X bit.
    //
    // Gate every dbus output with serv_rst_n. When SERV is in reset
    // dbus_cyc=0, dbus_we=0, dbus_addr=0, dbus_wdata=0 — peripherals are
    // idle and X-free. When SERV is running, real outputs pass through.
    // This doesn't eliminate window (2) above (SERV is out of reset there
    // by definition), but combined with dbus_cyc gating it pins all
    // peripheral selects to 0 unless SERV explicitly drives cyc=1, and
    // SERV's MINI reset guarantees cyc is 0 (not X) as it's the only
    // mandatorily-reset flop in MINI mode.
    wire        serv_dbus_cyc;
    wire [31:0] serv_dbus_addr;
    wire [31:0] serv_dbus_wdata;
    wire        serv_dbus_we;
    wire  [3:0] serv_dbus_be;

    wire        dbus_cyc   = serv_dbus_cyc & serv_rst_n;
    wire [31:0] dbus_addr  = serv_rst_n ? serv_dbus_addr  : 32'b0;
    wire [31:0] dbus_wdata = serv_rst_n ? serv_dbus_wdata : 32'b0;
    wire        dbus_we    = serv_dbus_we    & serv_rst_n;
    wire  [3:0] dbus_be    = serv_rst_n ? serv_dbus_be    : 4'b0;

    reg  [31:0] dbus_rdata;
    reg         dbus_ack;

    wire [31:0] ibus_adr;
    wire        ibus_cyc;
    reg         ibus_ack;

    always_ff @(posedge CLK_IN) begin
        if (!nRESET)     ibus_ack <= 1'b0;
        else             ibus_ack <= ibus_cyc & ~ibus_ack;
    end

    // -------------------------------------------------------------------------
    // instr_ram — 256 x 32
    //
    // Three ports:
    //   ibus read       : SERV instruction fetch (0x0000-0x03FF)
    //   dbus read alias : SERV data load from 0x0800-0x0BFF -> .rodata
    //   dbus write      : firmware_loader (boot only)
    //
    // Write port: ONLY the loader writes IRAM. Runtime SERV cannot modify
    // IRAM (no SERV-side write path is wired in). After iram_ack_done the
    // write enable is forced to 0.
    // -------------------------------------------------------------------------
    wire [31:0] ibus_rdt;

    // dbus alias decode: addresses 0x00000800-0x00000BFF route to IRAM dbus
    // read port. dbus_addr[31:10] == 22'h2 captures exactly that window.
    wire        iram_drd_sel = dbus_cyc & ~dbus_we
                             & (dbus_addr[31:10] == 22'h2);
    wire [31:0] iram_drd_rdt;

    // Loader-only write path (no runtime SERV writes to IRAM).
    wire       iram_we_eff    = ~iram_ack_done & (|loader_iram_we);
    wire [8:0] iram_waddr_eff = loader_iram_waddr;
    wire [31:0] iram_wdata_eff = loader_iram_wdata;

    instr_ram #(
        .DEPTH (256)
    ) u_iram (
        .clk          (CLK_IN),
        .i_rstn       (nRESET),
        .i_ibus_adr   (ibus_adr[10:2]),
        .o_ibus_rdt   (ibus_rdt),
        .i_ibus_cyc   (ibus_cyc),
        .i_dbus_raddr (dbus_addr[10:2]),
        .o_dbus_rdt   (iram_drd_rdt),
        .i_dbus_rcyc  (iram_drd_sel),
        .i_dbus_we    (iram_we_eff),
        .i_dbus_waddr (iram_waddr_eff),
        .i_dbus_wdata (iram_wdata_eff),
        .o_init_done  (iram_init_done)
    );

    // IRAM dbus read port is registered (1-cycle latency).
    // Generate a delayed ack pulse the same way ibus_ack is generated, so
    // dbus_ack lines up with the cycle iram_drd_rdt is valid.
    reg iram_drd_ack;
    always_ff @(posedge CLK_IN) begin
        if (!nRESET) iram_drd_ack <= 1'b0;
        else             iram_drd_ack <= iram_drd_sel & ~iram_drd_ack;
    end

    // -------------------------------------------------------------------------
    // data_ram — 64 x 32 (covers dbus 0x0000-0x00FF only)
    // -------------------------------------------------------------------------
    wire        dram_sel = dbus_cyc & (dbus_addr[31:8] == 24'h0);
    wire  [3:0] dram_we  = {4{dbus_we & dram_sel}} & dbus_be;
    wire [31:0] dram_rdt;

    data_ram u_dram (
        .clk         (CLK_IN),
        .i_rstn      (nRESET),
        .we          (dram_we),
        .waddr       (dbus_addr[7:2]),
        .wdata       (dbus_wdata),
        .raddr       (dbus_addr[7:2]),
        .rdata       (dram_rdt),
        .o_init_done (dram_init_done)
    );

    reg dram_ack;
    always_ff @(posedge CLK_IN) begin
        if (!nRESET) dram_ack <= 1'b0;
        else             dram_ack <= dram_sel & ~dbus_we & ~dram_ack;
    end

    // -------------------------------------------------------------------------
    // scan_ctrl
    // -------------------------------------------------------------------------
    wire        scan_wb_cyc = dbus_cyc & (dbus_addr[15:5] == 11'h300); // 0x6000–0x601F (regs at 0x6000–0x6010)
    wire        scan_wb_ack;
    wire [31:0] scan_wb_rdt;
    wire        scan_spi_start;
    wire        scan_buf_we;
    wire  [7:0] scan_buf_waddr;
    wire [11:0] scan_buf_wdata;
    wire        scan_busy;
    wire        scan_frame_done;
    wire  [3:0] scan_mux_row, scan_mux_col;

 
    // For scan_ctrl
    wire        spi_busy;
    wire [11:0] spi_rx_data;   

    scan_ctrl u_scan (
        .clk            (CLK_IN),
        .rst            (!nRESET),
        .i_wb_cyc       (scan_wb_cyc),
        .i_wb_we        (dbus_we),
        .i_wb_adr       (dbus_addr),
        .i_wb_dat       (dbus_wdata),
        .o_wb_ack       (scan_wb_ack),
        .o_wb_rdt       (scan_wb_rdt),
        .o_mux_row      (scan_mux_row),
        .o_mux_col      (scan_mux_col),
        .o_spi_start    (scan_spi_start),
        .i_spi_busy     (spi_busy),        // from spi_master
        .i_spi_rx_data  (spi_rx_data),     // from spi_master
        .o_buf_we       (scan_buf_we),
        .o_buf_waddr    (scan_buf_waddr),
        .o_buf_wdata    (scan_buf_wdata),
        .o_scan_busy    (scan_busy),
        .o_frame_done   (scan_frame_done)
    );

    // -------------------------------------------------------------------------
    // spi_master
    // -------------------------------------------------------------------------

    // For Wishbone control
    wire        spi_wb_cyc = dbus_cyc & (dbus_addr[15:4] == 12'h700);
    wire        spi_wb_ack;
    wire [31:0] spi_wb_rdt;

    spi_master u_spi (
        .clk        (CLK_IN),
        .rst        (!nRESET),
        .i_wb_cyc   (spi_wb_cyc),
        .i_wb_we    (dbus_we),
        .i_wb_adr   (dbus_addr),
        .i_wb_dat   (dbus_wdata),
        .o_wb_ack   (spi_wb_ack),
        .o_wb_rdt   (spi_wb_rdt),
        .i_hw_start (scan_spi_start),
        .o_spi_cs   (spi_cs_n_o),
        .o_spi_sck  (spi_clk_o),
        .i_spi_miso (spi_miso_i),
        .o_rx_data  (spi_rx_data),
        .o_busy     (spi_busy)
    );

    // -------------------------------------------------------------------------
    // mux_ctrl
    // -------------------------------------------------------------------------
    // FIX: 0x5000 >> 3 = 13'h0A00. This must match the full 0x5000-0x5007 window
    // so MUX/GPIO writes return mux_wb_ack; otherwise SERV stalls on GPIO_OUT.
    wire        mux_wb_cyc = dbus_cyc & (dbus_addr[15:3] == 13'h0A00);
    wire        mux_wb_ack;
    wire [31:0] mux_wb_rdt;
    wire  [3:0] mux_row, mux_col;

    mux_ctrl u_mux (
        .clk        (CLK_IN),
        .rst        (!nRESET),
        .i_wb_cyc   (mux_wb_cyc),
        .i_wb_we    (dbus_we),
        .i_wb_adr   (dbus_addr),
        .i_wb_dat   (dbus_wdata),
        .o_wb_ack   (mux_wb_ack),
        .o_wb_rdt   (mux_wb_rdt),
        .o_row_bits (mux_row),
        .o_col_bits (mux_col)
    );

    // scan_ctrl wins arbitration while it's running; otherwise firmware mux_ctrl drives.
    assign mux_row_o = scan_busy ? scan_mux_row : mux_row;
    assign mux_col_o = scan_busy ? scan_mux_col : mux_col;

    // -------------------------------------------------------------------------
    // adc_8bit_buf
    //
    // External read port B: bsg_link_upstream_ctl reads ADC frames.
    // External read port A: unused (was output_ctrl's raw ADC path, now removed).
    // -------------------------------------------------------------------------
    wire        abuf_sel = dbus_cyc & (dbus_addr[15:12] == 4'h8);
    wire        abuf_ack;
    wire [31:0] abuf_rdt;
    
    wire [7:0] upctl_adc_raddr;
    wire [7:0] upctl_adc_rdata;
    wire       up_ctl_busy;


    adc_8bit_buf u_abuf (
        .clk            (CLK_IN),
        .rst            (!nRESET), //~perip_rst_n?
        .i_wb_cyc       (abuf_sel),
        .i_wb_we        (dbus_we),
        .i_wb_adr       (dbus_addr),
        .i_wb_dat       (dbus_wdata),
        .o_wb_ack       (abuf_ack),
        .o_wb_rdt       (abuf_rdt),
        .i_scan_we      (scan_buf_we),
        .i_scan_addr    (scan_buf_waddr),
        .i_scan_data    (scan_buf_wdata),
        .i_ext_raddr    (upctl_adc_raddr),
        .o_ext_rdata    (upctl_adc_rdata)
    );

    // -------------------------------------------------------------------------
    // cnn_result_buf — captures result flits from BSG RX for output_ctrl
    // -------------------------------------------------------------------------
    wire        cbuf_sel = dbus_cyc & (dbus_addr[15:6] == 10'h380);
    wire        cbuf_ack;
    wire [31:0] cbuf_rdt;
    wire        cbuf_bsg_yumi;
    wire        cbuf_ready, cbuf_overflow;
    wire  [3:0] cbuf_ext_raddr;
    wire [15:0] cbuf_ext_rdata;

    wire [15:0] bsg_rx_data;
    wire        bsg_rx_valid;
    assign bsg_rx_data  = bsg_rx_data_i;
    assign bsg_rx_valid = bsg_rx_valid_i;

    wire cbuf_buf_clear;

    cnn_result_buf u_cbuf (
        .clk            (CLK_IN),
        .rst            (~perip_rst_n),
        .i_wb_cyc       (cbuf_sel),
        .i_wb_we        (dbus_we),
        .i_wb_adr       (dbus_addr),
        .i_wb_dat       (dbus_wdata),
        .o_wb_ack       (cbuf_ack),
        .o_wb_rdt       (cbuf_rdt),
        .i_bsg_rx_data  (bsg_rx_data),
        .i_bsg_rx_valid (bsg_rx_valid),
        .o_bsg_rx_yumi  (cbuf_bsg_yumi),
        .i_ext_raddr    (cbuf_ext_raddr),
        .o_ext_rdata    (cbuf_ext_rdata),
        .i_buf_clear    (cbuf_buf_clear),
        .o_buf_ready    (cbuf_ready),
        .o_buf_overflow (cbuf_overflow)
    );

    // Combined BSG RX yumi: firmware direct read or cnn_result_buf
    wire rd_bsg_rx = dbus_cyc & ~dbus_we & (dbus_addr[15:0] == 16'hC008);
    assign bsg_rx_yumi_o = cbuf_bsg_yumi | (rd_bsg_rx & bsg_rx_valid);

    // -------------------------------------------------------------------------
    // uart_peripheral — peripheral reset
    // -------------------------------------------------------------------------
    wire        uart_wb_cyc = dbus_cyc & (dbus_addr[15:4] == 12'hA00);
    wire        uart_wb_ack;
    wire [31:0] uart_wb_rdt;
    wire        peripheral_uart_tx;

    // Forward-declared framer→uart stream wires (driven by pkt_framer below)
    wire [7:0]  framer_uart_byte;
    wire        framer_uart_valid;
    wire        framer_stream_ready;

    uart_peripheral #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (UART_BAUD)
    ) u_uart (
        .clk               (CLK_IN),
        .rst               (~perip_rst_n),
        .i_wb_cyc          (uart_wb_cyc),
        .i_wb_we            (dbus_we),
        .i_wb_adr          (dbus_addr),
        .i_wb_dat          (dbus_wdata),
        .o_wb_rdt          (uart_wb_rdt),
        .o_wb_ack          (uart_wb_ack),
        .o_uart_tx         (peripheral_uart_tx),
        .i_stream_tx_data  (framer_uart_byte),
        .i_stream_tx_valid (framer_uart_valid),
        .o_stream_tx_ready (framer_stream_ready)
    );

    assign uart_tx_o = iram_ack_done ? peripheral_uart_tx : loader_uart_tx;

    wire uart_tx_ready = ~uart_wb_rdt[0];

    // -------------------------------------------------------------------------
    // pkt_framer — peripheral reset
    //
    // Self-driving: watches cnn_result_buf, frames 0xB0 packets, sends to
    // uart_peripheral stream port, clears the buffer when done.
    // -------------------------------------------------------------------------
    pkt_framer u_framer (
        .clk             (CLK_IN),
        .rst             (~perip_rst_n),
        .i_cnn_ready     (cbuf_ready),
        .o_cnn_raddr     (cbuf_ext_raddr),
        .i_cnn_rdata     (cbuf_ext_rdata),
        .o_cnn_buf_clear (cbuf_buf_clear),
        .o_uart_byte     (framer_uart_byte),
        .o_uart_valid    (framer_uart_valid),
        .i_uart_ready    (framer_stream_ready)
    );

    // -------------------------------------------------------------------------
    // BSG_LINK registers + upstream TX mux
    //
    // Two sources can drive BSG TX:
    //   1. Firmware direct: write to 0xC000 (bsg_tx_fw_*)
    //   2. DMA (bsg_link_upstream_ctl): autonomous ADC→ring stream
    //
    // bsg_link_upstream_ctl has priority when its DMA is active (up_ctl_busy).
    // -------------------------------------------------------------------------
    // ASIC chip_top owns the physical bsg_link reset sequencing.
    // No SERV-writable soft reset is exposed here.
    reg        bsg_tx_fw_valid;
    reg [15:0] bsg_tx_fw_data;
    wire       bsg_tx_ready = bsg_tx_ready_i;
    wire [15:0] up_ctl_tx_data;
    wire        up_ctl_tx_valid;

    wire wr_bsg_tx         = dbus_cyc & dbus_we & (dbus_addr[15:0] == 16'hC000);

    always_ff @(posedge CLK_IN) begin
        if (!nRESET) begin
            bsg_tx_fw_valid <= 1'b0;
            bsg_tx_fw_data  <= 16'd0;
        end else begin
            if (wr_bsg_tx) begin
                bsg_tx_fw_valid <= 1'b1;
                bsg_tx_fw_data  <= dbus_wdata[15:0];
            end else if (bsg_tx_fw_valid && bsg_tx_ready && !up_ctl_busy) begin
                bsg_tx_fw_valid <= 1'b0;
            end
        end
    end

    // Mux: DMA takes priority over firmware direct writes
    wire        bsg_tx_valid_mux = serv_rst_n? (up_ctl_busy ? up_ctl_tx_valid : bsg_tx_fw_valid):1'b0;
    wire [15:0] bsg_tx_data_mux  = up_ctl_busy ? up_ctl_tx_data  : bsg_tx_fw_data;
    assign bsg_tx_data_o  = bsg_tx_data_mux;
    assign bsg_tx_valid_o = bsg_tx_valid_mux;

    // -------------------------------------------------------------------------
    // bsg_link_upstream_ctl — DMA engine: ADC buffer → BSG TX
    // -------------------------------------------------------------------------
    // 0xC030-0xC03F: addr[15:4]==12'hC03
    // 0xC040-0xC043: addr[15:2]==14'h3010  (covers 0xC040)
    wire        up_ctl_sel = dbus_cyc & ((dbus_addr[15:4] == 12'hC03) |
                                         (dbus_addr[15:2] == 14'h3010));
    wire        up_ctl_wb_ack;
    wire [31:0] up_ctl_wb_rdt;
    wire        up_ctl_ack_irq;         // NOTE: This is unused for now

    bsg_link_upstream_ctl #(
        .FLIT_W          (BSG_WIDTH_P),
        .NUM_ELEMENTS    (ADC_FRAME_SIZE),
        .DEFAULT_DEST_ID (1)
    ) u_up_ctl (
        .clk            (CLK_IN),
        .rst            (~perip_rst_n),
        .o_adc_raddr    (upctl_adc_raddr),
        .i_adc_rdata    (upctl_adc_rdata),
        .o_bsg_tx_data  (up_ctl_tx_data),
        .o_bsg_tx_valid (up_ctl_tx_valid),
        .i_bsg_tx_ready (bsg_tx_ready),
        .i_pkt_ack      (1'b0),
        .o_ack_irq      (up_ctl_ack_irq),
        .o_busy         (up_ctl_busy),
        .i_frame_done   (scan_frame_done),
        .i_wb_cyc       (up_ctl_sel),
        .i_wb_we        (dbus_we),
        .i_wb_adr       (dbus_addr),
        .i_wb_dat       (dbus_wdata),
        .o_wb_rdt       (up_ctl_wb_rdt),
        .o_wb_ack       (up_ctl_wb_ack)
    );

    // -------------------------------------------------------------------------
    // Wishbone data bus mux
    // -------------------------------------------------------------------------
    always_comb begin
        dbus_rdata = 32'h0;
        dbus_ack   = 1'b0;

        if (dbus_cyc) begin
            casez (dbus_addr[15:0])
                // 0x0000-0x07FF -> data_ram (immediate ack, comb. read)
                // 0x0000-0x00FF -> data_ram (writes ack immediately, reads 1-cycle)
                16'h0???: begin
                    if (!dbus_addr[11]) begin
                        dbus_rdata = dram_rdt;
                        dbus_ack   = dbus_we ? 1'b1 : dram_ack;  // writes ack immediately, reads wait
                    end else begin
                        dbus_rdata = iram_drd_rdt;
                        dbus_ack   = iram_drd_ack;
                    end
                end
                16'h500?: begin
                    dbus_rdata = mux_wb_rdt;
                    dbus_ack   = mux_wb_ack;
                end
                16'h6000,
                16'h6004,
                16'h6008,
                16'h600C,
                16'h6010: begin
                    dbus_rdata = scan_wb_rdt;
                    dbus_ack   = scan_wb_ack;
                end
                16'h700?: begin
                    dbus_rdata = spi_wb_rdt;
                    dbus_ack   = spi_wb_ack;
                end
                16'h8???: begin
                    if (abuf_sel) begin
                        dbus_rdata = abuf_rdt;
                        dbus_ack   = abuf_ack;
                    end else begin
                        dbus_ack   = 1'b1;
                    end
                end
                16'hA00?: begin
                    dbus_rdata = uart_wb_rdt;
                    dbus_ack   = uart_wb_ack;
                end
                // BSG_LINK firmware direct registers
                16'hC000: begin dbus_rdata = 32'h0;                    dbus_ack = 1'b1; end
                16'hC004: begin dbus_rdata = {31'b0,~bsg_tx_ready};    dbus_ack = 1'b1; end
                16'hC008: begin dbus_rdata = {16'b0,bsg_rx_data};      dbus_ack = 1'b1; end
                16'hC00C: begin dbus_rdata = {31'b0,bsg_rx_valid};     dbus_ack = 1'b1; end
                16'hC010: begin dbus_rdata = 32'h0;                    dbus_ack = 1'b1; end
                // bsg_link_upstream_ctl registers
                16'hC030,
                16'hC034,
                16'hC038,
                16'hC03C,
                16'hC040: begin
                    dbus_rdata = up_ctl_wb_rdt;
                    dbus_ack   = up_ctl_wb_ack;
                end
                16'hE0??: begin
                    if (dbus_addr[15:6] == 10'h380) begin
                        dbus_rdata = cbuf_rdt;
                        dbus_ack   = cbuf_ack;
                    end else begin
                        dbus_ack   = 1'b1;
                    end
                end
                default: begin
                    dbus_rdata = 32'h0;
                    dbus_ack   = 1'b1;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // SERV
    // -------------------------------------------------------------------------
    serv_rf_top #(
        .RESET_PC       (32'h0000_0000),
        .RESET_STRATEGY ("MINI"),
        .WITH_CSR       (1)
    ) u_serv (
        .clk          (CLK_IN),
        .i_rst        (~serv_rst_n),
        .i_rf_por_rstn(nRESET),
        .i_timer_irq  (1'b0),
        .o_ibus_adr   (ibus_adr),
        .o_ibus_cyc   (ibus_cyc),
        .i_ibus_rdt   (ibus_rdt),
        .i_ibus_ack   (ibus_ack),
        .o_dbus_adr   (serv_dbus_addr),
        .o_dbus_dat   (serv_dbus_wdata),
        .o_dbus_sel   (serv_dbus_be),
        .o_dbus_we    (serv_dbus_we),
        .o_dbus_cyc   (serv_dbus_cyc),
        .i_dbus_rdt   (dbus_rdata),
        .i_dbus_ack   (dbus_ack),
        .i_ext_rd     (32'h0),
        .i_ext_ready  (1'b0),
        .o_ext_funct3 (),
        .o_mdu_valid  (),
        .o_rf_init_done(rf_init_done)
    );

endmodule
`default_nettype wire