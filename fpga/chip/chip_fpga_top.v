// chip_fpga_top.v
// Top level for FPGA A (the "chip" board, DE1-SoC).
// Puts the unchanged chip_top on the FPGA. Every chip pad is a named
// top-level pin; chip.qsf puts PAD n on header pin GPIO_0[n] (n < 36)
// or GPIO_1[n-36] (n >= 36). See docs/PINOUT.md.
//
// All pads are "inout" because the chip's own pad cells decide the
// direction (like the real chip). Directions below are from the chip's view.
//
// Board controls:
//   SW0 up = hold chip in reset (added to hard_reset from the driver)
//   LED0 chip running   LED1 clock arriving   LED2 firmware loaded
//   LED3 BOOT OK        LED4 ADC reading      LED5 BSG sending
//   LED6 BSG receiving  LED7 UART output      LED8 result packet sent

module chip_fpga_top (
    // bsg_link into the chip (from CNN side)
    inout  wire [7:0] dn_data,     // PAD 0-7   in
    inout  wire       dn_clk,      // PAD 8     in
    inout  wire       dn_valid,    // PAD 9     in
    inout  wire       dn_token,    // PAD 10    out (credits back)
    // bsg_link out of the chip (to CNN side)
    inout  wire       token_clk,   // PAD 12    in  (credits in)
    inout  wire       up_valid,    // PAD 14    out
    inout  wire       up_clk,      // PAD 15    out
    inout  wire [7:0] up_data,     // PAD 16-23 out (interleaved, see qsf)
    // SPI ADC
    inout  wire       spi_sclk,    // PAD 13    out
    inout  wire       spi_miso,    // PAD 25    in
    inout  wire       spi_cs_n,    // PAD 26    out
    // UART
    inout  wire       uart_rx,     // PAD 24    in
    inout  wire       uart_tx,     // PAD 27    out
    // I2C
    inout  wire       i2c_scl,     // PAD 28
    inout  wire       i2c_sda,     // PAD 29
    // Sensor mux
    inout  wire [3:0] mux_row,     // PAD 36-39 out
    inout  wire [3:0] mux_col,     // PAD 40-43 out
    // Clock, reset, scan
    inout  wire       core_clk,    // PAD 44    in
    inout  wire       hard_reset,  // PAD 45    in  (1 = reset)
    inout  wire       scan_en,     // PAD 11    in  (must be 0)
    inout  wire       scan_in,     // PAD 46    in
    inout  wire       scan_out,    // PAD 47    out
    // Board
    input  wire [9:0] SW,
    output wire [9:0] LEDR
);

    // ---- Reset: driver's hard_reset OR switch 0 ----
    wire reset_mix = hard_reset | SW[0];   // 1 = reset

    // PAD 30-35 are not used by the chip
    wire [5:0] unused_pads;

    // ---- The chip: build its 48-pad bus from the named pins ----
    chip_top u_chip (
        .PAD ({ scan_out, scan_in, reset_mix, core_clk,                  // 47-44
                mux_col, mux_row,                                        // 43-36
                unused_pads,                                             // 35-30
                i2c_sda, i2c_scl, uart_tx, spi_cs_n, spi_miso, uart_rx,  // 29-24
                up_data[1], up_data[0], up_data[3], up_data[2],          // 23-20
                up_data[5], up_data[4], up_data[7], up_data[6],          // 19-16
                up_clk, up_valid, spi_sclk, token_clk,                   // 15-12
                scan_en, dn_token, dn_valid, dn_clk,                     // 11-8
                dn_data }),                                              // 7-0
        .VDDPST (), .VSSPST (), .VDD (), .VSS ()   // power: not used on FPGA
    );

    // ---- Status LEDs (watch the chip's pins) ----
    chip_leds u_leds (
        .clk      (core_clk),
        .reset    (reset_mix),
        .uart_tx  (uart_tx),
        .spi_cs_n (spi_cs_n),
        .up_valid (up_valid),
        .dn_valid (dn_valid),
        .led      (LEDR)
    );

endmodule
