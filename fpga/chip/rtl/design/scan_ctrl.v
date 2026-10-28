// scan_ctrl.v -  Autonomous 16x16 tactile sensor array control
//
// This module allows firmware to write two registers to configure and kick off scanning.
//
//   SCAN_EN  (0x6000)
//     bit 31          1  0
//        [  unused    ] [en]
//     bit[0]=enable  — write 1 to start, 0 to halt after current cell
//
//   SCAN_CFG (0x6004)  [RW]
//     bit 31              16 15       1  0
//        [  settle_cycles  ] [ unused ] [auto_repeat]
//     bit[0]      = auto_repeat   (1=loop forever, 0=one frame then stop)
//     bits[15:1]  = reserved
//     bits[31:16] = settle_cycles (default 500 = 10 us @ 50 MHz)
//                   firmware-configurable; FSM uses this directly
//                   do not write below ~500 on 50 MHz build unless
//                   analog settling requirements are verified
//     SPI clock divider is owned by spi_master.SPI_DIV (0x700C).
//
//   SCAN_ST  (0x6008)  [R/W1C]  bit[0]=busy
//                                bit[1]=frame_done   (STICKY — set on frame end,
//                                                     cleared by W1C write of 1)
//                                bit[2]=spi_err      (STICKY — same)
//   SCAN_CELL(0x600C)  [R]      bits[7:0]={row,col}  bits[15:8]={err_row,err_col}
//   SCAN_TMO (0x6010)  [RW]     bits[15:0]=watchdog threshold cycles (default 2000)
// ============================================================
//
`default_nettype none

module scan_ctrl (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave (0x6000–0x6010)
    input  wire        i_wb_cyc,
    input  wire        i_wb_we,
    input  wire [31:0] i_wb_adr,
    input  wire [31:0] i_wb_dat,
    output reg         o_wb_ack,
    output reg  [31:0] o_wb_rdt,

    // Mux select
    output reg  [3:0]  o_mux_row,
    output reg  [3:0]  o_mux_col,

    // SPI master for ADC sampling
    output reg         o_spi_start,
    input  wire        i_spi_busy,
    input  wire [11:0] i_spi_rx_data,

    // ADC buffer direct write ports
    output reg         o_buf_we,
    output reg  [7:0]  o_buf_waddr,     // {row[3:0], col[3:0]}
    output reg  [11:0] o_buf_wdata,     // 12-bit ADC value

    // Status outputs for watchdog and error handling
    output wire        o_scan_busy,
    output reg         o_frame_done     // 1-cycle pulse when all 256 cells done
);

    // ------- Config registers -------
    reg scan_en;                // SCAN_EN[0]
    reg auto_repeat;            // SCAN_CFG[0]
    reg [15:0] settle_cfg;      // SCAN_CFG[31:16]: settle cycles (default 500 = 10 us @ 50 MHz)
    reg [15:0] tmo_thresh;      // SCAN_TMO[15:0]: Watchdog threshold in cycles (default 2000)
    reg spi_err;                // SCAN_ST[2]: SPI timeout flag (sticky)
    reg [7:0] err_cell;         // SCAN_CELL[15:8]: {err_row, err_col} latched on SPI error

    // MMIO address decoding
    wire [3:0] wadr = i_wb_adr[5:2]; // 4-bit word address within 0x6000–0x6010
    wire sel_en      = i_wb_cyc && (wadr == 4'h0); // 0x6000
    wire sel_cfg     = i_wb_cyc && (wadr == 4'h1); // 0x6004
    wire sel_st      = i_wb_cyc && (wadr == 4'h2); // 0x6008
    wire sel_cell    = i_wb_cyc && (wadr == 4'h3); // 0x600C
    wire sel_tmo     = i_wb_cyc && (wadr == 4'h4); // 0x6010

    // ------- FSM for controlling scan sequence -------
    localparam IDLE=3'd0, SETTLE=3'd1, SPI_STR=3'd2, SPI_WAIT=3'd3,
               SPI_BSY=3'd4, TIMEOUT=3'd5, STORE=3'd6, ADVANCE=3'd7;

    reg [2:0] state;
    reg [15:0] settle_cnt;      // 16-bit to match settle_cfg width (max 65535 cycles)
    reg [15:0] tmo_cnt;
    reg [3:0] cur_row, cur_col;
    reg frame_done_sticky;      // STICKY — cleared by W1C write to SCAN_ST[1]
    reg stop_req_r;             // set when scan_en cleared mid-frame

    assign o_scan_busy = (state != IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            cur_row <= 4'd0;
            cur_col <= 4'd0;
            o_mux_row <= 4'd0;
            o_mux_col <= 4'd0;
            o_spi_start <= 1'b0;
            o_buf_we <= 1'b0;
            o_buf_waddr <= 8'd0;
            o_buf_wdata <= 12'd0;
            o_frame_done <= 1'b0;
            settle_cnt <= 16'd0;
            tmo_cnt <= 16'd0;
            scan_en <= 1'b0;
            auto_repeat <= 1'b0;
            settle_cfg <= 16'd500;
            tmo_thresh <= 16'd2000;
            spi_err <= 1'b0;
            err_cell <= 8'd0;
            stop_req_r <= 1'b0;
            frame_done_sticky <= 1'b0;
        end else begin
            // Default outputs (1-cycle pulses deassert each cycle)
            o_spi_start  <= 1'b0;
            o_buf_we     <= 1'b0;
            o_frame_done <= 1'b0;
            // NOTE: frame_done_sticky is intentionally NOT cleared here.
            // It persists until firmware writes W1C to SCAN_ST[1].

            if (i_wb_cyc && i_wb_we) begin
                // Handle writes to config registers
                if (sel_en) begin
                    scan_en <= i_wb_dat[0];
                    if (!i_wb_dat[0] && o_scan_busy)
                        stop_req_r <= 1'b1; // Clearing enable mid-frame: clean stop after current cell
                end
                if (sel_cfg) begin
                    auto_repeat <= i_wb_dat[0];
                    settle_cfg  <= i_wb_dat[31:16];  // top 16 bits
                end
                if (sel_st) begin
                    // Clear status bits on write (W1C)
                    spi_err           <= spi_err           & ~i_wb_dat[2];
                    frame_done_sticky <= frame_done_sticky & ~i_wb_dat[1];
                end
                if (sel_tmo) begin
                    tmo_thresh <= i_wb_dat[15:0];
                end
            end

            // Main FSM
            case (state)
                IDLE: begin
                    cur_col <= 4'd0;
                    cur_row <= 4'd0;
                    o_mux_row <= 4'd0;
                    o_mux_col <= 4'd0;
                    stop_req_r <= 1'b0;
                    if (scan_en) begin
                        state <= SETTLE;
                        settle_cnt <= settle_cfg; // Use firmware-configured settle cycles
                    end
                end

                SETTLE: begin
                    o_mux_row <= cur_row;
                    o_mux_col <= cur_col;
                    if (settle_cnt > 16'd0) begin
                        settle_cnt <= settle_cnt - 16'd1; // Wait for mux to settle
                    end else begin
                        state <= SPI_STR;
                    end
                end

                SPI_STR: begin
                    o_spi_start <= 1'b1; // Trigger SPI read
                    tmo_cnt <= tmo_thresh;    // Reset watchdog
                    state <= SPI_WAIT;
                end

                SPI_WAIT: begin
                    if (i_spi_busy) begin
                        state <= SPI_BSY;
                    end else if (tmo_thresh != 16'd0 && tmo_cnt == 16'd0) begin
                        spi_err <= 1'b1;
                        err_cell <= {cur_row, cur_col};
                        state <= TIMEOUT;
                    end else begin
                        tmo_cnt <= tmo_cnt - 16'd1;
                    end
                end

                SPI_BSY: begin
                    if (!i_spi_busy) begin
                        state <= STORE; // SPI done, move to store result
                    end else if (tmo_thresh != 16'd0 && tmo_cnt == 16'd0) begin
                        spi_err <= 1'b1; // SPI timeout error
                        err_cell <= {cur_row, cur_col}; // Latch error cell address
                        state <= TIMEOUT; // Watchdog timeout
                    end else begin
                        tmo_cnt <= tmo_cnt - 16'd1;
                    end
                end

                TIMEOUT: begin
                    // Write sentinel 0xFFF so timed-out cells are visually
                    // distinct from real "no touch" readings (~0x00).
                    // After [11:4] truncation this stores 0xFF in adc_8bit_buf.
                    o_buf_we    <= 1'b1;
                    o_buf_waddr <= {cur_row, cur_col};
                    o_buf_wdata <= 12'hFFF;
                    state       <= ADVANCE;
                end

                STORE: begin
                    o_buf_we    <= 1'b1; // Write ADC result to buffer
                    o_buf_waddr <= {cur_row, cur_col};
                    o_buf_wdata <= i_spi_rx_data;
                    state       <= ADVANCE;
                end

                ADVANCE: begin
                    if (stop_req_r) begin
                        stop_req_r <= 1'b0;       // Clear stop request
                        state      <= IDLE;        // Stop requested, return to IDLE
                    end else if (cur_row == 4'd15 && cur_col == 4'd15) begin
                        // Frame complete: latch sticky bit, pulse the edge-output,
                        // and decide whether to loop or stop.
                        frame_done_sticky <= 1'b1;
                        o_frame_done      <= 1'b1;
                        if (auto_repeat && scan_en) begin
                            cur_row <= 4'd0;
                            cur_col <= 4'd0;
                            settle_cnt <= settle_cfg;
                            state <= SETTLE;
                        end else begin
                            scan_en <= 1'b0;   // one-shot: disarm so IDLE does not restart
                            state   <= IDLE;
                        end
                    end else begin
                        if (cur_col == 4'd15) begin
                            cur_col <= 4'd0;            // Wrap to first column
                            cur_row <= cur_row + 4'd1;  // Advance to next row
                        end else begin
                            cur_col <= cur_col + 4'd1;  // Advance to next column
                        end
                        state      <= SETTLE;           // Settle before next SPI read
                        settle_cnt <= settle_cfg;    // Reload firmware-configured settle for next cell
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    // ------- Wishbone read mux -------
    // Reads return the STICKY frame_done bit (was: 1-cycle pulse — caused
    // firmware to hang while polling SCAN_ST).
    always_comb begin
        o_wb_rdt = 32'd0;
        case (1'b1)
            sel_en:   o_wb_rdt = {31'd0, scan_en};
            sel_cfg:  o_wb_rdt = {settle_cfg, 15'd0, auto_repeat};
            sel_st:   o_wb_rdt = {29'd0, spi_err, frame_done_sticky, o_scan_busy};
            sel_cell: o_wb_rdt = {16'd0, err_cell, cur_row, cur_col};
            sel_tmo:  o_wb_rdt = {16'd0, tmo_thresh};
            default:  o_wb_rdt = 32'd0;
        endcase
    end

    // ------- Wishbone ack -------
    always_ff @(posedge clk) begin
        if (rst) o_wb_ack <= 1'b0;
        else     o_wb_ack <= i_wb_cyc && !o_wb_ack;
    end

endmodule
`default_nettype wire