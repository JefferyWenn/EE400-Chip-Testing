`default_nettype none

// uart_tx.v — 8N1 UART transmitter
//
// i_valid pulses one cycle with i_data to start a transmission.
// o_busy is high from the start bit through the stop bit.
// New data is ignored while o_busy is asserted.

module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] i_data,
    input  wire       i_valid,
    output reg        o_uart_tx,
    output wire       o_busy
);
    localparam CLKS_PER_BIT = CLK_HZ / BAUD;

    localparam IDLE  = 2'd0,
               START = 2'd1,
               DATA  = 2'd2,
               STOP  = 2'd3;

    reg  [1:0]  state;
    reg  [7:0]  tx_byte;
    reg  [15:0] cnt;
    reg  [2:0]  bit_idx;

    assign o_busy = (state != IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            o_uart_tx <= 1'b1;
            cnt       <= 0;
            bit_idx   <= 0;
            tx_byte   <= 0;
        end else case (state)
            IDLE: begin
                o_uart_tx <= 1'b1;
                cnt       <= 0;
                bit_idx   <= 0;
                if (i_valid) begin
                    tx_byte <= i_data;
                    state   <= START;
                end
            end
            START: begin
                o_uart_tx <= 1'b0;
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt   <= 0;
                    state <= DATA;
                end else cnt <= cnt + 1;
            end
            DATA: begin
                o_uart_tx <= tx_byte[bit_idx];
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt <= 0;
                    if (bit_idx == 3'd7) begin
                        bit_idx <= 0;
                        state   <= STOP;
                    end else bit_idx <= bit_idx + 1;
                end else cnt <= cnt + 1;
            end
            STOP: begin
                o_uart_tx <= 1'b1;
                if (cnt == CLKS_PER_BIT - 1) begin
                    cnt   <= 0;
                    state <= IDLE;
                end else cnt <= cnt + 1;
            end
        endcase
    end

endmodule

`default_nettype wire