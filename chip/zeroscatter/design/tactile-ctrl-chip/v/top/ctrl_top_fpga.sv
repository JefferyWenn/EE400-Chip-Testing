// =============================================================================
// ctrl_top_fpga.sv — FPGA emulation wrapper for ctrl_top
//
// Thin wrapper that adds bsg_link_reset + bsg_link_wrapper around ctrl_top,
// exposing DDR BSG ports so dual_chip_top can connect ctrl and DLA directly.
//
// NOT for ASIC tapeout — chip_top.sv owns the pad ring and bsg_link_wrapper
// for silicon. This file is FPGA-only (emu/full_1dla).
//
// Port list matches what dual_chip_top.sv expects from ctrl_top.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module ctrl_top_fpga (
    input  wire        CLK_IN,
    input  wire        nRESET,

    // BSG DDR upstream TX (ctrl → dla)
    output wire        bsg_up_clk_o,
    output wire [7:0]  bsg_up_data_o,
    output wire        bsg_up_valid_o,
    input  wire        bsg_up_token_i,

    // BSG DDR downstream RX (dla → ctrl)
    input  wire        bsg_dn_clk_i,
    input  wire [7:0]  bsg_dn_data_i,
    input  wire        bsg_dn_valid_i,
    output wire        bsg_dn_token_o,

    // UART
    output wire        uart_tx_o,
    input  wire        uart_rx_i,

    // I2C
    inout  wire        i2c_sda_io,
    inout  wire        i2c_scl_io,

    // SPI — AD7466 ADC
    output wire        spi_clk_o,
    input  wire        spi_miso_i,
    output wire        spi_cs_n_o,

    // Sensor MUX
    output wire [3:0]  mux_row_o,
    output wire [3:0]  mux_col_o,

    // JTAG stub (pass-through; no JTAG logic in ctrl_top)
    input  wire        jtag_tck_i,
    input  wire        jtag_tms_i,
    input  wire        jtag_tdi_i,
    output wire        jtag_tdo_o,

    // BSG link calibration status
    output wire        o_calib_done,

    // Firmware debug snoop (tied off — ctrl_top has no dbg port)
    output wire        o_dbg_byte_valid,
    output wire [7:0]  o_dbg_byte
);

    // ── BSG link parameters ───────────────────────────────────────
    localparam FLIT_WIDTH   = 16;
    localparam CH_WIDTH     = 8;
    localparam LG_FIFO      = 6;
    localparam LG_TOK_DEC   = 3;

    // ── JTAG stub ─────────────────────────────────────────────────
    assign jtag_tdo_o = jtag_tdi_i;

    // ── Debug snoop tied off ──────────────────────────────────────
    assign o_dbg_byte_valid = 1'b0;
    assign o_dbg_byte       = 8'h0;

    // ── Reset sync ────────────────────────────────────────────────
    wire rst_sync;
    reg rst_ff1, rst_n_sync_w;
    always_ff @(posedge CLK_IN or negedge nRESET) begin
        if (!nRESET) begin rst_ff1 <= 1'b0; rst_n_sync_w <= 1'b0; end
        else         begin rst_ff1 <= 1'b1; rst_n_sync_w <= rst_ff1; end
    end
    assign rst_sync = !rst_n_sync_w;

    // ── bsg_link_reset — same max_val_p=32 as dla_chip.sv ────────
    wire link_async_token_reset;
    wire link_io_upstream_reset;
    wire link_io_downstream_reset;
    wire link_core_reset;
    wire link_core_calib_done;

    bsg_link_reset #(
        .max_val_p (32)
    ) u_link_reset (
        .core_clk_i                 (CLK_IN),
        .async_reset_i              (rst_sync),
        .io_master_clk_i            (CLK_IN),
        .io_clk_tline_i             (bsg_dn_clk_i),
        .async_token_reset_o        (link_async_token_reset),
        .io_upstream_link_reset_o   (link_io_upstream_reset),
        .io_downstream_link_reset_o (link_io_downstream_reset),
        .core_link_reset_o          (link_core_reset),
        .core_calib_done_r_o        (link_core_calib_done)
    );

    assign o_calib_done = link_core_calib_done;

    // ── bsg_link_wrapper — flit ↔ DDR ────────────────────────────
    wire [15:0] bsg_rx_data;
    wire        bsg_rx_valid;
    wire        bsg_rx_yumi;
    wire [15:0] bsg_tx_data;
    wire        bsg_tx_valid;
    wire        bsg_tx_ready;

    bsg_link_wrapper #(
        .FLIT_WIDTH                    (FLIT_WIDTH),
        .CHANNEL_WIDTH                 (CH_WIDTH),
        .LG_FIFO_DEPTH                 (LG_FIFO),
        .LG_CREDIT_TO_TOKEN_DECIMATION (LG_TOK_DEC)
    ) u_bsg_link (
        .core_clk_i                 (CLK_IN),
        .reset_i                    (link_core_reset),

        // TX (upstream) — ctrl → dla
        .io_master_clk_i            (CLK_IN),
        .upstream_io_link_reset_i   (link_io_upstream_reset),
        .async_token_reset_i        (link_async_token_reset),
        .token_clk_i                (bsg_up_token_i),
        .upstream_io_clk_r_o        (bsg_up_clk_o),
        .upstream_io_data_r_o       (bsg_up_data_o),
        .upstream_io_valid_r_o      (bsg_up_valid_o),

        // RX (downstream) — dla → ctrl
        .downstream_io_link_reset_i (link_io_downstream_reset),
        .downstream_io_clk_i        (bsg_dn_clk_i),
        .downstream_io_data_i       (bsg_dn_data_i),
        .downstream_io_valid_i      (bsg_dn_valid_i),
        .downstream_core_token_r_o  (bsg_dn_token_o),

        // Core flit interface → ctrl_top
        .rx_data_o                  (bsg_rx_data),
        .rx_valid_o                 (bsg_rx_valid),
        .rx_yumi_i                  (bsg_rx_yumi),
        .tx_data_i                  (bsg_tx_data),
        .tx_valid_i                 (bsg_tx_valid),
        .tx_ready_o                 (bsg_tx_ready)
    );

    // ── ctrl_top — I2C oen/ie handled internally ─────────────────
    // ctrl_top drives i2c_sda/scl_io directly as inout.
    // oen/ie outputs are unused in FPGA context (no pad ring).
    wire i2c_sda_oen_w, i2c_sda_ie_w, i2c_scl_oen_w, i2c_scl_ie_w;

    // ── ctrl_top instantiation ────────────────────────────────────
    ctrl_top u_ctrl (
        .CLK_IN           (CLK_IN),
        .nRESET           (nRESET),

        // BSG flit interface
        .bsg_rx_data_i    (bsg_rx_data),
        .bsg_rx_valid_i   (bsg_rx_valid),
        .bsg_rx_yumi_o    (bsg_rx_yumi),
        .bsg_tx_data_o    (bsg_tx_data),
        .bsg_tx_valid_o   (bsg_tx_valid),
        .bsg_tx_ready_i   (bsg_tx_ready),

        // UART
        .uart_tx_o        (uart_tx_o),
        .uart_rx_i        (uart_rx_i),

        // I2C
        .i2c_sda_io       (i2c_sda_io),
        .i2c_scl_io       (i2c_scl_io),
        .i2c_sda_oen      (i2c_sda_oen_w),
        .i2c_sda_ie       (i2c_sda_ie_w),
        .i2c_scl_oen      (i2c_scl_oen_w),
        .i2c_scl_ie       (i2c_scl_ie_w),

        // SPI
        .spi_clk_o        (spi_clk_o),
        .spi_miso_i       (spi_miso_i),
        .spi_cs_n_o       (spi_cs_n_o),

        // MUX
        .mux_row_o        (mux_row_o),
        .mux_col_o        (mux_col_o)
    );

endmodule

`default_nettype wire
