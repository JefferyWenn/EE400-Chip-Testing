// =============================================================================
// pkt_framer.v — Self-driving CNN result framer
//
// Watches cnn_result_buf. When o_buf_ready goes high, frames the 12 flits
// (24 bytes) as a 0xB0 packet and sends them to uart_peripheral's streaming
// TX port. Once the packet is fully sent, pulses o_cnn_buf_clear so the
// buffer can accept the next CNN result from the conv chip.
//
// Output packet format:
//   [ 0xB0 ][ 0x18 ][ flit0_HI ][ flit0_LO ] ... [ flit11_HI ][ flit11_LO ][ XOR ]
//
// where flit_HI = i_cnn_rdata[15:8] and flit_LO = i_cnn_rdata[7:0].
//
// Loop:
//   ST_IDLE       → wait for i_cnn_ready
//   ST_HEADER     → send 0xB0
//   ST_LENGTH     → send 0x18
//   ST_PAYLOAD    → send 24 payload bytes from cnn buffer
//   ST_CHECKSUM   → send XOR checksum, pulse o_cnn_buf_clear, then wait
//   ST_WAIT_CLEAR → spin until i_cnn_ready deasserts (cbuf has accepted
//                   the clear and dropped buf_ready), then back to IDLE
//
// Why ST_WAIT_CLEAR is needed (race fix, 2026-06-04):
//   The original FSM transitioned ST_CHECKSUM → ST_IDLE in the same cycle
//   it pulsed o_cnn_buf_clear. cnn_result_buf samples i_buf_clear on the
//   NEXT posedge, so its o_buf_ready stayed high for one more cycle. In
//   that extra cycle pkt_framer was already in ST_IDLE and saw
//   i_cnn_ready == 1, so it re-entered ST_HEADER and emitted a SECOND
//   byte-identical 0xB0 packet for the same buffer contents. Gating the
//   IDLE→HEADER transition on the clear-handshake (i_cnn_ready==0)
//   eliminates the duplicate emit. Bonus: it also defends against the
//   cbuf re-asserting ready quickly after the clear; pkt_framer will not
//   re-frame until it has seen a clean low->high edge on i_cnn_ready.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module pkt_framer (
    input  wire        clk,
    input  wire        rst,

    // CNN buffer interface
    input  wire        i_cnn_ready,
    output wire [3:0]  o_cnn_raddr,
    input  wire [15:0] i_cnn_rdata,
    output reg         o_cnn_buf_clear,

    // UART streaming TX port (to uart_peripheral)
    output reg  [7:0]  o_uart_byte,
    output reg         o_uart_valid,
    input  wire        i_uart_ready
);

    localparam [7:0] HDR_BYTE = 8'hB0;
    localparam [7:0] LEN_BYTE = 8'h18;       // 24 payload bytes
    localparam [4:0] LAST_BYTE_IDX = 5'd23;

    localparam [2:0] ST_IDLE       = 3'd0,
                     ST_HEADER     = 3'd1,
                     ST_LENGTH     = 3'd2,
                     ST_PAYLOAD    = 3'd3,
                     ST_CHECKSUM   = 3'd4,
                     ST_WAIT_CLEAR = 3'd5;

    reg [2:0] state;
    reg [4:0] byte_idx;
    reg [7:0] checksum;

    assign o_cnn_raddr = byte_idx[4:1];
    wire [7:0] payload_byte = byte_idx[0] ? i_cnn_rdata[7:0]
                                          : i_cnn_rdata[15:8];

    // Gate transitions on (i_uart_ready & ~o_uart_valid): when we just issued
    // a byte (o_uart_valid=1), wait one cycle before sending the next so
    // uart_tx has time to latch it before we overwrite o_uart_byte.
    wire ready_to_send = i_uart_ready & ~o_uart_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            state           <= ST_IDLE;
            byte_idx        <= 5'd0;
            checksum        <= 8'h0;
            o_uart_byte     <= 8'h0;
            o_uart_valid    <= 1'b0;
            o_cnn_buf_clear <= 1'b0;
        end else begin
            o_uart_valid    <= 1'b0;
            o_cnn_buf_clear <= 1'b0;

            case (state)
                ST_IDLE: begin
                    byte_idx <= 5'd0;
                    checksum <= 8'h0;
                    if (i_cnn_ready)
                        state <= ST_HEADER;
                end

                ST_HEADER: begin
                    if (ready_to_send) begin
                        o_uart_byte  <= HDR_BYTE;
                        o_uart_valid <= 1'b1;
                        checksum     <= checksum ^ HDR_BYTE;
                        state        <= ST_LENGTH;
                    end
                end

                ST_LENGTH: begin
                    if (ready_to_send) begin
                        o_uart_byte  <= LEN_BYTE;
                        o_uart_valid <= 1'b1;
                        checksum     <= checksum ^ LEN_BYTE;
                        state        <= ST_PAYLOAD;
                    end
                end

                ST_PAYLOAD: begin
                    if (ready_to_send) begin
                        o_uart_byte  <= payload_byte;
                        o_uart_valid <= 1'b1;
                        checksum     <= checksum ^ payload_byte;
                        if (byte_idx == LAST_BYTE_IDX)
                            state <= ST_CHECKSUM;
                        else
                            byte_idx <= byte_idx + 5'd1;
                    end
                end

                ST_CHECKSUM: begin
                    if (ready_to_send) begin
                        o_uart_byte     <= checksum;
                        o_uart_valid    <= 1'b1;
                        o_cnn_buf_clear <= 1'b1;
                        state           <= ST_WAIT_CLEAR;
                    end
                end

                // Wait for cnn_result_buf to acknowledge the clear (its
                // o_buf_ready drops to 0) before re-arming. Without this
                // state pkt_framer would re-enter ST_HEADER on the same
                // cycle it pulsed o_cnn_buf_clear and emit a duplicate
                // packet for the same buffer contents.
                ST_WAIT_CLEAR: begin
                    if (!i_cnn_ready)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire