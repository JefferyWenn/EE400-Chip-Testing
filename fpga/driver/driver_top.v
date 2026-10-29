// driver_top.v
// Top level for FPGA B (the "test driver" board, DE1-SoC).
// It plays everything around the chip: clock, reset, firmware loading
// over UART (no PC needed), ADC, CNN chip.
//
// Pin names are the CHIP's pad names, and driver.qsf puts each one on the
// same header pin as on the chip board, so a straight cable connects them.
// Directions below are from the driver's view (opposite of the chip).
//
// Firmware: firmware.hex in this folder is built into the FPGA and sent
// to the chip over UART after start-up.
//
// Board controls:
//   SW0 up = hold everything in reset, down = run
//   SW1 up = send the firmware (once sending starts it finishes;
//            SW0 / KEY0 restart clears it)
//   KEY0 = restart (reset chip + link, load firmware again)
//   LEDR0 system running, LEDR1 clock running, LEDR2 a frame arrived,
//   LEDR3 every frame had all 256 pixels, LEDR4 firmware sent,
//   LEDR5 chip ACK (0x06), LEDR6 BOOT OK, LEDR7 result packet came back,
//   LEDR8 a KICKOFF was lost, LEDR9 a frame was short
//   (LEDR2-3 and 7-9 stay on until reset)
//   HEX5-4 = frames per second, HEX3-2 = strongest pixel in the last
//   frame (00-FF), HEX1-0 = where it is (row, column, 0-F each)
//   HEX values refresh twice per second (all numbers in hex)

