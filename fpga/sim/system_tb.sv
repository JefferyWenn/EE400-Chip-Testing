// Testbench for the two-board setup: chip_fpga_top and driver_top joined by wires.
// +WIRE_NS=n       delay on every wire
// +SKEW_NS=n       extra delay per bus bit (bit i gets i * n)
// +CLK_EXTRA_NS=n  extra delay on the clock wires
// +RUN_MS=n        how long to run after the firmware is sent

`timescale 1ns/1ps

module system_tb;

    logic clock_50 = 0;
    always #10 clock_50 = ~clock_50;

    real wire_ns = 0.0, skew_ns = 0.0, clk_extra_ns = 0.0;
    initial begin
        if (!$value$plusargs("WIRE_NS=%f", wire_ns))           wire_ns      = 0.0;
        if (!$value$plusargs("SKEW_NS=%f", skew_ns))           skew_ns      = 0.0;
        if (!$value$plusargs("CLK_EXTRA_NS=%f", clk_extra_ns)) clk_extra_ns = 0.0;
        $display("Wire delay %0.1f ns, bus skew %0.1f ns/bit, clock extra %0.1f ns",
                 wire_ns, skew_ns, clk_extra_ns);
    end

    // each signal has a driver side (d_) and a chip side (c_), joined by a delayed copy

    // driver -> chip
    logic [7:0] d_dn_data, c_dn_data;
    logic d_dn_clk, d_dn_valid, d_scan_en, d_token_clk, d_uart_rx, d_spi_miso;
    logic d_core_clk, d_hard_reset, d_scan_in;
    logic c_dn_clk, c_dn_valid, c_scan_en, c_token_clk, c_uart_rx, c_spi_miso;
    logic c_core_clk, c_hard_reset, c_scan_in;

    // chip -> driver (chip side is wire because it comes from the chip's inout pads)
    wire  [7:0] c_up_data;   logic [7:0] d_up_data;
    wire  [3:0] c_mux_row, c_mux_col;   logic [3:0] d_mux_row, d_mux_col;
    wire  c_dn_token, c_spi_sclk, c_up_valid, c_up_clk, c_spi_cs_n, c_uart_tx, c_scan_out;
    logic d_dn_token, d_spi_sclk, d_up_valid, d_up_clk, d_spi_cs_n, d_uart_tx, d_scan_out;

    // I2C is one shared line with pull-ups
    wire i2c_scl, i2c_sda;
    pullup (i2c_scl);
    pullup (i2c_sda);

    always @(d_core_clk)  c_core_clk  <= #(wire_ns + clk_extra_ns) d_core_clk;
    always @(d_dn_clk)    c_dn_clk    <= #(wire_ns + clk_extra_ns) d_dn_clk;
    always @(d_token_clk) c_token_clk <= #(wire_ns + clk_extra_ns) d_token_clk;
    always @(c_up_clk)    d_up_clk    <= #(wire_ns + clk_extra_ns) c_up_clk;
    always @(c_dn_token)  d_dn_token  <= #(wire_ns + clk_extra_ns) c_dn_token;

    always @(d_dn_valid)   c_dn_valid   <= #(wire_ns) d_dn_valid;
    always @(d_scan_en)    c_scan_en    <= #(wire_ns) d_scan_en;
    always @(d_uart_rx)    c_uart_rx    <= #(wire_ns) d_uart_rx;
    always @(d_spi_miso)   c_spi_miso   <= #(wire_ns) d_spi_miso;
    always @(d_hard_reset) c_hard_reset <= #(wire_ns) d_hard_reset;
    always @(d_scan_in)    c_scan_in    <= #(wire_ns) d_scan_in;
    always @(c_spi_sclk)   d_spi_sclk   <= #(wire_ns) c_spi_sclk;
    always @(c_up_valid)   d_up_valid   <= #(wire_ns) c_up_valid;
    always @(c_spi_cs_n)   d_spi_cs_n   <= #(wire_ns) c_spi_cs_n;
    always @(c_uart_tx)    d_uart_tx    <= #(wire_ns) c_uart_tx;
    always @(c_scan_out)   d_scan_out   <= #(wire_ns) c_scan_out;

    genvar gi;
    for (gi = 0; gi < 8; gi = gi + 1) begin : g8
        always @(d_dn_data[gi]) c_dn_data[gi] <= #(wire_ns + gi * skew_ns) d_dn_data[gi];
        always @(c_up_data[gi]) d_up_data[gi] <= #(wire_ns + gi * skew_ns) c_up_data[gi];
    end
    for (gi = 0; gi < 4; gi = gi + 1) begin : g4
        always @(c_mux_row[gi]) d_mux_row[gi] <= #(wire_ns + gi * skew_ns) c_mux_row[gi];
        always @(c_mux_col[gi]) d_mux_col[gi] <= #(wire_ns + gi * skew_ns) c_mux_col[gi];
    end

    // the chip's pads are inout, so they need nets
    wire [7:0] chip_dn_data = c_dn_data;
    wire chip_dn_clk = c_dn_clk, chip_dn_valid = c_dn_valid, chip_scan_en = c_scan_en;
    wire chip_token_clk = c_token_clk, chip_uart_rx = c_uart_rx, chip_spi_miso = c_spi_miso;
    wire chip_core_clk = c_core_clk, chip_hard_reset = c_hard_reset, chip_scan_in = c_scan_in;

    logic [9:0] chip_led;
    chip_fpga_top chip (
        .dn_data(chip_dn_data), .dn_clk(chip_dn_clk), .dn_valid(chip_dn_valid), .dn_token(c_dn_token),
        .token_clk(chip_token_clk), .up_valid(c_up_valid), .up_clk(c_up_clk), .up_data(c_up_data),
        .spi_sclk(c_spi_sclk), .spi_miso(chip_spi_miso), .spi_cs_n(c_spi_cs_n),
        .uart_rx(chip_uart_rx), .uart_tx(c_uart_tx), .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        .mux_row(c_mux_row), .mux_col(c_mux_col),
        .core_clk(chip_core_clk), .hard_reset(chip_hard_reset),
        .scan_en(chip_scan_en), .scan_in(chip_scan_in), .scan_out(c_scan_out),
        .SW(10'h0), .LEDR(chip_led)
    );

    // SW1 up so the driver sends the firmware
    driver_top #(
        .FW_FILE("/home/jwen68/Projects/EE400-Chip-Testing/fpga/driver/firmware.hex")
    ) drv (
        .CLOCK_50(clock_50), .KEY(4'hF), .SW(10'h002), .LEDR(),
        .HEX0(), .HEX1(), .HEX2(), .HEX3(), .HEX4(), .HEX5(),
        .dn_data(d_dn_data), .dn_clk(d_dn_clk), .dn_valid(d_dn_valid), .dn_token(d_dn_token),
        .scan_en(d_scan_en), .token_clk(d_token_clk), .spi_sclk(d_spi_sclk),
        .up_valid(d_up_valid), .up_clk(d_up_clk), .up_data(d_up_data),
        .uart_rx(d_uart_rx), .spi_miso(d_spi_miso), .spi_cs_n(d_spi_cs_n), .uart_tx(d_uart_tx),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .mux_row(d_mux_row), .mux_col(d_mux_col),
        .core_clk(d_core_clk), .hard_reset(d_hard_reset), .scan_in(d_scan_in), .scan_out(d_scan_out)
    );

    // print what the chip sends on UART (115200 baud at 50 MHz)
    localparam real BIT_NS = 434 * 20.0;
    logic chip_tx;
    assign chip_tx = c_uart_tx;

    integer rx_count = 0;
    logic [7:0] rx_byte;
    initial begin : listener
        integer i;
        forever begin
            @(negedge chip_tx);
            #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin rx_byte[i] = chip_tx; #(BIT_NS); end
            rx_count = rx_count + 1;
            if (rx_byte >= 8'h20 && rx_byte < 8'h7F)
                $display("[%0.2f ms] chip sent 0x%02h '%c'", $realtime/1.0e6, rx_byte, rx_byte);
            else
                $display("[%0.2f ms] chip sent 0x%02h", $realtime/1.0e6, rx_byte);
        end
    end

    integer spi_reads = 0;
    always @(negedge c_spi_cs_n) spi_reads = spi_reads + 1;
    integer flits = 0;
    always @(posedge drv.clk) if (drv.rx_valid) begin
        flits = flits + 1;
        if (drv.rx_data == 16'h0404 || drv.rx_data == 16'h0408)
            $display("[%0.2f ms] fake CNN got flit #%0d = 0x%04h",
                     $realtime/1.0e6, flits, drv.rx_data);
    end
    always @(posedge drv.clk) if (drv.tx_valid && drv.tx_ready && drv.u_cnn.idx == 0)
        $display("[%0.2f ms] fake CNN starts sending result", $realtime/1.0e6);

    initial begin wait (chip_led[0]); $display("[%0.2f ms] chip LED0: running",         $realtime/1.0e6); end
    initial begin wait (chip_led[2]); $display("[%0.2f ms] chip LED2: firmware loaded", $realtime/1.0e6); end
    initial begin wait (chip_led[3]); $display("[%0.2f ms] chip LED3: BOOT OK",         $realtime/1.0e6); end
    initial begin wait (chip_led[5]); $display("[%0.2f ms] chip LED5: ADC",             $realtime/1.0e6); end
    initial begin wait (chip_led[6]); $display("[%0.2f ms] chip LED6: frame out",       $realtime/1.0e6); end
    initial begin wait (chip_led[7]); $display("[%0.2f ms] chip LED7: result in",       $realtime/1.0e6); end
    initial begin wait (chip_led[9]); $display("[%0.2f ms] chip LED9: result packet",   $realtime/1.0e6); end

    initial begin
        #(2_000_000_000);
        $display("\n==== TIMEOUT: driver never finished (fw_loaded=%0b, byte %0d) ====",
                 drv.fw_loaded, drv.u_host.b);
        $finish;
    end

    integer run_ms;
    initial begin
        wait (drv.startup_done);
        $display("[%0.2f ms] driver start-up done", $realtime/1.0e6);
        wait (drv.fw_loaded);
        $display("[%0.2f ms] driver finished sending firmware", $realtime/1.0e6);

        if (!$value$plusargs("RUN_MS=%d", run_ms)) run_ms = 300;
        #(run_ms * 1_000_000);

        $display("\n==== SYSTEM RESULTS ====");
        $display("  firmware sent             : %0d", drv.fw_loaded);
        $display("  chip ACK 0x06             : %0d", drv.ack_seen);
        $display("  BOOT OK                   : %0d", drv.boot_ok);
        $display("  result packets            : %0d", drv.packets);
        $display("  frames at fake CNN        : %0d", drv.frames);
        $display("  pixels in last frame      : %0d (256 = all)", drv.last_count);
        $display("  KICKOFF lost              : %0d", drv.kick_lost);
        $display("  pixel order errors        : %0d", drv.order_errors);
        $display("  HEX5-4 fps / HEX3-2 peak / HEX1-0 pos : %02h %02h %02h",
                 drv.show_fps, drv.show_peak, drv.show_pos);
        $display("  chip LEDs 9..0            : %b", chip_led);
        $display("  SPI reads by chip         : %0d", spi_reads);
        $display("  bytes on chip UART        : %0d", rx_count);
        $finish;
    end

endmodule
