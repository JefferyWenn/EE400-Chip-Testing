`default_nettype none

// bsg_link_upstream_ctl.v — DMA-like controller: streams ADC buffer → BSG_LINK TX
//
// Trigger modes:
//   Timer mode  (BSG_UP_INTVL > 0): hw timer fires periodically, auto-starts DMA
//   Manual mode (BSG_UP_INTVL = 0): SERV writes GO=1 to trigger each transfer
//   Frame-sync mode  (full_stream_en=1):  i_frame_done pulse from scan_ctrl auto-triggers
//                                         full transfer (header + data + KICKOFF)
//
// Pack mode: when pack_8bit=1, each flit carries 2 ADC bytes (high/low).
//            Caller must set tx_pack_8bit on the conv chip to match.
//
// PKT_ACK: i_pkt_ack (one-cycle pulse from BSG RX when conv chip goes idle)
//   sets BSG_UP_ST[2]. SERV clears it with a W1C write. DMA never waits on it.
//
// MMIO (base = 0xC030, exposed via ctrl_top):
//   0xC030  BSG_UP_CFG    [RW]    bit[0]=pack_8bit
//                                  bit[1]=full_stream_en (1=auto-trigger on frame_done)
//   0xC034  BSG_UP_GO     [W]     write 1 → SERV manual trigger
//   0xC038  BSG_UP_ST     [R/W1C] bit[0]=busy  bit[1]=done  bit[2]=pkt_ack
//   0xC03C  BSG_UP_DST    [RW]    bits[5:0]=dest_chip_id (default 1)
//   0xC040  BSG_UP_INTVL  [RW]    timer interval in clk cycles (0=manual mode)

module bsg_link_upstream_ctl #(
    parameter FLIT_W          = 16,
    parameter CHIP_ID_W       = 6,
    parameter NUM_ELEMENTS    = 256,  // ADC frame size (16x16)
    parameter DEFAULT_DEST_ID = 1     // must match chip_id programmed via bsg_tag
)(
    input  wire              clk,
    input  wire              rst,

    // ADC buffer read port (combinational)
    output reg  [7:0]        o_adc_raddr,
    input  wire [7:0]        i_adc_rdata,

    // BSG_LINK upstream
    output reg  [FLIT_W-1:0] o_bsg_tx_data,
    output reg               o_bsg_tx_valid,
    input  wire              i_bsg_tx_ready,

    // PKT_ACK from BSG RX (one-cycle pulse)
    input  wire              i_pkt_ack,
    output wire              o_ack_irq,      // level: mirrors ack_r for SERV IRQ line
    output wire              o_busy,         // DMA active (gates BSG TX mux in ctrl_top)

    // Frame-done pulse from scan_ctrl (used when full_stream_en=1)
    input  wire              i_frame_done,
    
    // MMIO (Wishbone slave, single-cycle ack)
    input  wire              i_wb_cyc,
    input  wire              i_wb_we,
    input  wire [31:0]       i_wb_adr,
    input  wire [31:0]       i_wb_dat,
    output reg  [31:0]       o_wb_rdt,
    output reg               o_wb_ack
);
    localparam PKT_DATA    = 2'b01;
    localparam PKT_KICKOFF = 2'b10;
    localparam SRC_ID      = 6'd0;   // ctrl chip ID on the ring

    // ── Config registers ─────────────────────────────────────────
    reg               pack_8bit_r;
    reg               full_stream_en_r;  // BSG_UP_CFG[1]: auto-trigger on i_frame_done
    reg [CHIP_ID_W-1:0] dest_id_r;
    reg               done_r;
    reg               ack_r;
    reg [31:0]        interval_r;  // Set by SERV via 0xc040

    wire [5:0] wadr    = i_wb_adr[7:2];
    wire sel_cfg   = i_wb_cyc && (wadr == 6'h0C); // 0xC030
    wire sel_go    = i_wb_cyc && (wadr == 6'h0D); // 0xC034
    wire sel_st    = i_wb_cyc && (wadr == 6'h0E); // 0xC038
    wire sel_dst   = i_wb_cyc && (wadr == 6'h0F); // 0xC03C
    wire sel_intvl = i_wb_cyc && (wadr == 6'h10); // 0xC040

    // ── Timer ─────────────────────────────────────────────────────
    // Counts down from interval_r to 1, fires at 1, reloads.
    // interval_r=0 disables the timer (manual mode).
    reg [31:0] timer_cnt;       // internal countdown counter
    wire timer_fire = (timer_cnt == 32'd1) && (interval_r != 32'd0);

    wire sw_go = i_wb_we && sel_go && i_wb_dat[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            timer_cnt <= 32'd0;
        end else if (interval_r == 32'd0) begin
            timer_cnt <= 32'd0;     // disabled
        end else if (sw_go || timer_cnt == 32'd0 || timer_fire) begin
            timer_cnt <= interval_r;  // SW GO resets counter so next auto-fire is a full interval away
        end else begin
            timer_cnt <= timer_cnt - 32'd1;     // countdown
        end
    end

    // ── FSM ──────────────────────────────────────────────────────
    localparam S_IDLE    = 3'd0,
               S_HDR_HI  = 3'd1,   // send DATA header HI flit
               S_HDR_LO  = 3'd2,   // send DATA header LO flit
               S_BODY    = 3'd3,   // stream ADC elements as body flits
               S_KICK_HI = 3'd4,   // send KICKOFF HI flit
               S_KICK_LO = 3'd5;   // send KICKOFF LO flit

    reg [2:0] state;
    reg [8:0] elem_cnt;
    reg       body_hi_pending;
    reg [7:0] pack_hi_r;    // high byte of the flit being assembled in pack mode

    // Hold busy while o_bsg_tx_valid is asserted, even after state has returned
    // to S_IDLE — this keeps the TX-mux pointing at the DMA for the one extra
    // cycle that bsg_link needs to consume the final S_KICK_LO flit. Without
    // this, the kickoff LO flit (0x0000) sits in the registered output but never
    // reaches the link because the mux switches back to firmware-direct as soon
    // as state == S_IDLE.
    wire busy = (state != S_IDLE) || o_bsg_tx_valid;            // Fix from Maohua
    wire go   = (sw_go && !busy)                                       // firmware manual GO
              || (timer_fire && !busy)                      // timer auto-trigger
              || (full_stream_en_r && i_frame_done && !busy); // frame-sync auto-trigger

    // Fix from Maohua
    // Header word helpers (matches ring_pkg layout)
    // DATA header:  {dest[5:0], src[5:0], PKT_DATA[1:0], im_addr[8:0], len[8:0]}
    // KICKOFF:      {dest[5:0], src[5:0], PKT_KICKOFF[1:0], pc[8:0], 9'b0}
    //
    // Pack-aware length: when pack_8bit_r=1, each flit carries 2 ADC bytes,
    // so the body flit count is ceil(NUM_ELEMENTS/2) = (NUM_ELEMENTS+1)>>1.
    wire [8:0] data_len = pack_8bit_r ? 9'((NUM_ELEMENTS + 1) >> 1)
                                      : 9'(NUM_ELEMENTS);
    wire [31:0] data_hdr_word = {dest_id_r, SRC_ID, PKT_DATA,
                                 9'd0,
                                 data_len};
    wire [31:0] kick_hdr_word = {dest_id_r, SRC_ID, PKT_KICKOFF,
                                 9'd0, 9'd0};

    always_ff @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            o_bsg_tx_valid  <= 1'b0;
            o_bsg_tx_data   <= {FLIT_W{1'b0}};
            o_adc_raddr     <= 8'h0;
            elem_cnt        <= 9'd0;
            body_hi_pending <= 1'b0;
            pack_hi_r       <= 8'h0;
            pack_8bit_r     <= 1'b0;
            dest_id_r <= DEFAULT_DEST_ID[CHIP_ID_W-1:0];
            done_r          <= 1'b0;
            ack_r           <= 1'b0;
            interval_r      <= 32'd0;       // default = manual mode (timer off)
            full_stream_en_r <= 1'b0;
        end else begin
            o_bsg_tx_valid <= 1'b0;

            // PKT_ACK capture (sticky; cleared by SERV W1C on BSG_UP_ST[2])
            if (i_pkt_ack) ack_r <= 1'b1;

            // Config writes (blocked while busy to avoid mid-stream corruption)
            if (i_wb_we && sel_cfg && !busy) begin
                pack_8bit_r      <= i_wb_dat[0];
                full_stream_en_r <= i_wb_dat[1];
            end
            if (i_wb_we && sel_dst && !busy) dest_id_r    <= i_wb_dat[CHIP_ID_W-1:0];
            // interval_r writable any time; disabling mid-stream stops future auto-triggers
            if (i_wb_we && sel_intvl)        interval_r   <= i_wb_dat;
            // W1C: bit[1]=done, bit[2]=pkt_ack
            if (i_wb_we && sel_st) begin
                if (i_wb_dat[1]) done_r <= 1'b0;
                if (i_wb_dat[2]) ack_r  <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    elem_cnt        <= 9'd0;
                    o_adc_raddr     <= 8'h0;
                    body_hi_pending <= 1'b0;
                    if (go) begin
                        done_r <= 1'b0;
                        state  <= S_HDR_HI;
                    end
                end

                S_HDR_HI: begin
                    if (i_bsg_tx_ready) begin
                        o_bsg_tx_valid <= 1'b1;
                        o_bsg_tx_data  <= data_hdr_word[31:16];
                        state <= S_HDR_LO;
                    end
                end

                S_HDR_LO: begin
                    if (i_bsg_tx_ready) begin
                        o_bsg_tx_valid <= 1'b1;
                        o_bsg_tx_data  <= data_hdr_word[15:0];
                        state <= S_BODY;
                    end
                end

                S_BODY: begin
                    if (body_hi_pending) begin
                        if (i_bsg_tx_ready) begin
                            o_bsg_tx_valid  <= 1'b1;
                            // Fixes by Maohua
                            // Pack byte order: the chip's ring_node RX writes
                            // the LOW byte of the flit to IMA[k] first, then
                            // the HIGH byte to IMA[k+1]. So put the FIRST
                            // ADC byte (pack_hi_r) in the LOW position and
                            // the SECOND byte (i_adc_rdata) in HIGH — this
                            // preserves byte order across the link. Prior
                            // {pack_hi_r, i_adc_rdata} would pair-swap every
                            // 2 bytes, corrupting CONV input.
                            o_bsg_tx_data   <= {i_adc_rdata, pack_hi_r};
                            body_hi_pending <= 1'b0;
                            o_adc_raddr     <= o_adc_raddr + 1'b1;
                            if (elem_cnt == NUM_ELEMENTS - 1) begin
                                state <= S_KICK_HI;
                            end else begin
                                elem_cnt <= elem_cnt + 1'b1;
                            end
                        end
                    end else if (i_bsg_tx_ready) begin
                        if (pack_8bit_r) begin      // Pack two bytes per flit: latch first byte
                            pack_hi_r       <= i_adc_rdata;
                            o_adc_raddr     <= o_adc_raddr + 1'b1;
                            body_hi_pending <= 1'b1;
                            elem_cnt        <= elem_cnt + 1'b1;
                        end else begin              // only 1 ADC byte, zero-padded
                            o_bsg_tx_valid <= 1'b1;
                            o_bsg_tx_data  <= {8'h0, i_adc_rdata};
                            o_adc_raddr    <= o_adc_raddr + 1'b1;
                            if (elem_cnt == NUM_ELEMENTS - 1) begin
                                state <= S_KICK_HI;
                            end else begin
                                elem_cnt <= elem_cnt + 1'b1;
                            end
                        end
                    end
                end

                S_KICK_HI: begin
                    if (i_bsg_tx_ready) begin
                        o_bsg_tx_valid <= 1'b1;
                        o_bsg_tx_data  <= kick_hdr_word[31:16];
                        state <= S_KICK_LO;
                    end
                end

                S_KICK_LO: begin
                    if (i_bsg_tx_ready) begin
                        o_bsg_tx_valid <= 1'b1;
                        o_bsg_tx_data  <= kick_hdr_word[15:0];
                        done_r         <= 1'b1;
                        state          <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ── Output assignments ────────────────────────────────────────
    assign o_ack_irq    = ack_r;
    assign o_busy       = busy;

    // ── Wishbone ─────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) o_wb_ack <= 1'b0;
        else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
    end

    always_comb begin
        case (1'b1)
            sel_cfg:   o_wb_rdt = {30'b0, full_stream_en_r, pack_8bit_r};
            sel_st:    o_wb_rdt = {29'b0, ack_r, done_r, busy};
            sel_dst:   o_wb_rdt = {{(32-CHIP_ID_W){1'b0}}, dest_id_r};
            sel_intvl: o_wb_rdt = interval_r;
            default:   o_wb_rdt = 32'b0;
        endcase
    end

endmodule

`default_nettype wire