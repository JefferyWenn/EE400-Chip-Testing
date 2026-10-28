// =============================================================================
// cnn_result_buf.v — Output memory buffer for CNN results from compute chip
//
// Parses the 2-flit ring PKT_DATA header sent by dla_chip before capturing
// body flits into a 12-entry × 16-bit DFF buffer:
//
//   HI flit  bits [3:2] = pkt_type; must be PKT_DATA (2'b01) per ring_pkg.
//   LO flit  bits [8:0] = len; number of body flits that follow.
//   Body     len flits captured into buf_mem[0..len-1].
//
// buf_ready is asserted once exactly len body flits have been received.
// Buffer is cleared and FSM reset to ST_HDR_HI when:
//   - firmware writes CNN_BUF_CLR (0xE004) via Wishbone, OR
//   - i_buf_clear is pulsed by pkt_framer after a packet is sent
//
// MMIO (Wishbone, soc_top decode addr[15:6] == 10'h380 → 0xE000–0xE03F)
//   0xE000  CNN_BUF_ST  [R]   bit0=buf_ready, bit1=buf_overflow
//   0xE004  CNN_BUF_CLR [W]   any write clears buffer
//   0xE010–0xE038  CNN_BUF_DATA[0..11] [R] flit values
//
// External read port (for pkt_framer streaming):
//   i_ext_raddr [3:0]  flit index 0..11
//   o_ext_rdata [15:0] flit value (combinational)
//
// External clear (for pkt_framer):
//   i_buf_clear  pulse high one cycle to clear ready and reset FSM
//
// Capture interface (BSG downstream):
//   i_bsg_rx_data [15:0], i_bsg_rx_valid
//   o_bsg_rx_yumi  combinational: asserted same cycle as valid so the BSG FIFO
//                  pops at the posedge the FSM samples the flit. A registered
//                  yumi would cause the same flit to be re-read in the next state.
//
// rst: active-high synchronous
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module cnn_result_buf (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave (0xE000–0xE03F)
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg         o_wb_ack,
    output reg  [31:0] o_wb_rdt,

    // BSG downstream capture
    input  wire [15:0] i_bsg_rx_data,
    input  wire        i_bsg_rx_valid,
    output wire        o_bsg_rx_yumi,

    // External read port (pkt_framer)
    input  wire [3:0]  i_ext_raddr,
    output wire [15:0] o_ext_rdata,

    // External clear pulse (pkt_framer)
    input  wire        i_buf_clear,

    // Status
    output wire        o_buf_ready,
    output wire        o_buf_overflow
);

    // -------------------------------------------------------------------------
    // 12-entry × 16-bit DFF buffer
    // -------------------------------------------------------------------------
    reg [15:0] buf_mem [0:11];
    reg [3:0]  wr_ptr;
    reg        ready_r;
    reg        overflow_r;

    assign o_buf_ready    = ready_r;
    assign o_buf_overflow = overflow_r;
    assign o_ext_rdata    = buf_mem[i_ext_raddr];

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [1:0] ST_HDR_HI = 2'd0,
                     ST_HDR_LO = 2'd1,
                     ST_BODY   = 2'd2,
                     ST_FULL   = 2'd3;

    localparam [1:0] PKT_DATA_TYPE = 2'b01;

    reg [1:0] state;
    reg [8:0] expect_len;
    reg [8:0] body_cnt;

    // -------------------------------------------------------------------------
    // Clear sources: firmware Wishbone write OR pkt_framer pulse
    // -------------------------------------------------------------------------
    wire is_clr_wb = i_wb_cyc && i_wb_we && (i_wb_adr[5:2] == 4'd1);
    wire do_clear  = is_clr_wb || i_buf_clear;

    // Combinational yumi: pop the BSG FIFO in the same cycle as valid so the
    // FIFO advances at the posedge where the FSM samples the flit. A registered
    // yumi would hold the same flit for an extra cycle, causing the FSM to
    // re-read the HI flit as the LO flit and corrupt the parse.
    assign o_bsg_rx_yumi = i_bsg_rx_valid && !do_clear;

    // -------------------------------------------------------------------------
    // Capture FSM
    // -------------------------------------------------------------------------
    integer j;
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= ST_HDR_HI;
            wr_ptr        <= 4'd0;
            expect_len    <= 9'd0;
            body_cnt      <= 9'd0;
            ready_r       <= 1'b0;
            overflow_r    <= 1'b0;
            for (j = 0; j < 12; j = j + 1)
                buf_mem[j] <= 16'h0;
        end else begin
            if (do_clear) begin
                state      <= ST_HDR_HI;
                wr_ptr     <= 4'd0;
                expect_len <= 9'd0;
                body_cnt   <= 9'd0;
                ready_r    <= 1'b0;
                overflow_r <= 1'b0;
            end else if (i_bsg_rx_valid) begin
                case (state)
                    ST_HDR_HI: begin
                        if (i_bsg_rx_data[3:2] == PKT_DATA_TYPE) begin
                            state <= ST_HDR_LO;
                        end else begin
                            overflow_r <= 1'b1;
                        end
                    end
                    ST_HDR_LO: begin
                        expect_len <= i_bsg_rx_data[8:0];
                        body_cnt   <= 9'd0;
                        wr_ptr     <= 4'd0;
                        if (i_bsg_rx_data[8:0] == 9'd0) begin
                            ready_r <= 1'b1;
                            state   <= ST_FULL;
                        end else begin
                            state   <= ST_BODY;
                        end
                    end
                    ST_BODY: begin
                        if (wr_ptr < 4'd12) begin
                            buf_mem[wr_ptr] <= i_bsg_rx_data;
                            wr_ptr <= wr_ptr + 4'd1;
                        end else begin
                            overflow_r <= 1'b1;
                        end
                        if (body_cnt == expect_len - 9'd1) begin
                            ready_r <= 1'b1;
                            state   <= ST_FULL;
                        end else begin
                            body_cnt <= body_cnt + 9'd1;
                        end
                    end
                    ST_FULL: begin
                        overflow_r <= 1'b1;
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Wishbone read mux
    // -------------------------------------------------------------------------
    wire [3:0] wb_off = i_wb_adr[5:2];

    always_comb begin
        o_wb_rdt = 32'h0;
        if (i_wb_cyc && !i_wb_we) begin
            if (wb_off == 4'd0) begin
                o_wb_rdt = {30'h0, overflow_r, ready_r};
            end else if (wb_off >= 4'd4) begin
                o_wb_rdt = {16'h0, buf_mem[wb_off - 4'd4]};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Wishbone ack
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) o_wb_ack <= 1'b0;
        else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
    end

endmodule
`default_nettype wire