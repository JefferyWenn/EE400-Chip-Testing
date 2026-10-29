// fake_adc.v
// Pretends to be the AD7466 ADC on the sensor board.
// Each SPI read returns 16 bits: 4 zeros + a 12-bit sample.
// The sample is {row, col, 4'b0}, so after the chip keeps the top 8 bits,
// every pixel equals its own cell number (0..255). Easy to check later.

module fake_adc (
    input  wire       clk,
    input  wire       sclk,      // from chip (PAD 13)
    input  wire       cs_n,      // from chip (PAD 26)
    input  wire [3:0] row,       // from chip mux pins (PAD 36-39)
    input  wire [3:0] col,       // from chip mux pins (PAD 40-43)
    output wire       miso       // to chip (PAD 25)
);
    // Bring the chip's SPI signals into our clock (and find their edges)
    reg [2:0] sclk_s = 3'b000;
    reg [2:0] cs_s   = 3'b111;
    always @(posedge clk) begin
        sclk_s <= {sclk_s[1:0], sclk};
        cs_s   <= {cs_s[1:0],   cs_n};
    end
    wire cs_fall   = cs_s[2]   & ~cs_s[1];
    wire sclk_fall = sclk_s[2] & ~sclk_s[1];

    // Shift register: load on CS falling, shift out on each SCK falling edge
    reg [15:0] sh = 16'h0;
    always @(posedge clk) begin
        if (cs_fall)
            sh <= {4'b0000, row, col, 4'b0000};
        else if (!cs_s[1] && sclk_fall)
            sh <= {sh[14:0], 1'b0};
    end

    assign miso = sh[15];   // MSB first
endmodule
