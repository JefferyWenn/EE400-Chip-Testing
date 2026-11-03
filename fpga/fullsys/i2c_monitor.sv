// Watches the chip's I2C write at boot.
// ok turns on if it sees address 0x5E and then data 0x7D.

module i2c_monitor (
    input  logic clk,
    input  logic reset,
    input  logic scl,
    input  logic sda,
    output logic ok = 0
);
    logic [2:0] scl_s = 3'b111, sda_s = 3'b111;
    always @(posedge clk) begin
        scl_s <= {scl_s[1:0], scl};
        sda_s <= {sda_s[1:0], sda};
    end

    logic scl_rise, start;
    assign scl_rise = ~scl_s[2] &  scl_s[1];
    assign start    =  scl_s[1] &  sda_s[2] & ~sda_s[1];   // SDA falls while SCL is high

    logic [3:0] bits = 0;
    logic [7:0] shift = 0;
    logic [1:0] nbyte = 0;
    logic       addr_ok = 0;

    // 9 clocks per byte: 8 data bits, then ACK
    always @(posedge clk) begin
        if (reset) begin
            ok <= 0; bits <= 0; nbyte <= 0; addr_ok <= 0;
        end else if (start) begin
            bits <= 0; nbyte <= 0; addr_ok <= 0;
        end else if (scl_rise) begin
            if (bits < 8) begin
                shift <= {shift[6:0], sda_s[1]};
                bits  <= bits + 1'b1;
            end else begin
                bits <= 0;
                if (nbyte == 0) addr_ok <= (shift == 8'h5E);
                if (nbyte == 1 && addr_ok && shift == 8'h7D) ok <= 1;
                nbyte <= nbyte + 1'b1;
            end
        end
    end
endmodule