module driver_top #(
    parameter FW_FILE = "firmware.hex"
)(
    // ---- Board ----
    input  wire       CLOCK_50,
    input  wire [3:0] KEY,
    input  wire [9:0] SW,
    output wire [9:0] LEDR,
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,

    // ---- To / from the chip board (chip pad names) ----
    output wire [7:0] dn_data,     // PAD 0-7   link data into chip
    output wire       dn_clk,      // PAD 8
    output wire       dn_valid,    // PAD 9
    input  wire       dn_token,    // PAD 10    credits back from chip
    output wire       scan_en,     // PAD 11    must be 0
    output wire       token_clk,   // PAD 12    credits to chip
    input  wire       spi_sclk,    // PAD 13
    input  wire       up_valid,    // PAD 14    link out of chip
    input  wire       up_clk,      // PAD 15
    input  wire [7:0] up_data,     // PAD 16-23
    output wire       uart_rx,     // PAD 24    firmware into chip
    output wire       spi_miso,    // PAD 25
    input  wire       spi_cs_n,    // PAD 26
    input  wire       uart_tx,     // PAD 27    chip's UART output
    input  wire       i2c_scl,     // PAD 28    (only pulled up)
    input  wire       i2c_sda,     // PAD 29    (only pulled up)
    input  wire [3:0] mux_row,     // PAD 36-39
    input  wire [3:0] mux_col,     // PAD 40-43
    output wire       core_clk,    // PAD 44
    output wire       hard_reset,  // PAD 45    1 = chip in reset
    output wire       scan_in,     // PAD 46
    input  wire       scan_out     // PAD 47    (not used)
);

    // ---- Clock: 50 MHz / 4 = 12.5 MHz (chip UART is then 28800 baud) ----
    reg [1:0] div = 2'd0;
    always @(posedge CLOCK_50) div <= div + 1'b1;
    wire clk = div[1];

    // ---- Reset: SW0 up (hold) or KEY0 pressed (restart) ----
    reg [1:0] key_s = 2'b11;
    reg [1:0] sw_s  = 2'b00;
    reg [1:0] sw1_s = 2'b00;
    always @(posedge clk) begin
        key_s <= {key_s[0], KEY[0]};
        sw_s  <= {sw_s[0],  SW[0]};
        sw1_s <= {sw1_s[0], SW[1]};
    end
    wire restart = ~key_s[1] | sw_s[1];   // 1 = reset everything
    wire freeze  = 1'b0;                  // HEX always updates

    // ---- SW1: send firmware. Once flipped up, stays "go" until restart ----
    reg fw_go = 1'b0;
    always @(posedge clk) begin
        if (restart)       fw_go <= 1'b0;
        else if (sw1_s[1]) fw_go <= 1'b1;
    end

    // ---- Start-up sequence ----
    wire tx_token_reset, tx_io_reset, rx_io_reset, core_reset, startup_done;
    reset_seq u_rst (
        .clk(clk), .restart(restart),
        .hard_reset(hard_reset), .tx_token_reset(tx_token_reset),
        .tx_io_reset(tx_io_reset), .rx_io_reset(rx_io_reset),
        .core_reset(core_reset), .done(startup_done)
    );

    // ---- Link to the chip (same BaseJump link as the testbench) ----
    wire [15:0] tx_data, rx_data;
    wire        tx_valid, tx_ready, rx_valid;

    bsg_link_ddr_upstream #(.width_p(16), .channel_width_p(8), .num_channels_p(1), .lg_fifo_depth_p(6)) u_tx (
        .core_clk_i(clk), .core_link_reset_i(core_reset),
        .core_data_i(tx_data), .core_valid_i(tx_valid), .core_ready_o(tx_ready),
        .io_clk_i(clk), .io_link_reset_i(tx_io_reset), .async_token_reset_i(tx_token_reset),
        .io_clk_r_o(dn_clk), .io_data_r_o(dn_data), .io_valid_r_o(dn_valid),
        .token_clk_i(dn_token)
    );

    wire rx_io_reset_sync;
    bsg_sync_sync #(.width_p(1)) u_rx_rst_sync (
        .oclk_i(up_clk), .iclk_data_i(rx_io_reset), .oclk_data_o(rx_io_reset_sync)
    );

    bsg_link_ddr_downstream #(.width_p(16), .channel_width_p(8), .num_channels_p(1), .lg_fifo_depth_p(6)) u_rx (
        .core_clk_i(clk), .core_link_reset_i(core_reset), .io_link_reset_i(rx_io_reset_sync),
        .core_data_o(rx_data), .core_valid_o(rx_valid), .core_yumi_i(rx_valid),  // always accept
        .io_clk_i(up_clk), .io_data_i(up_data), .io_valid_i(up_valid),
        .core_token_r_o(token_clk)
    );

    // ---- Fake CNN chip ----
    wire [7:0] frames, order_errors, kick_lost;
    wire [8:0] last_count;
    wire [7:0] peak_val, peak_pos;
    fake_cnn u_cnn (
        .clk(clk), .reset(core_reset),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .frames(frames), .last_count(last_count), .order_errors(order_errors),
        .kick_lost(kick_lost), .peak_val(peak_val), .peak_pos(peak_pos)
    );

    // ---- Firmware loader / UART listener (plays the PC) ----
    wire fw_loaded, ack_seen, boot_ok;
    wire [7:0] packets;
    uart_host #(.FW_FILE(FW_FILE)) u_host (
        .clk(clk), .reset(restart), .start(startup_done & fw_go),
        .tx(uart_rx), .rx(uart_tx),
        .loaded(fw_loaded), .ack_seen(ack_seen), .boot_ok(boot_ok), .packets(packets)
    );

    // ---- Fake ADC ----
    fake_adc u_adc (
        .clk(clk), .sclk(spi_sclk), .cs_n(spi_cs_n),
        .row(mux_row), .col(mux_col), .miso(spi_miso)
    );

    // ---- Other signals to the chip ----
    assign core_clk = clk;
    assign scan_en  = 1'b0;
    assign scan_in  = 1'b0;

    // ---- Steady values for LEDs / HEX ----
    wire [7:0] show_fps;
    wire [7:0] show_peak, show_pos;
    wire any_frame, any_short, any_kick, any_packet;
    status u_status (
        .clk(clk), .reset(restart), .freeze(freeze),
        .frames(frames), .last_count(last_count), .order_errors(order_errors),
        .kick_lost(kick_lost), .packets(packets),
        .peak_val(peak_val), .peak_pos(peak_pos),
        .show_fps(show_fps), .show_peak(show_peak), .show_pos(show_pos),
        .any_frame(any_frame), .any_short(any_short), .any_kick(any_kick),
        .any_packet(any_packet)
    );

    // ---- LEDs ----
    reg [22:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;

    assign LEDR[0] = startup_done & ~restart;   // system running
    assign LEDR[1] = blink[22];                 // clock running
    assign LEDR[2] = any_frame;                 // a frame arrived
    assign LEDR[3] = any_frame & ~any_short;    // every frame complete
    assign LEDR[4] = fw_loaded;                 // firmware sent
    assign LEDR[5] = ack_seen;                  // chip ACK 0x06
    assign LEDR[6] = boot_ok;                   // BOOT OK
    assign LEDR[7] = any_packet;                // result packet came back
    assign LEDR[8] = any_kick;                  // a KICKOFF was lost
    assign LEDR[9] = any_short;                 // a frame was short

    // ---- HEX displays ----
    hex7seg h0 (.d(show_pos[3:0]),  .seg(HEX0));   // column
    hex7seg h1 (.d(show_pos[7:4]),  .seg(HEX1));   // row
    hex7seg h2 (.d(show_peak[3:0]), .seg(HEX2));   // strongest pixel
    hex7seg h3 (.d(show_peak[7:4]), .seg(HEX3));
    hex7seg h4 (.d(show_fps[3:0]),  .seg(HEX4));   // frames per second
    hex7seg h5 (.d(show_fps[7:4]),  .seg(HEX5));

endmodule
