// Chip status LEDs. Only watches the chip's pins, so the chip stays unchanged.

module chip_leds (
    input  logic       clk,
    input  logic       reset,
    input  logic       uart_tx,
    input  logic       spi_cs_n,
    input  logic       up_valid,
    input  logic       dn_valid,
    output logic [9:0] led
);
    logic [1:0] tx_s = 2'b11, cs_s = 2'b11, up_s = 2'b00, dn_s = 2'b00;
    always @(posedge clk) begin
        tx_s <= {tx_s[0], uart_tx};
        cs_s <= {cs_s[0], spi_cs_n};
        up_s <= {up_s[0], up_valid};
        dn_s <= {dn_s[0], dn_valid};
    end

    // keep a LED on for a moment after each event so you can see it
    logic [22:0] t_adc = 0, t_up = 0, t_dn = 0, t_tx = 0;
    always @(posedge clk) begin
        t_adc <= !cs_s[1] ? 23'h7FFFFF : (t_adc != 0 ? t_adc - 1'b1 : 23'd0);
        t_up  <=  up_s[1] ? 23'h7FFFFF : (t_up  != 0 ? t_up  - 1'b1 : 23'd0);
        t_dn  <=  dn_s[1] ? 23'h7FFFFF : (t_dn  != 0 ? t_dn  - 1'b1 : 23'd0);
        t_tx  <= !tx_s[1] ? 23'h7FFFFF : (t_tx  != 0 ? t_tx  - 1'b1 : 23'd0);
    end

    // read what the chip prints on UART
    localparam CLKS_PER_BIT = 434;
    logic       busy = 0;
    logic [9:0] cnt  = 0;
    logic [3:0] n    = 0;
    logic [7:0] data = 0, prev = 0;
    logic       fw_loaded = 0, boot_ok = 0, packet = 0;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 0; fw_loaded <= 0; boot_ok <= 0; packet <= 0; prev <= 0;
        end else if (!busy) begin
            if (!tx_s[1]) begin busy <= 1; cnt <= CLKS_PER_BIT / 2; n <= 0; end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 0;
            if (n == 0) begin
                if (tx_s[1]) busy <= 0;
                n <= 1;
            end else if (n <= 8) begin
                data <= {tx_s[1], data[7:1]};
                n <= n + 1'b1;
            end else begin
                busy <= 0;
                if (data == 8'h06)               fw_loaded <= 1;
                if (prev == "O" && data == "K")  boot_ok   <= 1;
                if (data == 8'hB0)               packet    <= 1;
                prev <= data;
            end
        end else
            cnt <= cnt + 1'b1;
    end

    logic [24:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;

    // same order as the driver's LEDs
    assign led[0] = ~reset;          // running
    assign led[1] = blink[24];       // clock
    assign led[2] = fw_loaded;       // firmware loaded
    assign led[3] = boot_ok;         // BOOT OK
    assign led[4] = 1'b0;            // I2C (set in fullsys_top)
    assign led[5] = (t_adc != 0);    // ADC
    assign led[6] = (t_up  != 0);    // frame out
    assign led[7] = (t_dn  != 0);    // result in
    assign led[8] = (t_tx  != 0);    // UART out
    assign led[9] = packet;          // result packet
endmodule
