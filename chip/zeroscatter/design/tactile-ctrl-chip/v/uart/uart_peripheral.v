// uart_peripheral.v — Wishbone UART peripheral, TX-only
//
// Wraps uart_tx. The runtime UART RX path was removed (scan chain handles
// debug; firmware_loader has its own RX sampler for boot).
//
// MMIO:
//   0xA000  UART_TX  [W]   write byte [7:0] to transmit
//   0xA004  UART_ST  [R]   bit[0] = tx_busy
//   0xA008  UART_CFG [RW] bit[0]=stream_disable (1=WB TX wins over pkt_framer stream)

// Streaming TX port (for pkt_framer):
//   i_stream_tx_data / i_stream_tx_valid : framer pushes a byte
//   o_stream_tx_ready                    : high when uart_tx can accept
//   Stream has priority over Wishbone TX writes.

`default_nettype none

module uart_peripheral #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
)(
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg  [31:0] o_wb_rdt,
    output reg         o_wb_ack,

    // UART TX pin
    output wire        o_uart_tx,

    // Streaming TX port (from pkt_framer)
    input  wire [7:0]  i_stream_tx_data,
    input  wire        i_stream_tx_valid,
    output wire        o_stream_tx_ready
);

    // ── Address decode ───────────────────────────────────────────
    wire sel_tx  = i_wb_cyc && (i_wb_adr[3:0] == 4'h0);  // 0xA000
    wire sel_st  = i_wb_cyc && (i_wb_adr[3:0] == 4'h4);  // 0xA004
    wire sel_cfg = i_wb_cyc && (i_wb_adr[3:0] == 4'h8);  // 0xA008
    reg  stream_disable_r;

    // ── uart_tx ──────────────────────────────────────────────────
    wire tx_busy;

    wire        wb_tx_fire     = i_wb_cyc && i_wb_we && sel_tx && !tx_busy;
    wire        stream_tx_fire = i_stream_tx_valid && !tx_busy && !stream_disable_r;
    wire [7:0]  tx_data_mux    = stream_tx_fire ? i_stream_tx_data
                                                : i_wb_dat[7:0];
    wire        tx_valid_mux   = stream_tx_fire | wb_tx_fire;

    assign o_stream_tx_ready = ~tx_busy;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk      (clk),
        .rst      (rst),
        .i_data   (tx_data_mux),
        .i_valid  (tx_valid_mux),
        .o_uart_tx(o_uart_tx),
        .o_busy   (tx_busy)
    );

    // ── Wishbone read ────────────────────────────────────────────
    always_comb begin
        o_wb_rdt = 32'h0;
        if      (sel_st)  o_wb_rdt = {31'h0, tx_busy};
        else if (sel_cfg) o_wb_rdt = {31'h0, stream_disable_r};
    end

    // ── Wishbone write + reset ────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            stream_disable_r <= 1'b0;
        end else begin
            if (i_wb_cyc && i_wb_we && sel_cfg)
                stream_disable_r <= i_wb_dat[0];
        end
    end

    // ── Wishbone ack ─────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) o_wb_ack <= 1'b0;
        else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
    end

endmodule

`default_nettype wire