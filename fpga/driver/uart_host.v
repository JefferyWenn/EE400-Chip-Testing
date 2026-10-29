// uart_host.v
// Plays the PC: loads the chip's firmware over UART and listens to its replies.
//
// Send (after "start" + a short wait):
//   AA 55, then for word 0..255: [address 4 bytes][instruction 4 bytes],
//   then FF FF FF FF + 4 dummy bytes  (the chip's firmware_loader protocol)
// Listen:
//   0x06 = load ACK, "OK" = end of "BOOT OK", 0xB0 = start of a result packet

module uart_host #(
    parameter FW_FILE      = "firmware.hex",  // one 32-bit hex word per line
    parameter CLKS_PER_BIT = 434              // same divider as the chip's UART
)(
    input  wire       clk,
    input  wire       reset,       // 1 = start over
    input  wire       start,       // 1 = chip is ready, begin loading
    output reg        tx = 1'b1,   // to chip UART RX (PAD 24)
    input  wire       rx,          // from chip UART TX (PAD 27)
    output reg        loaded = 0,  // all bytes sent
    output reg        ack_seen = 0,// got 0x06
    output reg        boot_ok = 0, // got "BOOT OK"
    output reg  [7:0] packets = 0  // number of 0xB0 bytes seen
);

    // ---------------- Firmware image (on-chip ROM) ----------------
    reg [31:0] rom [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) rom[i] = 32'h0;
        $readmemh(FW_FILE, rom);
    end

    // Which byte we are sending: 0..2057
    //   0-1: AA 55 | 2-2049: 256 words x 8 bytes | 2050-2057: FFFFFFFF DEADBEEF
    reg [11:0] b = 0;
    wire [11:0] k    = b - 12'd2;
    wire [7:0]  w    = k[10:3];        // word number
    wire [2:0]  part = k[2:0];         // byte inside [addr][data]

    reg [31:0] word;
    always @(posedge clk) word <= rom[w];

    wire [31:0] addr32 = {24'b0, w};
    wire [7:0] next_byte =
        (b == 0)    ? 8'hAA :
        (b == 1)    ? 8'h55 :
        (b < 2050)  ? (part < 4 ? addr32[8*(3-part[1:0]) +: 8]
                                : word  [8*(3-part[1:0]) +: 8]) :
        (b < 2054)  ? 8'hFF :
        (b == 2054) ? 8'hDE : (b == 2055) ? 8'hAD :
        (b == 2056) ? 8'hBE : 8'hEF;

    // ---------------- Sender ----------------
    reg [19:0] wait_cnt = 0; // short wait before sending
    reg [9:0]  shift = 10'h3FF; // stop | data | start
    reg [3:0]  bits_left = 0;
    reg [8:0]  bit_cnt = 0;
    reg [1:0]  gap = 0;      // a few clocks for the ROM to catch up

    always @(posedge clk) begin
        if (reset) begin
            tx <= 1'b1; b <= 0; loaded <= 0; wait_cnt <= 0;
            bits_left <= 0; bit_cnt <= 0; gap <= 0;
        end else if (!start || loaded) begin
            tx <= 1'b1;
        end else if (wait_cnt < 20'd65535) begin
            wait_cnt <= wait_cnt + 1'b1;                 // ~5 ms at 12.5 MHz
        end else if (bits_left == 0) begin
            if (gap != 2'd3) gap <= gap + 1'b1;          // let "word" update
            else begin
                shift     <= {1'b1, next_byte, 1'b0};    // load next byte
                bits_left <= 4'd10;
                bit_cnt   <= 0;
                gap       <= 0;
            end
        end else begin
            tx <= shift[0];
            if (bit_cnt == CLKS_PER_BIT - 1) begin       // one bit time done
                bit_cnt   <= 0;
                shift     <= {1'b1, shift[9:1]};
                bits_left <= bits_left - 1'b1;
                if (bits_left == 1) begin                // byte finished
                    if (b == 12'd2057) loaded <= 1'b1;
                    else               b <= b + 1'b1;
                end
            end else
                bit_cnt <= bit_cnt + 1'b1;
        end
    end

    // ---------------- Receiver ----------------
    reg [1:0] rx_s = 2'b11;
    always @(posedge clk) rx_s <= {rx_s[0], rx};

    reg       busy = 0;
    reg [9:0] cnt = 0;
    reg [3:0] n = 0;
    reg [7:0] data = 0, prev = 0;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 0; ack_seen <= 0; boot_ok <= 0; packets <= 0; prev <= 0;
        end else if (!busy) begin
            if (!rx_s[1]) begin                       // start bit
                busy <= 1; cnt <= CLKS_PER_BIT / 2; n <= 0;
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin   // middle of a bit
            cnt <= 0;
            if (n == 0) begin
                if (rx_s[1]) busy <= 0;               // false start
                n <= 1;
            end else if (n <= 8) begin
                data <= {rx_s[1], data[7:1]};         // LSB first
                n <= n + 1'b1;
            end else begin                            // stop bit: byte done
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
