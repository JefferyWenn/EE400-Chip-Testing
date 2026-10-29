// fullsys_top.v
// Full-system emulation on ONE DE1-SoC: test driver + chip under test,
// with the real glove/ADC board on the chip's sensor pins.
//
// Loopback: 26 link/clock/reset/UART signals leave the driver on JP1 (GPIO_0)
// and come back to the chip on JP2 (GPIO_1): wire k = JP1 pin N -> JP2 pin N.
// Glove board: the chip's SPI, mux and I2C pins go to the glove board.
//
// Board controls:
//   SW0 up = hold everything in reset      SW1 up = send the firmware
//   SW2 up = use the loopback wires, down = connect inside the FPGA
//   SW9 up = LEDs show the chip side, down = LEDs show the driver side
//   KEY0   = restart
//   HEX    = driver: fps (HEX5-4), strongest pixel (HEX3-2),
//            its row and column (HEX1-0)
//   Chip-side LED9 = chip's I2C write (0x5E, 0x7D) seen on the pins
//
// Loopback wire k (GPIO_0[k] <-> GPIO_1[k]):
//   0-7 dn_data  8 dn_clk  9 dn_valid  10 dn_token  11 token_clk  12 up_clk
//   13 up_valid  14-21 up_data  22 core_clk  23 hard_reset  24 uart_rx  25 uart_tx
// Glove board (chip side):
//   GPIO_1[26..29] = GND_SEL[0..3] (mux_row)   GPIO_1[30..33] = RD_SEL[0..3] (mux_col)
//   GPIO_1[34] = I2C_SCL   GPIO_1[35] = I2C_SDA
//   GPIO_0[26] = ADC_SCLK  GPIO_0[27] = ADC_MISO  GPIO_0[28] = ADC_CS_n

