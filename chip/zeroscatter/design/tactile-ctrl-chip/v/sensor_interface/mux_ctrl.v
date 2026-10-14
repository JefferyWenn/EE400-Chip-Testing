// ============================================================
// mux_ctrl.v — Sensor matrix MUX select controller
//
// Renamed from gpio_peripheral.v. I2C OE bits removed —
// I2C pad mux is handled entirely in soc_top (i2c_init drives
// push-pull at boot; pads held idle after i2c_done=1).
//
// Controls ADG333 row MUX and ADG706 column MUX for the
// 16×16 tactile sensor matrix via 4-pin binary select.
//
// MMIO (Wishbone, 32-bit):
//   0x5000  MUX_OUT  [W/R]  MUX select register
//   0x5004  MUX_IN   [R]    reserved / future use
//
// MUX_OUT bit layout:
//   bits [3:0]   COL_BITS → ADG706 A[3:0]  column select
//   bits [7:4]   ROW_BITS → ADG333 A[3:0]  row select
//   bits [31:8]  unused
//
// Top-level pin mapping (soc_top):
//   mux_sel_o[3:2] = o_row_bits[1:0] → ADG333 A[1:0]
//   mux_sel_o[1:0] = o_col_bits[1:0] → ADG706 A[1:0]
//
// Reset state: ROW=0, COL=0
// Clock: 50 MHz, reset: synchronous active-high
// ============================================================

`default_nettype none

module mux_ctrl (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave (0x5000–0x5007)
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg         o_wb_ack,
    output reg  [31:0] o_wb_rdt,

    // MUX select outputs → sensor PCB
    output wire [3:0]  o_row_bits,   // → ADG333 A[3:0]
    output wire [3:0]  o_col_bits    // → ADG706 A[3:0]
);

    // ── Address decode ────────────────────────────────────────
    // 0x5000 → addr[3:2] == 2'b00  MUX_OUT
    // 0x5004 → addr[3:2] == 2'b01  MUX_IN (reserved)
    wire sel_out = i_wb_cyc && (i_wb_adr[3:2] == 2'b00);

    // ── MUX_OUT register (8 bits used) ───────────────────────
    reg [7:0] mux_out_reg;

    always_ff @(posedge clk) begin
        if (rst)
            mux_out_reg <= 8'b0;
        else if (i_wb_we && sel_out)
            mux_out_reg <= i_wb_dat[7:0];
    end

    // ── Wishbone ack — single-cycle pulse ─────────────────────
    always_ff @(posedge clk) begin
        if (rst) o_wb_ack <= 1'b0;
        else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
    end

    // ── Read data mux ─────────────────────────────────────────
    always_comb begin
        case (i_wb_adr[3:2])
            2'b00:   o_wb_rdt = {24'b0, mux_out_reg};
            default: o_wb_rdt = 32'b0;
        endcase
    end

    // ── Output assignments ────────────────────────────────────
    assign o_col_bits = mux_out_reg[3:0];
    assign o_row_bits = mux_out_reg[7:4];

endmodule

`default_nettype wire
