// i2c_monitor.v
// Listens to the chip's I2C write at boot and checks it:
//   START, address byte 0x5E, ACK, data byte 0x7D, ACK, STOP
// "ok" turns on (and stays on) when both bytes were seen correctly.

module i2c_monitor (
    input  wire clk,
    input  wire reset,
    input  wire scl,
    input  wire sda,
    output reg  ok = 0
);
    // Bring the lines into our clock and find edges
    reg [2:0] scl_s = 3'b111, sda_s = 3'b111;
    always @(posedge clk) begin
        scl_s <= {scl_s[1:0], scl};
        sda_s <= {sda_s[1:0], sda};
    end
    wire scl_rise = ~scl_s[2] &  scl_s[1];
    wire start    =  scl_s[1] &  sda_s[2] & ~sda_s[1];   // SDA falls while SCL high

    // Collect bits on SCL rising edges (9 per byte: 8 data + ACK)
    reg [3:0] bits = 0;
    reg [7:0] shift = 0;
    reg [1:0] nbyte = 0;
    reg       addr_ok = 0;

    always @(posedge clk) begin
        if (reset) begin
            ok <= 0; bits <= 0; nbyte <= 0; addr_ok <= 0;
        end else if (start) begin
            bits <= 0; nbyte <= 0; addr_ok <= 0;
        end else if (scl_rise) begin
            if (bits < 8) begin
                shift <= {shift[6:0], sda_s[1]};   // MSB first
                bits  <= bits + 1'b1;
            end else begin                          // ACK bit: byte finished
                bits <= 0;
                if (nbyte == 0) addr_ok <= (shift == 8'h5E);
                if (nbyte == 1 && addr_ok && shift == 8'h7D) ok <= 1;
                nbyte <= nbyte + 1'b1;
            end
        end
    end
endmodule
