// -----------------------------------------------------------------------
// chip_top.sv <- This file is for physical testing
//
// 48-pad TSMC180 wrapper for the EE478b zeroscatter SoC. Integrates:
//   - bsg_link 16-bit DDR upstream + downstream (config writes / status)
//   - SPI slave (alternate path to write the same config registers)
//   - BLE waveform generator (PIN_18 modulator output)
//   - Optional DFT scan chain stitched through PAD[11], PAD[46], PAD[47]
//
// Pad map (matches pcb_jumper_layout.md):
//
//   TOP    PAD[0..7]   = dn_data[7:0]   (RX bus, byte 0, bsg_link grid 1)
//          PAD[8]      = dn_clk
//          PAD[9]      = dn_valid
//          PAD[10]     = dn_token       (output to FPGA RX-side credit return)
//          PAD[11]     = scan_en
//
//   LEFT   PAD[12]     = token_clk      (input from FPGA RX-side)
//          PAD[13]     = SCLK           (SPI clock)
//          PAD[14]     = up_valid       (output)
//          PAD[15]     = up_clk         (output)
//          PAD[16..23] = up_data[6,7,4,5,2,3,0,1] (TX bus, byte 0, bsg_link grid 3)
//
//   BOTTOM PAD[24]     = UART_RX        (input)
//          PAD[25]     = MISO           (input, SPI ADC)
//          PAD[26]     = SS_n / CS_n    (output)
//          PAD[27]     = UART_TX        (output)
//          PAD[28..35] = up_data[8..15] (TX bus, byte 1, bsg_link grid 4)
//
//   RIGHT  PAD[36..43] = dn_data[9,8,11,10,13,12,15,14] (RX byte 1, grid 2)
//          PAD[44]     = core_clk
//          PAD[45]     = hard_reset
//          PAD[46]     = scan_in
//          PAD[47]     = scan_out
//
// io_master_clk_i for bsg_link_ddr_upstream is tied to core_clk_i internally
// to save one pad. All four bsg_link reset inputs are tied to hard_reset.
// -----------------------------------------------------------------------
module chip_top (
    inout wire [47:0] PAD,
    inout wire VDDPST,
    inout wire VSSPST,
    inout wire VDD,
    inout wire VSS
);

    // Pad ring control vectors
    reg [47:0] I;       // Output data to PAD
    reg [47:0] DS;      // Drive strength control
    reg [47:0] OEN;     // Output enable (active-low)
    reg [47:0] PE;      // Pull-down enable
    reg [47:0] IE;      // Input enable
    wire [47:0] C;      // Input data from PAD

    pad_ring_64 u_pad_ring (
        .I      (I),
        .DS     (DS),
        .OEN    (OEN),
        .PE     (PE),
        .IE     (IE),
        .C      (C),
        .PAD    (PAD),
        .VDDPST (VDDPST),
        .VSSPST (VSSPST),
        .VDD    (VDD),
        .VSS    (VSS)
    );

    // ----- Pad index parameters (must match pcb_jumper_layout.md) -----
    // Global control
    localparam int CORE_CLK_PAD          = 44;
    localparam int HARD_RESET_PAD        = 45;

    // Bsg_link RX (FPGA -> ASIC)
    localparam int DN_CLK_PAD            = 8;
    localparam int DN_VALID_PAD          = 9;
    localparam int DN_TOKEN_PAD          = 10;

    // Bsg_link TX (ASIC -> FPGA)
    localparam int TOKEN_CLK_PAD         = 12;
    localparam int UP_VALID_PAD          = 14;
    localparam int UP_CLK_PAD            = 15;

    // SPI
    localparam int SCLK_PAD              = 13;
    
    localparam int MISO_PAD              = 25;
    localparam int SS_N_PAD              = 26;

    // BLE modulator output
    localparam int UART_TX               = 27;
    localparam int UART_RX               = 24;

    // DFT scan
    localparam int SCAN_EN_PAD           = 11;
    localparam int SCAN_IN_PAD           = 46;
    localparam int SCAN_OUT_PAD          = 47;

    //MUX signal
    localparam int MUX_ROW_0 = 36;
    localparam int MUX_ROW_1 = 37;
    localparam int MUX_ROW_2 = 38;
    localparam int MUX_ROW_3 = 39;

    localparam int MUX_COL_0 = 40;
    localparam int MUX_COL_1 = 41;
    localparam int MUX_COL_2 = 42;
    localparam int MUX_COL_3 = 43;

    //I2C
    localparam int SCL = 28;
    localparam int SDA = 29;

    // ----- Per-bit dn_data PAD index lookup -----
    // dn_data[0..7] live on PAD[0..7] (top side, 2x4 jumper grid 1).
    // dn_data[8..15] live on PAD[36..43] in an interleaved pattern dictated
    // by the schematic: P1 pin 1=PAD37=dn_data[8], pin 2=PAD36=dn_data[9],
    // pin 3=PAD39=dn_data[10], pin 4=PAD38=dn_data[11], etc.
    function automatic int dn_data_pad(input int bit_idx);
        case (bit_idx)
            0:  dn_data_pad = 0;
            1:  dn_data_pad = 1;
            2:  dn_data_pad = 2;
            3:  dn_data_pad = 3;
            4:  dn_data_pad = 4;
            5:  dn_data_pad = 5;
            6:  dn_data_pad = 6;
            7:  dn_data_pad = 7;
            //8:  dn_data_pad = 37;
            //9:  dn_data_pad = 36;
            //10: dn_data_pad = 39;
            //11: dn_data_pad = 38;
            //12: dn_data_pad = 41;
            //13: dn_data_pad = 40;
            //14: dn_data_pad = 43;
            //15: dn_data_pad = 42;
            default: dn_data_pad = 0;
        endcase
    endfunction

    // up_data[0..7] live on PAD[16..23] (left side, 2x4 jumper grid 3),
    // interleaved: P2 pin 17=PAD15=??, ... Actually our left-side mapping
    // is up_data[0..7] -> PAD[22, 23, 20, 21, 18, 19, 16, 17].
    // up_data[8..15] live on PAD[28..35] sequentially.
    function automatic int up_data_pad(input int bit_idx);
        case (bit_idx)
            0:  up_data_pad = 22;
            1:  up_data_pad = 23;
            2:  up_data_pad = 20;
            3:  up_data_pad = 21;
            4:  up_data_pad = 18;
            5:  up_data_pad = 19;
            6:  up_data_pad = 16;
            7:  up_data_pad = 17;
            //8:  up_data_pad = 28;
            //9:  up_data_pad = 29;
            //10: up_data_pad = 30;
            //11: up_data_pad = 31;
            //12: up_data_pad = 32;
            //13: up_data_pad = 33;
            //14: up_data_pad = 34;
            //15: up_data_pad = 35;
            default: up_data_pad = 28;
        endcase
    endfunction

    // ----- Tap nets from C[] / drive nets toward I[] -----
    wire core_clk;
    wire hard_reset;
    wire hard_reset_sync;


    async_rst_sync_deassert u_hard_rst_sync (
        .clk                     (core_clk),
        .rst                     (~hard_reset),   // hard_reset is active-low nRESET; invert to active-high for synchronizer
        .async_rst_sync_deassert (hard_reset_sync)
    );

    wire dn_clk;
    wire dn_valid;
    wire [7:0] dn_data;
    wire dn_token;            // chip output, drives PAD[10]

    wire token_clk;
    wire up_clk;              // chip output, drives PAD[15]
    wire up_valid;            // chip output, drives PAD[14]
    wire [7:0] up_data;      // chip outputs

    // // BSG Link internal wires
    // wire [7:0] bsg_up_clk; 
    // wire       bsg_up_data; 
    // wire       bsg_up_valid;
    // wire       bsg_up_token;

    // wire [7:0] bsg_dn_clk;
    // wire       bsg_dn_data;
    // wire       bsg_dn_valid;
    // wire       bsg_dn_token;

    // UART
    wire uart_tx;

    // I2C
    wire i2c_sda_out, i2c_scl_out;   // core -> pad I[] (pad does the bidirectional)

    // SPI
    wire spi_clk, spi_cs_n;

    // Sensor MUX
    wire [3:0] mux_row, mux_col;

    //wire sclk_in; // unused: SPI master drives SCK out, never read it back
    wire uart_rx;
    wire spi_miso_i;
    //wire miso_out;

    wire scl_oen;
    wire sda_oen;
    wire scl_ie;
    wire sda_ie;

    //wire pin_18_out;

    // Tie io_master_clk to core_clk to save the PAD that would otherwise
    // carry it. The bsg_link_ddr_upstream's internal CDC degenerates when
    // io_clk_i and core_clk_i are the same net.
    wire io_master_clk = core_clk;

    // ----- Internal reset sequencer for bsg_link init protocol -----
    // bsg_async_credit_counter requires:
    //   1. Assert r_reset (= io_link_reset, on io_clk domain).
    //   2. While r_reset asserted, pulse w_reset (= async_token_reset)
    //      0 -> 1 -> 0 at least once.
    //   3. Wait >=4 r_clock posedges before deasserting r_reset.
    //   4. Deassert r_reset.
    //
    // Tying every link reset to hard_reset would violate that ordering, so
    // the chip generates the staged reset internally from a single counter
    // that starts running once hard_reset deasserts.
    // Synchronous reset. reset_cnt sits in the bootstrap reset path, so its
    // clock must keep toggling while hard_reset is asserted or it can never
    // load 0 at gate level (gated clock off in reset -> reset_cnt=X -> nRESET=X
    // -> no boot). Clock gating is therefore disabled at synthesis
    // (synthesis.clock_gating_mode: "empty" in cfg.yml) so this sync reset is
    // guaranteed to initialize. Do NOT clock-gate this counter.
    reg [5:0] reset_cnt = 6'd0;
    always_ff @(posedge core_clk) begin
        if (hard_reset_sync)              reset_cnt <= 6'd0;                // hold at 0
        else if (reset_cnt < 6'd63)       reset_cnt <= reset_cnt + 6'd1;    // count up
    end

    // async_token_reset: 0 normally, pulsed 1 during counts 2..4 after
    // hard_reset_sync deasserts. Held 0 during reset (matches bsg ref tb).
    wire async_token_reset_int = ~hard_reset_sync
                                 && (reset_cnt >= 6'd2)
                                 && (reset_cnt <  6'd5);

    // io_link_resets: held high while reset is asserted, then for
    // ~16 more core_clk cycles after the async_token_reset pulse.
    wire io_link_reset_int            = hard_reset_sync || (reset_cnt < 6'd16);
    //wire downstream_io_link_reset_int = hard_reset_sync || (reset_cnt < 6'd28);
    wire downstream_io_link_reset_int = hard_reset_sync || (reset_cnt < 6'd24);
    // Re-synchronize into dn_clk domain — required by bsg_link_ddr_downstream.
    wire downstream_io_link_reset_sync;
    
    async_rst_sync_deassert u_dn_reset_sync (
        .clk                     (dn_clk),
        .rst                     (~downstream_io_link_reset_int),
        .async_rst_sync_deassert (downstream_io_link_reset_sync)
    );

    // core link reset: released last (~32 cycles after hard_reset_sync).
    wire core_link_reset_int = hard_reset_sync || (reset_cnt < 6'd32);

    // ----- Tap clocks/inputs from pad ring -----
    assign core_clk    = C[CORE_CLK_PAD];
    assign hard_reset  = C[HARD_RESET_PAD];



    assign dn_clk      = C[DN_CLK_PAD];
    assign dn_valid    = C[DN_VALID_PAD];
    assign token_clk   = C[TOKEN_CLK_PAD];

    assign uart_rx     = C[UART_RX];
    assign spi_miso_i     = C[MISO_PAD];

    // I2C is driven straight to the pad's I/OEN pins below — no internal
    // tri-state net. The PDDW1216CDG pad provides the bidirectional buffer.

    // RX data: gather 8 bits from interleaved PAD indices.
    genvar dn_i;
    generate
        for (dn_i = 0; dn_i < 8; dn_i = dn_i + 1) begin : gen_dn_data
            assign dn_data[dn_i] = C[dn_data_pad(dn_i)];
        end
    endgenerate

`ifdef DFT_EN
    // Naive scan chain. Buffer cells give Genus named pins (instance/Z,
    // instance/I) to use as DFT control points referenced by cfg/dft.yml.
    wire scan_en, scan_in, scan_out, scan_out_d;
    BUFFD0BWP7T u_scan_en_buf  (.I(C[SCAN_EN_PAD]), .Z(scan_en));   // scan_en_port
    BUFFD0BWP7T u_scan_in_buf  (.I(C[SCAN_IN_PAD]), .Z(scan_in));   // scan_in_port
    BUFFD0BWP7T u_scan_out_buf (.I(scan_out),       .Z(scan_out_d));// scan_out_port
`endif

    // ----- Default pad configuration + per-pad overrides -----


    integer k;
    always_comb begin
        // Defaults: all pads input-disabled, output-disabled, no PD, low DS.
        for (k = 0; k < 48; k = k + 1) begin
            IE[k]  = 1'b0;
            OEN[k] = 1'b1;
            PE[k]  = 1'b0;
            DS[k]  = 1'b0;
            I[k]   = 1'b0;
        end

        // Inputs (chip listens; OEN=1 keeps driver disabled, IE=1 enables receiver).
        IE[CORE_CLK_PAD]   = 1'b1;
        IE[HARD_RESET_PAD] = 1'b1;
        IE[DN_CLK_PAD]     = 1'b1;
        IE[DN_VALID_PAD]   = 1'b1;
        IE[TOKEN_CLK_PAD]  = 1'b1;
        IE[UART_RX]       = 1'b1;
        IE[MISO_PAD]       = 1'b1; 
        for (k = 0; k < 8; k = k + 1) begin
            IE[dn_data_pad(k)] = 1'b1;
        end
        IE[SCL]=scl_ie;
        IE[SDA]=sda_ie;

        // Outputs (chip drives).
        OEN[DN_TOKEN_PAD]  = 1'b0; I[DN_TOKEN_PAD]  = dn_token;
        OEN[UP_CLK_PAD]    = 1'b0; I[UP_CLK_PAD]    = up_clk;
        OEN[UP_VALID_PAD]  = 1'b0; I[UP_VALID_PAD]  = up_valid;
        //OEN[MISO_PAD]      = 1'b0; I[MISO_PAD]      = miso_out;
        OEN[UART_TX]    = 1'b0; I[UART_TX]    = uart_tx;
        for (k = 0; k < 8; k = k + 1) begin
            OEN[up_data_pad(k)] = 1'b0;
            I[up_data_pad(k)]   = up_data[k];
        end

        OEN[SCLK_PAD]  = 1'b0; I[SCLK_PAD]  = spi_clk;
        OEN[SS_N_PAD]  = 1'b0; I[SS_N_PAD]  = spi_cs_n;
        OEN[MUX_COL_0]  = 1'b0; I[MUX_COL_0] = mux_col[0];
        OEN[MUX_COL_1]  = 1'b0; I[MUX_COL_1] = mux_col[1];
        OEN[MUX_COL_2]  = 1'b0; I[MUX_COL_2] = mux_col[2];
        OEN[MUX_COL_3]  = 1'b0; I[MUX_COL_3] = mux_col[3];
        OEN[MUX_ROW_0]  = 1'b0; I[MUX_ROW_0] = mux_row[0];
        OEN[MUX_ROW_1]  = 1'b0; I[MUX_ROW_1] = mux_row[1];
        OEN[MUX_ROW_2]  = 1'b0; I[MUX_ROW_2] = mux_row[2];
        OEN[MUX_ROW_3]  = 1'b0; I[MUX_ROW_3] = mux_row[3];


        //I2C
        OEN[SCL] = scl_oen; I[SCL] = i2c_scl_out;
        OEN[SDA] = sda_oen; I[SDA] = i2c_sda_out;

        

        `ifdef DFT_EN
                IE[SCAN_EN_PAD]  = 1'b1; OEN[SCAN_EN_PAD]  = 1'b1;
                IE[SCAN_IN_PAD]  = 1'b1; OEN[SCAN_IN_PAD]  = 1'b1;
                IE[SCAN_OUT_PAD] = 1'b0; OEN[SCAN_OUT_PAD] = 1'b0; I[SCAN_OUT_PAD] = scan_out_d;
        `endif
    end

    // ----- bsg_link wrapper: 16-bit ready/valid to top.v -----
    wire [15:0] link_rx_data;
    wire        link_rx_valid;
    wire        link_rx_yumi;
    wire [15:0] link_tx_data;
    wire        link_tx_valid;
    wire        link_tx_ready;

    bsg_link_wrapper #(
        .FLIT_WIDTH    (16),
        .CHANNEL_WIDTH (8)
    ) u_bsg_link_wrapper (
        .core_clk_i                (core_clk),
        .reset_i                   (core_link_reset_int),
        .io_master_clk_i           (io_master_clk),
        .upstream_io_link_reset_i  (io_link_reset_int),
        .async_token_reset_i       (async_token_reset_int),
        .token_clk_i               (token_clk),
        .downstream_io_link_reset_i(downstream_io_link_reset_sync),
        .downstream_io_clk_i       (dn_clk),
        .downstream_io_data_i      (dn_data),
        .downstream_io_valid_i     (dn_valid),
        .upstream_io_clk_r_o       (up_clk),
        .upstream_io_data_r_o      (up_data),
        .upstream_io_valid_r_o     (up_valid),
        .downstream_core_token_r_o (dn_token),
        .rx_data_o                 (link_rx_data),
        .rx_valid_o                (link_rx_valid),
        .rx_yumi_i                 (link_rx_yumi),
        .tx_data_i                 (link_tx_data),
        .tx_valid_i                (link_tx_valid),
        .tx_ready_o                (link_tx_ready)
    );

    // ----- Student-editable design instance -----
    ctrl_top u_ctrl_top (
        .CLK_IN         (core_clk),
        .nRESET         (~core_link_reset_int),

        .bsg_rx_data_i   (link_rx_data),
        .bsg_rx_valid_i  (link_rx_valid),
        .bsg_rx_yumi_o   (link_rx_yumi),

        .bsg_tx_data_o   (link_tx_data),
        .bsg_tx_valid_o  (link_tx_valid),
        .bsg_tx_ready_i  (link_tx_ready),

        .uart_tx_o      (uart_tx),
        .uart_rx_i      (uart_rx), // PAD[24]

        .i2c_sda_out    (i2c_sda_out),
        .i2c_sda_oen    (sda_oen),
        .i2c_sda_ie     (sda_ie),
        .i2c_scl_oen    (scl_oen),
        .i2c_scl_ie     (scl_ie),
        .i2c_scl_out    (i2c_scl_out),

        .spi_clk_o      (spi_clk),
        .spi_miso_i     (spi_miso_i), // PAD[26]
        .spi_cs_n_o     (spi_cs_n),

        .mux_row_o      (mux_row),
        .mux_col_o      (mux_col)
    );

endmodule

// -----------------------------------------------------------------------
// Async assert / sync deassert reset synchronizer.
// -----------------------------------------------------------------------
module async_rst_sync_deassert (
    input  wire clk,
    input  wire rst,
    output wire async_rst_sync_deassert
);
    wire rst_sync1;
    wire n_0 = 1'b0;  // SDN tie-low for normal operation

    // First stage flip-flop: capture async reset
    DFSNQD1BWP7T rst_sync1_reg (
        .D(1'b0),
        .CP(clk),
        .SDN(rst),        // Async reset input (active-low)
        .Q(rst_sync1)
    );

    // Second stage flip-flop: synchronize
    DFSNQD1BWP7T rst_sync2_reg (
        .D(rst_sync1),
        .CP(clk),
        .SDN(rst),       // Normal operation (SDN = 1 = disabled)
        .Q(async_rst_sync_deassert)
    );
endmodule

// -----------------------------------------------------------------------
// pad_ring_64 — instantiates 48 PDDW1216CDG bidirectional IO pads
// plus 4 corner power/ground pads per chip side.
// -----------------------------------------------------------------------
module pad_ring_64 (
    input  wire [47:0] I,
    input  wire [47:0] DS,
    input  wire [47:0] OEN,
    input  wire [47:0] PE,
    input  wire [47:0] IE,
    output wire [47:0] C,
    inout  wire [47:0] PAD,
    inout  wire        VDDPST,
    inout  wire        VSSPST,
    inout  wire        VDD,
    inout  wire        VSS
);

    PVDD2POC Pad_VDDPST_top    (.VDDPST(VDDPST));
    PVSS2CDG Pad_VSSPST_top    (.VSSPST(VSSPST));
    PVDD1CDG Pad_VDD_top       (.VDD(VDD));
    PVSS1CDG Pad_VSS_top       (.VSS(VSS));

    PVDD2CDG Pad_VDDPST_bottom (.VDDPST(VDDPST));
    PVSS2CDG Pad_VSSPST_bottom (.VSSPST(VSSPST));
    PVDD1CDG Pad_VDD_bottom    (.VDD(VDD));
    PVSS1CDG Pad_VSS_bottom    (.VSS(VSS));

    PVDD2CDG Pad_VDDPST_left   (.VDDPST(VDDPST));
    PVSS2CDG Pad_VSSPST_left   (.VSSPST(VSSPST));
    PVDD1CDG Pad_VDD_left      (.VDD(VDD));
    PVSS1CDG Pad_VSS_left      (.VSS(VSS));

    PVDD2CDG Pad_VDDPST_right  (.VDDPST(VDDPST));
    PVSS2CDG Pad_VSSPST_right  (.VSSPST(VSSPST));
    PVDD1CDG Pad_VDD_right     (.VDD(VDD));
    PVSS1CDG Pad_VSS_right     (.VSS(VSS));

    genvar i;
    generate
        for (i = 0; i < 48; i = i + 1) begin: Pad_IO
            PDDW1216CDG in_out (
                .C   (C[i]),
                .DS  (DS[i]),
                .OEN (OEN[i]),
                .PAD (PAD[i]),
                .I   (I[i]),
                .PE  (PE[i]),
                .IE  (IE[i])
            );
        end
    endgenerate

endmodule
