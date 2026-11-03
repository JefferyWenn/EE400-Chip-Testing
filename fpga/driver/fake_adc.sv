// Fake ADC for testing without the glove.
// Every pixel reads back as its own cell number, so it's easy to check.

module fake_adc (
    input  logic       clk,
    input  logic       sclk,
    input  logic       cs_n,
    input  logic [3:0] row,
    input  logic [3:0] col,
    output logic       miso
);
    logic [2:0] sclk_s = 3'b000;
    logic [2:0] cs_s   = 3'b111;
    always @(posedge clk) begin
        sclk_s <= {sclk_s[1:0], sclk};
        cs_s   <= {cs_s[1:0],   cs_n};
    end

    logic cs_fall, sclk_fall;
    assign cs_fall   = cs_s[2]   & ~cs_s[1];
    assign sclk_fall = sclk_s[2] & ~sclk_s[1];

    // 4 zeros, then the 12-bit sample {row, col, 0000}
    logic [15:0] sh = 16'h0;
    always @(posedge clk) begin
        if (cs_fall)
            sh <= {4'b0000, row, col, 4'b0000};
        else if (!cs_s[1] && sclk_fall)
            sh <= {sh[14:0], 1'b0};
    end

    assign miso = sh[15];
endmodule
