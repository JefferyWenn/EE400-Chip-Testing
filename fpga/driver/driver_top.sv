// Test driver: everything around the chip.
// Makes the clock and reset, sends the firmware over UART, acts as the CNN chip,
// and shows status on the LEDs and HEX.
//
// SW0 up = reset, SW1 up = send firmware, KEY0 = restart
// HEX5-4 = fps, HEX3-2 = strongest press, HEX1-0 = its row and column

module driver_top #(
    parameter FW_FILE = "firmware.hex"
)(
    input  logic       CLOCK_50,
    input  logic [3:0] KEY,
    input  logic [9:0] SW,
    output logic [9:0] LEDR,
    output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,

    // chip pins (named like the chip pads)
    output logic [7:0] dn_data,     // PAD 0-7
    output logic       dn_clk,      // PAD 8
    output logic       dn_valid,    // PAD 9
    input  logic       dn_token,    // PAD 10
    output logic       scan_en,     // PAD 11, must be 0
    output logic       token_clk,   // PAD 12
    input  logic       spi_sclk,    // PAD 13
    input  logic       up_valid,    // PAD 14
    input  logic       up_clk,      // PAD 15
    input  logic [7:0] up_data,     // PAD 16-23
    output logic       uart_rx,     // PAD 24
    output logic       spi_miso,    // PAD 25
    input  logic       spi_cs_n,    // PAD 26
    input  logic       uart_tx,     // PAD 27
    input  logic       i2c_scl,     // PAD 28
    input  logic       i2c_sda,     // PAD 29
    input  logic [3:0] mux_row,     // PAD 36-39
    input  logic [3:0] mux_col,     // PAD 40-43
    output logic       core_clk,    // PAD 44
    output logic       hard_reset,  // PAD 45, 1 = reset
    output logic       scan_in,     // PAD 46
    input  logic       scan_out     // PAD 47
);

    logic clk;
    assign clk = CLOCK_50;

    logic [1:0] key_s = 2'b11;
    logic [1:0] sw_s  = 2'b00;
    logic [1:0] sw1_s = 2'b00;
    always @(posedge clk) begin
        key_s <= {key_s[0], KEY[0]};
        sw_s  <= {sw_s[0],  SW[0]};
        sw1_s <= {sw1_s[0], SW[1]};
    end
    logic restart, freeze;
    assign restart = ~key_s[1] | sw_s[1];
    assign freeze  = 1'b0;

    // once SW1 goes up, keep sending until the next reset
    logic fw_go = 1'b0;
    always @(posedge clk) begin
        if (restart)       fw_go <= 1'b0;
        else if (sw1_s[1]) fw_go <= 1'b1;
    end

    logic tx_token_reset, tx_io_reset, rx_io_reset, core_reset, startup_done;
    reset_seq u_rst (
        .clk(clk), .restart(restart),
        .hard_reset(hard_reset), .tx_token_reset(tx_token_reset),
        .tx_io_reset(tx_io_reset), .rx_io_reset(rx_io_reset),
        .core_reset(core_reset), .done(startup_done)
    );

    // link to the chip
    logic [15:0] tx_data, rx_data;
    logic        tx_valid, tx_ready, rx_valid;

    bsg_link_ddr_upstream #(.width_p(16), .channel_width_p(8), .num_channels_p(1), .lg_fifo_depth_p(6)) u_tx (
        .core_clk_i(clk), .core_link_reset_i(core_reset),
        .core_data_i(tx_data), .core_valid_i(tx_valid), .core_ready_o(tx_ready),
        .io_clk_i(clk), .io_link_reset_i(tx_io_reset), .async_token_reset_i(tx_token_reset),
        .io_clk_r_o(dn_clk), .io_data_r_o(dn_data), .io_valid_r_o(dn_valid),
        .token_clk_i(dn_token)
    );

    logic rx_io_reset_sync;
    bsg_sync_sync #(.width_p(1)) u_rx_rst_sync (
        .oclk_i(up_clk), .iclk_data_i(rx_io_reset), .oclk_data_o(rx_io_reset_sync)
    );

    bsg_link_ddr_downstream #(.width_p(16), .channel_width_p(8), .num_channels_p(1), .lg_fifo_depth_p(6)) u_rx (
        .core_clk_i(clk), .core_link_reset_i(core_reset), .io_link_reset_i(rx_io_reset_sync),
        .core_data_o(rx_data), .core_valid_o(rx_valid), .core_yumi_i(rx_valid),
        .io_clk_i(up_clk), .io_data_i(up_data), .io_valid_i(up_valid),
        .core_token_r_o(token_clk)
    );

    logic [7:0] frames, order_errors, kick_lost;
    logic [8:0] last_count;
    logic [7:0] peak_val, peak_pos;
    fake_cnn u_cnn (
        .clk(clk), .reset(core_reset),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .frames(frames), .last_count(last_count), .order_errors(order_errors),
        .kick_lost(kick_lost), .peak_val(peak_val), .peak_pos(peak_pos)
    );

    logic fw_loaded, ack_seen, boot_ok;
    logic [7:0] packets;
    uart_host #(.FW_FILE(FW_FILE)) u_host (
        .clk(clk), .reset(restart), .start(startup_done & fw_go),
        .tx(uart_rx), .rx(uart_tx),
        .loaded(fw_loaded), .ack_seen(ack_seen), .boot_ok(boot_ok), .packets(packets)
    );

    // only used on the two-board setup
    fake_adc u_adc (
        .clk(clk), .sclk(spi_sclk), .cs_n(spi_cs_n),
        .row(mux_row), .col(mux_col), .miso(spi_miso)
    );

    assign core_clk = clk;
    assign scan_en  = 1'b0;
    assign scan_in  = 1'b0;

    logic [7:0] show_fps;
    logic [7:0] show_peak, show_pos;
    logic any_frame, any_short, any_kick, any_packet;
    status u_status (
        .clk(clk), .reset(restart), .freeze(freeze),
        .frames(frames), .last_count(last_count), .order_errors(order_errors),
        .kick_lost(kick_lost), .packets(packets),
        .peak_val(peak_val), .peak_pos(peak_pos),
        .show_fps(show_fps), .show_peak(show_peak), .show_pos(show_pos),
        .any_frame(any_frame), .any_short(any_short), .any_kick(any_kick),
        .any_packet(any_packet)
    );

    logic [24:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;

    // keep a LED on for a moment after each event so you can see it
    logic [1:0]  utx_s = 2'b11;
    logic [22:0] t_rx = 0, t_tx = 0, t_uart = 0;
    always @(posedge clk) begin
        utx_s  <= {utx_s[0], uart_tx};
        t_rx   <= rx_valid              ? 23'h7FFFFF : (t_rx   != 0 ? t_rx   - 1'b1 : 23'd0);
        t_tx   <= (tx_valid & tx_ready) ? 23'h7FFFFF : (t_tx   != 0 ? t_tx   - 1'b1 : 23'd0);
        t_uart <= !utx_s[1]             ? 23'h7FFFFF : (t_uart != 0 ? t_uart - 1'b1 : 23'd0);
    end

    // same order as the chip's LEDs
    assign LEDR[0] = startup_done & ~restart;   // running
    assign LEDR[1] = blink[24];                 // clock
    assign LEDR[2] = fw_loaded;                 // firmware sent
    assign LEDR[3] = boot_ok;                   // BOOT OK
    assign LEDR[4] = 1'b0;                      // I2C (set in fullsys_top)
    assign LEDR[5] = any_frame & ~any_short;    // all 256 pixels
    assign LEDR[6] = (t_rx   != 0);             // frame in
    assign LEDR[7] = (t_tx   != 0);             // result out
    assign LEDR[8] = (t_uart != 0);             // UART in
    assign LEDR[9] = any_packet;                // result packet

    hex7seg h0 (.d(show_pos[3:0]),  .seg(HEX0));
    hex7seg h1 (.d(show_pos[7:4]),  .seg(HEX1));
    hex7seg h2 (.d(show_peak[3:0]), .seg(HEX2));
    hex7seg h3 (.d(show_peak[7:4]), .seg(HEX3));
    hex7seg h4 (.d(show_fps[3:0]),  .seg(HEX4));
    hex7seg h5 (.d(show_fps[7:4]),  .seg(HEX5));

endmodule
