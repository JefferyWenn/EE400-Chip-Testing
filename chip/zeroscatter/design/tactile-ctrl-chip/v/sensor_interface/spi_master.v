// ============================================================
// spi_master.v — SPI master for AD7466 ADC (16-bit, CPOL=0 CPHA=0)
//
// Trigger paths:
//   Hardware : i_hw_start pulse from scan_ctrl (normal operation)
//   Firmware : write to SPI_DATA (0x7000) while scan_ctrl is idle (debug only)
//
// SCK divider:
//   SPI_DIV (0x700C) controls all firmware and scan_ctrl-triggered transfers.
//
// All logic runs on core_clk. o_spi_sck is a registered data output —
// not a clock — so constraints.tcl only needs a constraint on core_clk.
//
// MMIO:
//   0x7000  SPI_DATA  [W]   debug trigger: start one 16-bit conversion
//   0x7004  SPI_ST    [R]   bit[0]=busy
//   0x7008  SPI_RX    [R]   16-bit result
//   0x700C  SPI_DIV   [W/R] CLK_DIV_HALF (default 7 = 3.125 MHz @ 50 MHz)
// ============================================================
`default_nettype none

module spi_master (
    input  wire        clk,
    input  wire        rst,
    // Wishbone slave (0x7000–0x700C)
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg         o_wb_ack,
    output reg  [31:0] o_wb_rdt,
    // Hardware trigger from scan_ctrl, takes precedence over debug trigger
    input  wire        i_hw_start,

    output reg         o_spi_cs,
    output reg         o_spi_sck,
    input  wire        i_spi_miso,
    // Result forwarded directly to scan_ctrl
    output wire [11:0] o_rx_data,
    output wire        o_busy
);

wire sel_data = i_wb_cyc && (i_wb_adr[3:2] == 2'b00);
wire sel_st   = i_wb_cyc && (i_wb_adr[3:2] == 2'b01);
wire sel_rx   = i_wb_cyc && (i_wb_adr[3:2] == 2'b10);
wire sel_div  = i_wb_cyc && (i_wb_adr[3:2] == 2'b11);

reg [7:0] div_reg;

always_ff @(posedge clk) begin
    if (rst) div_reg <= 8'd7;
    else if (i_wb_we && sel_div) div_reg <= i_wb_dat[7:0];
end

localparam IDLE=3'd0, WAIT=3'd1, SHIFT=3'd2, HOLD=3'd3, DONE=3'd4;
reg [2:0] state;
assign o_busy = (state != IDLE);

// cnt counts core_clk cycles; SCK toggles when cnt == div_reg.
// sck_rising_now / sck_falling_now fire in the same cycle as the toggle,
// removing the two-cycle edge-detection latency from the old sck_prev chain.
reg [7:0] cnt;
always_ff @(posedge clk) begin
    if (rst || !o_busy) begin
        cnt       <= 8'd0;
        o_spi_sck <= 1'b0;
    end else if (cnt == div_reg) begin
        o_spi_sck <= ~o_spi_sck;
        cnt       <= 8'd0;
    end else begin
        cnt <= cnt + 8'd1;
    end
end

// Rising: SCK is currently 0, about to go 1.  Falling: currently 1, about to go 0.
wire sck_rising_now  = (cnt == div_reg) && !o_spi_sck;
wire sck_falling_now = (cnt == div_reg) &&  o_spi_sck;

reg [3:0] bit_cnt; reg [15:0] rx_shift; reg [15:0] rx_latch;
assign o_rx_data = rx_latch[11:0];      // ADC_reading is 4 leading zeros + 12 data bits

// Primary trigger: scan_ctrl hardware path (normal operation)
// Debug trigger:   firmware write to SPI_DATA (0x7000) while scan_ctrl idle
// Both are gated on IDLE so a conversion in progress cannot be interrupted
wire trigger = (i_hw_start || (i_wb_we && sel_data)) && (state == IDLE);        // Combines both trigger path

always_ff @(posedge clk) begin
    if (rst) begin
        state <= IDLE; o_spi_cs <= 1; rx_shift <= 0; rx_latch <= 0; bit_cnt <= 15;
    end else case (state)
        IDLE: begin
            o_spi_cs <= 1; bit_cnt <= 15;
            if (trigger) begin o_spi_cs <= 0; state <= WAIT; end
        end
        WAIT: if (sck_rising_now) begin
            rx_shift <= {rx_shift[14:0], i_spi_miso};
            bit_cnt <= 14; state <= SHIFT;
        end
        SHIFT: if (sck_rising_now) begin
            rx_shift <= {rx_shift[14:0], i_spi_miso};
            if (bit_cnt == 0) state <= HOLD;
            else bit_cnt <= bit_cnt - 1;
        end
        HOLD: if (sck_falling_now) state <= DONE;
        DONE: begin rx_latch <= rx_shift; o_spi_cs <= 1; state <= IDLE; end
        default: state <= IDLE;
    endcase
end

// Original correct ack for SERV
always_ff @(posedge clk) begin
    if (rst) o_wb_ack <= 0;
    else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
end

always_comb begin
    case (i_wb_adr[3:2])
        2'b01:   o_wb_rdt = {31'b0, o_busy};
        2'b10:   o_wb_rdt = {16'b0, rx_latch};
        2'b11:   o_wb_rdt = {24'b0, div_reg};
        default: o_wb_rdt = 32'b0;
    endcase
end

endmodule
`default_nettype wire