module fullsys_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire [35:0] GPIO_0,     // JP1
    inout  wire [35:0] GPIO_1      // JP2
);
    wire loop  = SW[2];            // 1 = through the loopback wires

    // ================= Signal names =================
    // chip side (c_...)
    wire [7:0] c_dn_data;
    wire c_dn_clk, c_dn_valid, c_token_clk, c_core_clk, c_hard_reset, c_uart_rx, c_spi_miso;
    wire [7:0] c_up_data;
    wire [3:0] c_mux_row, c_mux_col;
    wire c_dn_token, c_up_clk, c_up_valid, c_uart_tx, c_spi_sclk, c_spi_cs_n, c_scan_out;
    wire [9:0] chip_led;

    // ================= Driver side =================
    wire [7:0] d_dn_data;
    wire d_dn_clk, d_dn_valid, d_token_clk, d_core_clk, d_hard_reset;
    wire d_uart_rx, d_spi_miso, d_scan_en, d_scan_in;
    wire [7:0] d_up_data;   // d_spi_miso (fake ADC) is left unused
    wire d_dn_token, d_up_clk, d_up_valid, d_uart_tx, d_scan_out;
    wire [9:0] drv_led;

    driver_top #(.FW_FILE("../driver/firmware.hex")) u_drv (
        .CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW), .LEDR(drv_led),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .dn_data(d_dn_data), .dn_clk(d_dn_clk), .dn_valid(d_dn_valid), .dn_token(d_dn_token),
        .scan_en(d_scan_en), .token_clk(d_token_clk),
        .up_valid(d_up_valid), .up_clk(d_up_clk), .up_data(d_up_data),
        .uart_rx(d_uart_rx), .uart_tx(d_uart_tx),
        .spi_sclk(c_spi_sclk), .spi_miso(d_spi_miso), .spi_cs_n(c_spi_cs_n),   // fake ADC (not used)
        .mux_row(c_mux_row), .mux_col(c_mux_col),                              // listens inside
        .i2c_scl(1'b1), .i2c_sda(1'b1),                                        // not used
        .core_clk(d_core_clk), .hard_reset(d_hard_reset), .scan_in(d_scan_in), .scan_out(d_scan_out)
    );

    // ================= Chip side =================

    chip_fpga_top u_chip (
        .dn_data(c_dn_data), .dn_clk(c_dn_clk), .dn_valid(c_dn_valid), .dn_token(c_dn_token),
        .token_clk(c_token_clk), .up_valid(c_up_valid), .up_clk(c_up_clk), .up_data(c_up_data),
        .spi_sclk(c_spi_sclk), .spi_miso(c_spi_miso), .spi_cs_n(c_spi_cs_n),
        .uart_rx(c_uart_rx), .uart_tx(c_uart_tx),
        .i2c_scl(GPIO_1[34]), .i2c_sda(GPIO_1[35]),   // chip drives the glove's I2C pins
        .mux_row(c_mux_row), .mux_col(c_mux_col),
        .core_clk(c_core_clk), .hard_reset(c_hard_reset),
        .scan_en(d_scan_en), .scan_in(d_scan_in), .scan_out(c_scan_out),
        .SW(10'b0), .LEDR(chip_led)
    );

    // ================= Loopback wires 0-25 =================
    // driver -> chip: driver drives JP1, chip reads JP2 (or the inside copy)
    assign GPIO_0[7:0] = d_dn_data;     assign c_dn_data    = loop ? GPIO_1[7:0] : d_dn_data;
    assign GPIO_0[8]   = d_dn_clk;      assign c_dn_clk     = loop ? GPIO_1[8]   : d_dn_clk;
    assign GPIO_0[9]   = d_dn_valid;    assign c_dn_valid   = loop ? GPIO_1[9]   : d_dn_valid;
    assign GPIO_0[11]  = d_token_clk;   assign c_token_clk  = loop ? GPIO_1[11]  : d_token_clk;
    assign GPIO_0[22]  = d_core_clk;    assign c_core_clk   = loop ? GPIO_1[22]  : d_core_clk;
    assign GPIO_0[23]  = d_hard_reset;  assign c_hard_reset = loop ? GPIO_1[23]  : d_hard_reset;
    assign GPIO_0[24]  = d_uart_rx;     assign c_uart_rx    = loop ? GPIO_1[24]  : d_uart_rx;

    // chip -> driver: chip drives JP2, driver reads JP1 (or the inside copy)
    assign GPIO_1[10]    = c_dn_token;  assign d_dn_token = loop ? GPIO_0[10]    : c_dn_token;
    assign GPIO_1[12]    = c_up_clk;    assign d_up_clk   = loop ? GPIO_0[12]    : c_up_clk;
    assign GPIO_1[13]    = c_up_valid;  assign d_up_valid = loop ? GPIO_0[13]    : c_up_valid;
    assign GPIO_1[21:14] = c_up_data;   assign d_up_data  = loop ? GPIO_0[21:14] : c_up_data;
    assign GPIO_1[25]    = c_uart_tx;   assign d_uart_tx  = loop ? GPIO_0[25]    : c_uart_tx;

    // ================= Glove board =================
    assign GPIO_1[29:26] = c_mux_row;     // GND_SEL[3:0]
    assign GPIO_1[33:30] = c_mux_col;     // RD_SEL[3:0]
    assign GPIO_0[26]    = c_spi_sclk;    // ADC_SCLK
    assign GPIO_0[28]    = c_spi_cs_n;    // ADC_CS_n
    assign c_spi_miso    = GPIO_0[27];    // ADC_MISO (always the real glove)

    assign d_scan_out = c_scan_out;

    // ================= I2C check (reads the chip's I2C pins) =================
    wire i2c_ok;
    i2c_monitor u_i2c (
        .clk(CLOCK_50), .reset(SW[0] | ~KEY[0]),
        .scl(GPIO_1[34]), .sda(GPIO_1[35]),
        .ok(i2c_ok)
    );

    // ================= LEDs =================
    assign LEDR = SW[9] ? {i2c_ok, chip_led[8:0]} : drv_led;

endmodule
