// chip_leds.v
// Status LEDs for the chip board. It only watches the chip's pins
// (like a logic analyzer), so the chip RTL stays unchanged.

module chip_leds (
    input  wire       clk,         // core_clk (PAD 44)
    input  wire       reset,       // 1 = chip held in reset
    input  wire       uart_tx,     // PAD 27
    input  wire       spi_cs_n,    // PAD 26
    input  wire       up_valid,    // PAD 14 (chip -> CNN)
    input  wire       dn_valid,    // PAD 9  (CNN -> chip)
    output wire [9:0] led
);
    // ---- Bring pin signals into our clock ----
    reg [1:0] tx_s = 2'b11, cs_s = 2'b11, up_s = 2'b00, dn_s = 2'b00;
    always @(posedge clk) begin
        tx_s <= {tx_s[0], uart_tx};
        cs_s <= {cs_s[0], spi_cs_n};
        up_s <= {up_s[0], up_valid};
        dn_s <= {dn_s[0], dn_valid};
    end

    // ---- Activity LEDs: stay on ~0.1 s after each event ----
    reg [22:0] t_adc = 0, t_up = 0, t_dn = 0, t_tx = 0;   // ~0.17 s at 50 MHz
    always @(posedge clk) begin
        t_adc <= !cs_s[1] ? 23'h7FFFFF : (t_adc != 0 ? t_adc - 1'b1 : 23'd0);
        t_up  <=  up_s[1] ? 23'h7FFFFF : (t_up  != 0 ? t_up  - 1'b1 : 23'd0);
        t_dn  <=  dn_s[1] ? 23'h7FFFFF : (t_dn  != 0 ? t_dn  - 1'b1 : 23'd0);
        t_tx  <= !tx_s[1] ? 23'h7FFFFF : (t_tx  != 0 ? t_tx  - 1'b1 : 23'd0);
    end

    // ---- Read the chip's UART bytes (434 clocks per bit, like the chip) ----
    localparam CLKS_PER_BIT = 434;
    reg       busy = 0;
    reg [9:0] cnt  = 0;
    reg [3:0] n    = 0;
    reg [7:0] data = 0, prev = 0;
    reg       fw_loaded = 0, boot_ok = 0, packet = 0;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 0; fw_loaded <= 0; boot_ok <= 0; packet <= 0; prev <= 0;
        end else if (!busy) begin
            if (!tx_s[1]) begin busy <= 1; cnt <= CLKS_PER_BIT / 2; n <= 0; end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 0;
            if (n == 0) begin
                if (tx_s[1]) busy <= 0;          // false start
                n <= 1;
            end else if (n <= 8) begin
                data <= {tx_s[1], data[7:1]};    // LSB first
                n <= n + 1'b1;
            end else begin                       // byte done
                busy <= 0;
                if (data == 8'h06)               fw_loaded <= 1;
                if (prev == "O" && data == "K")  boot_ok   <= 1;
                if (data == 8'hB0)               packet    <= 1;
                prev <= data;
            end
        end else
            cnt <= cnt + 1'b1;
    end

    // ---- Clock blink ----
    reg [24:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;

    // Same order as the driver board's LEDs, step by step
    assign led[0] = ~reset;          // on = chip running
    assign led[1] = blink[24];       // toggles = clock arriving
    assign led[2] = fw_loaded;       // firmware loaded (0x06 ACK)
    assign led[3] = boot_ok;         // "BOOT OK" sent
    assign led[4] = 1'b0;            // I2C write seen (fullsys_top fills it in)
    assign led[5] = (t_adc != 0);    // ADC being read
    assign led[6] = (t_up  != 0);    // link sending (frame out)
    assign led[7] = (t_dn  != 0);    // link receiving (result in)
    assign led[8] = (t_tx  != 0);    // UART sending
    assign led[9] = packet;          // result packet 0xB0 sent
endmodule
