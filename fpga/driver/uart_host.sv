// Sends the firmware to the chip over UART and listens for its replies.
// Sends: AA 55, then 256 x [address][instruction], then FF FF FF FF.
// Listens for: 0x06 (ACK), "BOOT OK", 0xB0 (result packet).

module uart_host #(
    parameter FW_FILE      = "firmware.hex",
    parameter CLKS_PER_BIT = 434              // same as the chip, 115200 baud at 50 MHz
)(
    input  logic       clk,
    input  logic       reset,
    input  logic       start,
    output logic       tx = 1'b1,
    input  logic       rx,
    output logic       loaded = 0,
    output logic       ack_seen = 0,
    output logic       boot_ok = 0,
    output logic [7:0] packets = 0
);

    logic [31:0] rom [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) rom[i] = 32'h0;
        $readmemh(FW_FILE, rom);
    end

    // b = which byte we're on (0..2057)
    logic [11:0] b = 0;
    logic [11:0] k;
    logic [7:0]  w;
    logic [2:0]  part;
    assign k    = b - 12'd2;
    assign w    = k[10:3];
    assign part = k[2:0];

    logic [31:0] word;
    always @(posedge clk) word <= rom[w];

    logic [31:0] addr32;
    logic [7:0]  next_byte;
    assign addr32 = {24'b0, w};
    assign next_byte =
        (b == 0)    ? 8'hAA :
        (b == 1)    ? 8'h55 :
        (b < 2050)  ? (part < 4 ? addr32[8*(3-part[1:0]) +: 8]
                                : word  [8*(3-part[1:0]) +: 8]) :
        (b < 2054)  ? 8'hFF :
        (b == 2054) ? 8'hDE : (b == 2055) ? 8'hAD :
        (b == 2056) ? 8'hBE : 8'hEF;

    // send
    logic [19:0] wait_cnt = 0;
    logic [9:0]  shift = 10'h3FF;
    logic [3:0]  bits_left = 0;
    logic [8:0]  bit_cnt = 0;
    logic [1:0]  gap = 0;

    always @(posedge clk) begin
        if (reset) begin
            tx <= 1'b1; b <= 0; loaded <= 0; wait_cnt <= 0;
            bits_left <= 0; bit_cnt <= 0; gap <= 0;
        end else if (!start || loaded) begin
            tx <= 1'b1;
        end else if (wait_cnt < 20'd65535) begin
            wait_cnt <= wait_cnt + 1'b1;
        end else if (bits_left == 0) begin
            // give the ROM a few clocks before the next byte
            if (gap != 2'd3) gap <= gap + 1'b1;
            else begin
                shift     <= {1'b1, next_byte, 1'b0};
                bits_left <= 4'd10;
                bit_cnt   <= 0;
                gap       <= 0;
            end
        end else begin
            tx <= shift[0];
            if (bit_cnt == CLKS_PER_BIT - 1) begin
                bit_cnt   <= 0;
                shift     <= {1'b1, shift[9:1]};
                bits_left <= bits_left - 1'b1;
                if (bits_left == 1) begin
                    if (b == 12'd2057) loaded <= 1'b1;
                    else               b <= b + 1'b1;
                end
            end else
                bit_cnt <= bit_cnt + 1'b1;
        end
    end

    // receive
    logic [1:0] rx_s = 2'b11;
    always @(posedge clk) rx_s <= {rx_s[0], rx};

    logic       busy = 0;
    logic [9:0] cnt = 0;
    logic [3:0] n = 0;
    logic [7:0] data = 0, prev = 0;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 0; ack_seen <= 0; boot_ok <= 0; packets <= 0; prev <= 0;
        end else if (!busy) begin
            if (!rx_s[1]) begin
                busy <= 1; cnt <= CLKS_PER_BIT / 2; n <= 0;
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 0;
            if (n == 0) begin
                if (rx_s[1]) busy <= 0;
                n <= 1;
            end else if (n <= 8) begin
                data <= {rx_s[1], data[7:1]};
                n <= n + 1'b1;
            end else begin
                busy <= 0;
                if (data == 8'h06)                    ack_seen <= 1;
                if (prev == "O" && data == "K")       boot_ok  <= 1;
                if (data == 8'hB0)                    packets  <= packets + 1'b1;
                prev <= data;
            end
        end else
            cnt <= cnt + 1'b1;
    end
endmodule
