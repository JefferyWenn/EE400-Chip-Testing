// reset_seq.v
// Start-up order for the chip and the bsg_link (same counts as the testbench).
// One counter runs after power-up or after "restart"; each reset turns off
// at its own count.

module reset_seq (
    input  wire clk,
    input  wire restart,         // 1 = start over
    output reg  hard_reset     = 1'b1, // to chip PAD 45 (1 = chip in reset)
    output reg  tx_token_reset = 1'b0, // our TX link: short pulse
    output reg  tx_io_reset    = 1'b1, // our TX link
    output reg  rx_io_reset    = 1'b1, // our RX link
    output reg  core_reset     = 1'b1, // our link core side
    output wire done             // all resets released
);
    reg [7:0] cnt = 8'd0;

    always @(posedge clk) begin
        if (restart)          cnt <= 8'd0;
        else if (cnt != 255)  cnt <= cnt + 1'b1;
    end

    always @(posedge clk) begin
        tx_token_reset <= (cnt >= 8) && (cnt < 10);  // pulse for 2 clocks
        tx_io_reset    <= (cnt < 19);
        hard_reset     <= (cnt < 27);                // chip leaves reset
        rx_io_reset    <= (cnt < 92);
        core_reset     <= (cnt < 100);
    end

    assign done = (cnt >= 100);
endmodule
