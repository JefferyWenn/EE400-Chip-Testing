// Releases the chip and link resets one by one after start-up.

module reset_seq (
    input  logic clk,
    input  logic restart,
    output logic hard_reset     = 1'b1,   // to the chip, 1 = reset
    output logic tx_token_reset = 1'b0,
    output logic tx_io_reset    = 1'b1,
    output logic rx_io_reset    = 1'b1,
    output logic core_reset     = 1'b1,
    output logic done
);
    logic [7:0] cnt = 8'd0;

    always @(posedge clk) begin
        if (restart)          cnt <= 8'd0;
        else if (cnt != 255)  cnt <= cnt + 1'b1;
    end

    always @(posedge clk) begin
        tx_token_reset <= (cnt >= 8) && (cnt < 10);
        tx_io_reset    <= (cnt < 19);
        hard_reset     <= (cnt < 27);
        rx_io_reset    <= (cnt < 92);
        core_reset     <= (cnt < 100);
    end

    assign done = (cnt >= 100);
endmodule
