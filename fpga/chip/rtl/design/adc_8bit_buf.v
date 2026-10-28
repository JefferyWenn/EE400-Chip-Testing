// Current firmware address map:
//   ADC_BUF_W write address = 0x8200 + (cell_index << 2), cell_index 0..255
//   ADC_BUF_R read  address = 0x8600 + (cell_index << 2), cell_index 0..255
// ============================================================
// adc_8bit_buf.v — Single buffer for 8-bit ADC frames
//
// The 12-bit ADC raw value is truncated to 8 bits by keeping
// the top 8 bits: adc_8bit = adc_raw[11:4]  (drop lowest 4 bits).
//
// One 256-entry × 8-bit bank storing one complete 16×16 frame.
//
// Write port — scan_ctrl (priority) or firmware (when scan_ctrl idle):
//   i_scan_we             write enable — one cycle per cell (highest priority)
//   i_scan_addr[7:0]      {row[3:0], col[3:0]}
//   i_scan_data[11:0]     12-bit ADC result; top 8 bits stored
//
// Firmware write port — Wishbone (only when scan_ctrl is not writing):
//   0x8200–0x82FC     ADC_BUF_W     write bank, cell {row[3:0],col[3:0]}
//                                   addr = 0x8200 + ({row,col} << 2)
//                                   bits[7:0] of write data stored directly
//                                   ignored if scan_ctrl write active same cycle
//
// Read port — bsg_link_upstream_ctl DMA:
//   i_ext_raddr[7:0]     {row[3:0], col[3:0]}
//   o_ext_rdata[7:0]     8-bit value (combinational)
//
// Wishbone — read-only (firmware readback / debug):
//   0x8300–0x83FC     ADC_BUF_R     read bank, cell {row[3:0],col[3:0]}
//                                   addr = 0x8300 + ({row,col} << 2)
//   cell_addr[7:0]  = addr[9:2]  (covers 0..255 = 16×16 cells)
//
// ============================================================

`default_nettype none

module adc_8bit_buf (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave — i_wb_cyc already gated to this peripheral by ctrl_top
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg         o_wb_ack,
    output reg  [31:0] o_wb_rdt,

    // Direct write from scan_ctrl (primary write path during scanning).
    // i_scan_addr is the 8-bit cell index: {row[3:0], col[3:0]}.
    input  wire        i_scan_we,
    input  wire [7:0]  i_scan_addr,   // {row[3:0], col[3:0]}
    input  wire [11:0] i_scan_data,   // 12-bit ADC result; [11:4] stored

    // Direct read port — bsg_link_upstream_ctl DMA (combinational)
    input  wire  [7:0] i_ext_raddr,
    output wire  [7:0] o_ext_rdata
);

// ── Single 256 × 8-bit bank ──────────────────────────────────
reg [7:0] bank [0:255];

// Firmware Wishbone cell addressing:
//   write ADC_BUF_W cell i at byte address 0x8200 + (i << 2)
//   read  ADC_BUF_R cell i at byte address 0x8600 + (i << 2)
//   i is the same 8-bit cell index as {row[3:0], col[3:0]}.

// ── Address decode ───────────────────────────────────────────
// Cell windows:
//   write 0x8200-0x85FC, word aligned, 256 cells
//   read  0x8600-0x89FC, word aligned, 256 cells
// Firmware writes 256 cells at 0x8200 + (cell_index << 2).
// Optional firmware readback uses 0x8600 + (cell_index << 2).
wire is_wr_win = (i_wb_adr[15:9] == 7'b1000001) ||
                 (i_wb_adr[15:9] == 7'b1000010);
wire is_rd_win = (i_wb_adr[15:9] == 7'b1000011) ||
                 (i_wb_adr[15:9] == 7'b1000100);
wire [7:0] cell_addr = i_wb_adr[9:2] - 8'h80;

wire is_rd_cell = i_wb_cyc && !i_wb_we && is_rd_win;
wire is_wr_cell = i_wb_cyc &&  i_wb_we && is_wr_win;

// ── SRAM ─────────────────────────────────────────────────────
// scan_ctrl write has priority — firmware write is gated out if
// scan_ctrl is writing the same cycle to prevent any conflict.
integer i;
always_ff @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 256; i = i + 1)
            bank[i] <= 8'h0;
    end else begin
        if (i_scan_we) begin
            bank[i_scan_addr] <= i_scan_data[11:4];
        end else if (is_wr_cell) begin
            // Firmware path: only when scan_ctrl is idle (not writing)
            // bits[7:0] of Wishbone write data stored directly
            bank[cell_addr] <= i_wb_dat[7:0];
        end
    end
end

assign o_ext_rdata = bank[i_ext_raddr];

// ── Wishbone read ────────────────────────────────────────────
always_comb begin
    o_wb_rdt = 32'h0;
    if (is_rd_cell) o_wb_rdt = {24'h0, bank[cell_addr]};
end

// ── Wishbone ack ─────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (rst) o_wb_ack <= 1'b0;
    else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
end

endmodule
`default_nettype wire