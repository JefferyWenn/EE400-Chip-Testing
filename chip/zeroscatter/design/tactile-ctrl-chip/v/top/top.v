// top.v — wrapper connecting ctrl_top to chip_top's bsg_link_wrapper
module top (
    input  wire        CLK,
    input  wire        hard_reset,
    input  wire        SCLK,
    input  wire        MOSI,
    output wire        MISO,
    input  wire        SS_n,
    input  wire [31:0] link_rx_data_i,
    input  wire        link_rx_valid_i,
    output wire        link_rx_yumi_o,
    input  wire        link_tx_ready_i,
    output wire [31:0] link_tx_data_o,
    output wire        link_tx_valid_o,
    output wire        PIN_18
);
    assign MISO = 1'b0;
    wire nRESET = ~hard_reset;

    // wire        bsg_up_clk;
    // wire [7:0]  bsg_up_data;
    // wire        bsg_up_valid;
    // wire        bsg_up_token;
    // wire        bsg_dn_clk;
    // wire [7:0]  bsg_dn_data;
    // wire        bsg_dn_valid;
    // wire        bsg_dn_token;
    wire        uart_tx;
    wire        spi_clk;
    wire        spi_cs_n;
    wire [3:0]  mux_row;
    wire [3:0]  mux_col;
    wire        i2c_sda;
    wire        i2c_scl;

    // wire i2c_keepalive = i2c_sda ^ i2c_scl;
    wire bsg_up_clk = 1'b0;  // or 1'b1

    //// BSG bridge
    // assign bsg_dn_clk      = CLK;
    // assign bsg_dn_data     = link_rx_data_i[7:0];
    // assign bsg_dn_valid    = link_rx_valid_i;
    // assign link_rx_yumi_o  = bsg_dn_token;
    // assign link_tx_data_o  = {8'd0, mux_col, mux_row,
    //                            spi_cs_n, spi_clk, uart_tx,
    //                            bsg_up_valid, bsg_up_data};
    // assign link_tx_valid_o = bsg_up_valid;
    // assign bsg_up_token    = link_tx_ready_i;

    // PIN_18 keepalive
    assign PIN_18 = uart_tx ^ spi_clk ^ spi_cs_n
                  ^ mux_row[0] ^ mux_row[1] ^ mux_row[2] ^ mux_row[3]
                  ^ mux_col[0] ^ mux_col[1] ^ mux_col[2] ^ mux_col[3]
                  ^ bsg_up_clk;

    // Top-level outputs — pass through from ctrl_top
    assign link_rx_yumi_o  = 1'b0;  // Or tie to actual signal if needed
    assign link_tx_data_o  = 32'h0;
    assign link_tx_valid_o = 1'b0;

    ctrl_top u_ctrl_top (
        .CLK_IN         (CLK),
        .nRESET         (nRESET),
        // .bsg_up_clk_o   (bsg_up_clk),
        // .bsg_up_data_o  (bsg_up_data),
        // .bsg_up_valid_o (bsg_up_valid),
        // .bsg_up_token_i (bsg_up_token),
        // .bsg_dn_clk_i   (bsg_dn_clk),
        // .bsg_dn_data_i  (bsg_dn_data),
        // .bsg_dn_valid_i (bsg_dn_valid),
        // .bsg_dn_token_o (bsg_dn_token),
        .bsg_rx_data_i  (link_rx_data_i),
        .bsg_rx_valid_i (link_rx_valid_i),
        .bsg_rx_yumi_o  (link_rx_yumi_o),
        .bsg_tx_data_o  (link_tx_data_o[15:0]),
        .bsg_tx_valid_o (link_tx_valid_o),
        .bsg_tx_ready_i (link_tx_ready_i),
        .uart_tx_o      (uart_tx),
        .uart_rx_i      (MOSI),
        .i2c_sda_io     (i2c_sda),
        .i2c_scl_io     (i2c_scl),
        .spi_clk_o      (spi_clk),
        .spi_miso_i     (SS_n),
        .spi_cs_n_o     (spi_cs_n),
        .mux_row_o      (mux_row),
        .mux_col_o      (mux_col)
    );

endmodule
