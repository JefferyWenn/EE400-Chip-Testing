// -----------------------------------------------------------------------
// top.v — student-editable SoC instance.
//
// Two paths can write the 297-bit BLE config register `cfg_regs`:
//
//   (A) SPI: 298-bit transactions land in spi_reg_out. Bit 297 is the
//       enable flag — when high, cfg_regs follows spi_reg_out[296:0]
//       continuously (level-driven, like the original SW3 switch).
//
//   (B) bsg_link RX: a 10-word streaming write fills link_cfg_buffer
//       (10 * 32 = 320 bits). On every 10th word the chip latches the
//       low 297 bits of the buffer into a sticky `link_cfg_sticky`
//       register and asserts `link_cfg_active`. bsg_link writes are
//       OR'd in below SPI (SPI's enable bit is the override).
//
// Status output: `link_tx_data_o` continuously offers a 32-bit status
// word back to the FPGA (header + counters + BLE state).
// -----------------------------------------------------------------------
module top (
    input  wire        CLK,           // core_clk (16 MHz)
    input  wire        hard_reset,    // active high

    // SPI (config write path A)
    input  wire        SCLK,
    input  wire        MOSI,
    output wire        MISO,
    input  wire        SS_n,

    // bsg_link (config write path B + status return)
    input  wire [31:0] link_rx_data_i,
    input  wire        link_rx_valid_i,
    output wire        link_rx_yumi_o,
    output wire [31:0] link_tx_data_o,
    output wire        link_tx_valid_o,
    input  wire        link_tx_ready_i,

    // BLE modulator output
    output wire        PIN_18
);

    // ----- Clock + sync reset -----
    wire clk_pll_buff;
    wire hard_reset_sync;
    assign clk_pll_buff = CLK;

    async_rst_sync_deassert hard_reset_sync_inst (
        .clk                    (clk_pll_buff),
        .rst                    (hard_reset),
        .async_rst_sync_deassert(hard_reset_sync)
    );

    // ----- BLE config register (declared early; written by SPI or bsg_link) -----
    reg [296:0] cfg_regs;

    // ----- Built-in default config (used at reset) -----
    wire [296:0] builtin_regs;
    assign builtin_regs = {
        1'b1,                                                                // transmit_enable
        232'h556B7D9171F283FAA738052E25EE0C2882F96C2951A431D10F7D5F2EC2,     // packet_in
        8'd1,                                                                // clk_div
        8'd48,                                                               // clk_total
        16'd11136,                                                           // pulses
        8'd6,                                                                // clk_div0
        8'd12,                                                               // clk_total0
        8'd8,                                                                // clk_div1
        8'd16                                                                // clk_total1
    };

    // ----- SPI config-write path -----
    // Bit 297 of the 298-bit shift register acts as the "enable cfg load"
    // flag. The SPI master writes [enable_bit, cfg_regs[296:0]] in one
    // 298-bit transaction. While enable_bit is held high, cfg_regs follows
    // the latest spi_reg_out[296:0].
    wire [297:0] spi_reg_out;
    wire         spi_reg_enable = spi_reg_out[297];

    spi_slave spi_inst (
        .SCLK    (SCLK),
        .MOSI    (MOSI),
        .MISO    (MISO),
        .SS_n    (SS_n),
        .clk     (clk_pll_buff),
        .rst_n   (~hard_reset_sync),
        .reg_in  ({spi_reg_enable, cfg_regs}),
        .reg_out (spi_reg_out)
    );

    // ----- bsg_link config-write path -----
    // Receive 10 32-bit words; on the cycle AFTER the 10th, latch the
    // low 297 bits of the accumulated buffer into a sticky register.
    // After the first commit, link_cfg_active stays high until reset.
    localparam integer LINK_CFG_WORDS = 10;
    reg [3:0]    link_word_idx;
    reg [319:0]  link_cfg_buffer;
    reg [296:0]  link_cfg_sticky;
    reg          link_cfg_active;
    reg          link_cfg_commit_pending;
    reg [31:0]   rx_word_count;
    reg [31:0]   rx_last_word;

    // Always consume incoming bsg_link words (no backpressure in this demo).
    assign link_rx_yumi_o = link_rx_valid_i;

    // Stage 1: accumulate words into the 320-bit buffer.
    always @(posedge clk_pll_buff) begin
        if (hard_reset_sync) begin
            link_word_idx           <= 4'd0;
            link_cfg_buffer         <= 320'd0;
            link_cfg_commit_pending <= 1'b0;
            rx_word_count           <= 32'd0;
            rx_last_word            <= 32'd0;
        end else begin
            link_cfg_commit_pending <= 1'b0;
            if (link_rx_valid_i) begin
                link_cfg_buffer[link_word_idx*32 +: 32] <= link_rx_data_i;
                rx_word_count <= rx_word_count + 32'd1;
                rx_last_word  <= link_rx_data_i;
                if (link_word_idx == LINK_CFG_WORDS-1) begin
                    link_word_idx           <= 4'd0;
                    link_cfg_commit_pending <= 1'b1;
                end else begin
                    link_word_idx <= link_word_idx + 4'd1;
                end
            end
        end
    end

    // Stage 2: one cycle after the 10th word, commit the buffer to sticky.
    always @(posedge clk_pll_buff) begin
        if (hard_reset_sync) begin
            link_cfg_sticky <= 297'd0;
            link_cfg_active <= 1'b0;
        end else if (link_cfg_commit_pending) begin
            link_cfg_sticky <= link_cfg_buffer[296:0];
            link_cfg_active <= 1'b1;
        end
    end

    // ----- Mux config sources into cfg_regs -----
    // Priority: SPI (when enable bit set) > bsg_link sticky > builtin.
    always @(posedge clk_pll_buff) begin
        if (hard_reset_sync) begin
            cfg_regs <= builtin_regs;
        end else if (spi_reg_enable) begin
            cfg_regs <= spi_reg_out[296:0];
        end else if (link_cfg_active) begin
            cfg_regs <= link_cfg_sticky;
        end else begin
            cfg_regs <= builtin_regs;
        end
    end

    // ----- Decode cfg_regs into named fields -----
    wire transmit_enable;
    wire [231:0] packet_in;
    wire [7:0]   clk_div, clk_total;
    wire [15:0]  pulses;
    wire [7:0]   clk_div0, clk_total0, clk_div1, clk_total1;

    assign {transmit_enable, packet_in,
            clk_div, clk_total, pulses,
            clk_div0, clk_total0,
            clk_div1, clk_total1} = cfg_regs[296:0];

    wire enable_n = ~(transmit_enable & ~hard_reset_sync);

    // ----- BLE waveform generation chain -----
    wire bitclock;
    wire din;
    wire packetenable_n;
    wire modsignal;

    squarewave onembps (
        .clk      (clk_pll_buff),
        .rst      (enable_n),
        .enable   (bitclock),
        .pwmSig   (packetenable_n),
        .CLK_DIV  (clk_div),
        .CLK_TOTAL(clk_total),
        .PULSES   (pulses)
    );

    BLEpacket enable_inst (
        .clk      (clk_pll_buff),
        .rst      (enable_n),
        .enable   (bitclock),
        .dout     (din),
        .packet_in(packet_in)
    );

    squarewavemod datamodulate (
        .clk       (clk_pll_buff),
        .rst       (packetenable_n),
        .din       (din),
        .enable    (modsignal),
        .CLK_DIV0  (clk_div0),
        .CLK_TOTAL0(clk_total0),
        .CLK_DIV1  (clk_div1),
        .CLK_TOTAL1(clk_total1)
    );

    assign PIN_18 = modsignal;

    // ----- bsg_link TX status return -----
    // Emit a 32-bit status word back to the FPGA on every cycle the link
    // is ready. Format: {magic[7:0]=5A, tx_counter[7:0], rx_word_count[7:0],
    // hard_reset_sync, modsignal, din, packetenable_n, link_cfg_active,
    // spi_reg_enable, transmit_enable, 1'b0}.
    reg [31:0] tx_counter_r;
    always @(posedge clk_pll_buff) begin
        if (hard_reset_sync) begin
            tx_counter_r <= 32'd0;
        end else if (link_tx_ready_i) begin
            tx_counter_r <= tx_counter_r + 32'd1;
        end
    end

    assign link_tx_valid_o = ~hard_reset_sync;
    assign link_tx_data_o  = {
        8'h5A,
        tx_counter_r[7:0],
        rx_word_count[7:0],
        hard_reset_sync,
        modsignal,
        din,
        packetenable_n,
        link_cfg_active,
        spi_reg_enable,
        transmit_enable,
        1'b0
    };

endmodule

