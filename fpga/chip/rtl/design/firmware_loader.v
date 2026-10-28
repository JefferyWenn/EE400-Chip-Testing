// =============================================================================
// firmware_loader.v — UART boot loader for IRAM
//
// Loads instruction RAM from a host (PC or ESP32) at boot.
// Asserts o_load_done permanently when the 0xFFFFFFFF sentinel is received.
// After sentinel, sends ACK byte 0x06 back over o_uart_tx so the host knows
// the load completed successfully.
//
// Wire protocol (host -> chip, 8N1, 115200 baud, big-endian):
//
//   [ 0xAA ][ 0x55 ]                              -- 2-byte sync header
//   <repeat for each word:>
//     [ ADDR_B3 ][ ADDR_B2 ][ ADDR_B1 ][ ADDR_B0 ] -- 32-bit word address
//     [ DATA_B3 ][ DATA_B2 ][ DATA_B1 ][ DATA_B0 ] -- 32-bit instruction
//   <terminator:>
//     [ 0xFF ][ 0xFF ][ 0xFF ][ 0xFF ]             -- sentinel address
//     [ XX ][ XX ][ XX ][ XX ]                     -- 4 dummy bytes (ignored)
//
// After sentinel received, chip sends back:
//   [ 0x06 ]                                       -- ACK byte
//
// Status outputs:
//   o_load_done  — high once sentinel is received (does NOT wait for ACK TX)
//   o_ack_done   — high only AFTER the ACK byte has been fully transmitted
//                  (use this to switch the chip's UART TX mux from loader
//                  output to runtime output)
//
// rst: active-high synchronous.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module firmware_loader #(
    parameter CLK_HZ  = 50_000_000,
    parameter BAUD_HZ = 115_200
)(
    input  wire        clk,
    input  wire        rst,

    // RX — boot protocol input
    input  wire        i_uart_rx,

    // TX — ACK output (0x06 after sentinel)
    output wire        o_uart_tx,

    // IRAM write port
    output reg  [3:0]  o_iram_we,
    output reg  [8:0]  o_iram_waddr,
    output reg  [31:0] o_iram_wdata,

    // Status
    output reg         o_load_done,   // high after sentinel received
    output reg         o_ack_done     // high after ACK TX has completed
);

    // -------------------------------------------------------------------------
    // Baud divider
    // -------------------------------------------------------------------------
    localparam integer CLK_DIV = CLK_HZ / BAUD_HZ;
    localparam integer DIV_W   = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV);

    // -------------------------------------------------------------------------
    // RX — 8N1 UART receiver
    // -------------------------------------------------------------------------
    reg [1:0] rx_sync;
    always_ff @(posedge clk) begin
        if (rst) rx_sync <= 2'b11;
        else     rx_sync <= {rx_sync[0], i_uart_rx};
    end
    wire rx_s = rx_sync[1];

    reg [DIV_W-1:0] baud_cnt;
    reg [3:0]       bit_cnt;
    reg             rx_active;
    reg [7:0]       rx_shift;
    reg             byte_valid;
    reg [7:0]       byte_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            baud_cnt   <= 0;
            bit_cnt    <= 0;
            rx_active  <= 1'b0;
            rx_shift   <= 8'h0;
            byte_valid <= 1'b0;
            byte_data  <= 8'h0;
        end else begin
            byte_valid <= 1'b0;
            if (!rx_active) begin
                if (!rx_s) begin
                    rx_active <= 1'b1;
                    baud_cnt  <= CLK_DIV[DIV_W-1:0] >> 1;
                    bit_cnt   <= 4'd0;
                end
            end else begin
                if (baud_cnt == 0) begin
                    baud_cnt <= CLK_DIV[DIV_W-1:0] - 1;
                    case (bit_cnt)
                        4'd0: begin
                            if (rx_s) rx_active <= 1'b0;
                            bit_cnt <= bit_cnt + 4'd1;
                        end
                        4'd1,4'd2,4'd3,4'd4,
                        4'd5,4'd6,4'd7,4'd8: begin
                            rx_shift <= {rx_s, rx_shift[7:1]};
                            bit_cnt  <= bit_cnt + 4'd1;
                        end
                        4'd9: begin
                            byte_data  <= rx_shift;
                            byte_valid <= rx_s;
                            rx_active  <= 1'b0;
                        end
                        default: rx_active <= 1'b0;
                    endcase
                end else begin
                    baud_cnt <= baud_cnt - {{(DIV_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // TX — sends ACK byte 0x06 after sentinel
    // Standard 8N1: start bit (0), 8 data bits LSB first, stop bit (1)
    // o_ack_done asserts permanently after the stop bit completes.
    // -------------------------------------------------------------------------
    localparam ACK_BYTE = 8'h06;

    reg [9:0]       tx_shift;
    reg [3:0]       tx_bit_cnt;
    reg [DIV_W-1:0] tx_baud_cnt;
    reg             tx_active;

    assign o_uart_tx = tx_active ? tx_shift[0] : 1'b1;  // idle high

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_shift    <= 10'h3FF;
            tx_bit_cnt  <= 4'd0;
            tx_baud_cnt <= 0;
            tx_active   <= 1'b0;
            o_ack_done  <= 1'b0;
        end else begin
            if (!tx_active && !o_ack_done && o_load_done) begin
                tx_shift    <= {1'b1, ACK_BYTE, 1'b0};  // stop|data|start
                tx_bit_cnt  <= 4'd10;
                tx_baud_cnt <= 0;
                tx_active   <= 1'b1;
            end else if (tx_active) begin
                if (tx_baud_cnt == CLK_DIV[DIV_W-1:0] - 1) begin
                    tx_baud_cnt <= 0;
                    tx_shift    <= {1'b1, tx_shift[9:1]};
                    tx_bit_cnt  <= tx_bit_cnt - 4'd1;
                    if (tx_bit_cnt == 4'd1) begin
                        tx_active  <= 1'b0;
                        o_ack_done <= 1'b1;
                    end
                end else begin
                    tx_baud_cnt <= tx_baud_cnt + 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Loader FSM
    // -------------------------------------------------------------------------
    localparam S_SYNC1 = 3'd0,
               S_SYNC2 = 3'd1,
               S_ADDR  = 3'd2,
               S_DATA  = 3'd3,
               S_DONE  = 3'd4;

    reg [2:0]  state;
    reg [1:0]  byte_idx;
    reg [31:0] addr_acc;
    reg [31:0] data_acc;
    reg        word_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_SYNC1;
            byte_idx     <= 2'd0;
            addr_acc     <= 32'h0;
            data_acc     <= 32'h0;
            o_iram_we    <= 4'h0;
            o_iram_waddr <= 9'h0;
            o_iram_wdata <= 32'h0;
            o_load_done  <= 1'b0;
            word_ready   <= 1'b0;
        end else begin
            o_iram_we  <= 4'h0;
            word_ready <= 1'b0;

            if (word_ready) begin
                if (addr_acc[31:9] == 23'h0) begin
                    o_iram_we    <= 4'hF;
                    o_iram_waddr <= addr_acc[8:0];
                    o_iram_wdata <= data_acc[31:0];
                end
            end

            if (byte_valid && !o_load_done) begin
                case (state)

                    S_SYNC1: begin
                        if (byte_data == 8'hAA) state <= S_SYNC2;
                    end

                    S_SYNC2: begin
                        if (byte_data == 8'h55) begin
                            state    <= S_ADDR;
                            byte_idx <= 2'd0;
                        end else if (byte_data == 8'hAA) begin
                            state <= S_SYNC2;
                        end else begin
                            state <= S_SYNC1;
                        end
                    end

                    S_ADDR: begin
                        case (byte_idx)
                            2'd0: addr_acc[31:24] <= byte_data;
                            2'd1: addr_acc[23:16] <= byte_data;
                            2'd2: addr_acc[15: 8] <= byte_data;
                            2'd3: addr_acc[ 7: 0] <= byte_data;
                        endcase
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            state    <= S_DATA;
                        end else begin
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    S_DATA: begin
                        case (byte_idx)
                            2'd0: data_acc[31:24] <= byte_data;
                            2'd1: data_acc[23:16] <= byte_data;
                            2'd2: data_acc[15: 8] <= byte_data;
                            2'd3: data_acc[ 7: 0] <= byte_data;
                        endcase

                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            if (addr_acc == 32'hFFFF_FFFF) begin
                                o_load_done <= 1'b1;
                                state       <= S_DONE;
                            end else begin
                                word_ready <= 1'b1;
                                state      <= S_ADDR;
                            end
                        end else begin
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    S_DONE: ;
                    default: state <= S_SYNC1;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
