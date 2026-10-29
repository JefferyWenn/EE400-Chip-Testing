// system_tb.sv
// Both boards in simulation: chip_fpga_top <-> driver_top, connected by
// named wires (each wire = one conductor of the cable between the boards).
// No PC: the driver loads the firmware itself. This testbench only
// listens to the chip's UART pin and prints what it sees.

`timescale 1ns/1ps

module system_tb;

    // ---- Board clock ----
    reg clock_50 = 0;
    always #10 clock_50 = ~clock_50;          // 50 MHz

    // ---- The cable between the two boards (chip pad names) ----
    wire [7:0] dn_data, up_data;
    wire [3:0] mux_row, mux_col;
    wire dn_clk, dn_valid, dn_token, scan_en, token_clk, spi_sclk, up_valid, up_clk;
    wire uart_rx, spi_miso, spi_cs_n, uart_tx, i2c_scl, i2c_sda;
    wire core_clk, hard_reset, scan_in, scan_out;
    pullup (i2c_scl);                          // like the driver's weak pull-ups
    pullup (i2c_sda);

    wire [9:0] chip_led;
    chip_fpga_top chip (
        .dn_data(dn_data), .dn_clk(dn_clk), .dn_valid(dn_valid), .dn_token(dn_token),
        .token_clk(token_clk), .up_valid(up_valid), .up_clk(up_clk), .up_data(up_data),
        .spi_sclk(spi_sclk), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        .mux_row(mux_row), .mux_col(mux_col),
        .core_clk(core_clk), .hard_reset(hard_reset),
        .scan_en(scan_en), .scan_in(scan_in), .scan_out(scan_out),
        .SW(10'h0), .LEDR(chip_led)
    );

    driver_top #(
        .FW_FILE("/home/jwen68/Projects/EE400-Chip-Testing/fpga/driver/firmware.hex")
    ) drv (
        .CLOCK_50(clock_50), .KEY(4'hF), .SW(10'h0), .LEDR(),
        .HEX0(), .HEX1(), .HEX2(), .HEX3(), .HEX4(), .HEX5(),
        .dn_data(dn_data), .dn_clk(dn_clk), .dn_valid(dn_valid), .dn_token(dn_token),
        .scan_en(scan_en), .token_clk(token_clk), .spi_sclk(spi_sclk),
        .up_valid(up_valid), .up_clk(up_clk), .up_data(up_data),
        .uart_rx(uart_rx), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n), .uart_tx(uart_tx),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .mux_row(mux_row), .mux_col(mux_col),
        .core_clk(core_clk), .hard_reset(hard_reset), .scan_in(scan_in), .scan_out(scan_out)
    );

    // ---- Listen to the chip's UART output (PAD 27) ----
    // Chip clock is 12.5 MHz, UART divider is 434 clocks -> 34.72 us per bit
    localparam real BIT_NS = 434 * 80.0;
    wire chip_tx = uart_tx;

    integer rx_count = 0;
    reg [7:0] rx_byte;
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

    // ---- Debug monitors ----
    integer spi_reads = 0;
    always @(negedge spi_cs_n) spi_reads = spi_reads + 1;          // chip CS_n falling
    integer flits = 0;
    always @(posedge drv.clk) if (drv.rx_valid) begin
        flits = flits + 1;
        if (drv.rx_data == 16'h0404 || drv.rx_data == 16'h0408)
            $display("[%0.2f ms] fake CNN got flit #%0d = 0x%04h",
                     $realtime/1.0e6, flits, drv.rx_data);
    end
    always @(posedge drv.clk) if (drv.tx_valid && drv.tx_ready && drv.u_cnn.idx == 0)
        $display("[%0.2f ms] fake CNN starts sending result", $realtime/1.0e6);

    // ---- Print when each chip-board LED first turns on ----
    initial begin wait (chip_led[0]); $display("[%0.2f ms] chip LED0 on: chip running",        $realtime/1.0e6); end
    initial begin wait (chip_led[2]); $display("[%0.2f ms] chip LED2 on: firmware loaded",     $realtime/1.0e6); end
    initial begin wait (chip_led[3]); $display("[%0.2f ms] chip LED3 on: BOOT OK",             $realtime/1.0e6); end
    initial begin wait (chip_led[4]); $display("[%0.2f ms] chip LED4 on: ADC being read",      $realtime/1.0e6); end
    initial begin wait (chip_led[5]); $display("[%0.2f ms] chip LED5 on: BSG sending",         $realtime/1.0e6); end
    initial begin wait (chip_led[6]); $display("[%0.2f ms] chip LED6 on: BSG receiving",       $realtime/1.0e6); end
    initial begin wait (chip_led[7]); $display("[%0.2f ms] chip LED7 on: UART output",         $realtime/1.0e6); end
    initial begin wait (chip_led[8]); $display("[%0.2f ms] chip LED8 on: result packet sent",  $realtime/1.0e6); end

    // ---- Safety timeout (simulated time) ----
    initial begin
        #(2_000_000_000);   // 2 s
        $display("\n==== TIMEOUT: driver never finished (fw_loaded=%0b, byte %0d) ====",
                 drv.fw_loaded, drv.u_host.b);
        $finish;
    end

    // ---- Main test ----
    initial begin
        wait (drv.startup_done);
        $display("[%0.2f ms] driver start-up done", $realtime/1.0e6);
        wait (drv.fw_loaded);
        $display("[%0.2f ms] driver finished sending firmware", $realtime/1.0e6);

        #(900_000_000);  // let it run 900 ms: many frames, display updates

        $display("\n==== CHIP BOARD LEDs (now) ====");
        $display("  LED0 running %0b | LED1 clock %0b | LED2 fw loaded %0b | LED3 BOOT OK %0b",
                 chip_led[0], chip_led[1], chip_led[2], chip_led[3]);
        $display("  LED8 result packet sent %0b", chip_led[8]);
        $display("\n==== SYSTEM RESULTS (driver LEDs / HEX) ====");
        $display("  LED4 firmware sent        : %0d", drv.fw_loaded);
        $display("  LED5 chip ACK 0x06        : %0d", drv.ack_seen);
        $display("  LED6 BOOT OK              : %0d", drv.boot_ok);
        $display("  LED7 result packets       : %0d", drv.packets);
        $display("  HEX5-4 fps                : %02h", drv.show_fps);
        $display("  HEX3   order errors       : %01h", drv.show_order);
        $display("  HEX2-0 fewest pixels      : %03h", drv.show_worst);
        $display("  LED2 frame %0b | LED3 all full %0b | LED7 packet %0b | LED8 kick lost %0b | LED9 short %0b",
                 drv.any_frame, drv.any_frame & ~drv.any_short, drv.any_packet, drv.any_kick, drv.any_short);
        $display("  frames at fake CNN        : %0d", drv.frames);
        $display("  pixels in last frame      : %0d (256 = all)", drv.last_count);
        $display("  KICKOFF lost              : %0d", drv.kick_lost);
        $display("  pixel order errors        : %0d", drv.order_errors);
        $display("  SPI reads by chip         : %0d", spi_reads);
        $display("  bytes on chip UART        : %0d", rx_count);
        $finish;
    end

endmodule
