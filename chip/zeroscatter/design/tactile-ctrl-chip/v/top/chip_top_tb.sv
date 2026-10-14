// -----------------------------------------------------------------------
// chip_top_tb.sv
//
//
// Comprehensive testbench for the ctrl_top (Tactile Glove SoC).
// Verifies firmware loading, SERV CPU execution, sensor scanning, and
// bidirectional bsg_link communication with the DLA chip.
//
// Test phases:
//   Phase 1: Reset and bsg_link calibration
//   Phase 2: Firmware load via UART (AA 55 protocol)
//   Phase 3: SERV CPU execution and boot sequence
//   Phase 4: Sensor scan simulation (SPI ADC responses)
//   Phase 5: Full dataflow (ADC → DMA → UART output)
//
// -----------------------------------------------------------------------
`timescale 1ps/1ps
`default_nettype none

module chip_top_tb;

    // ========================================================================
    // Parameters
    // ========================================================================
    localparam int FLIT_WIDTH       = 16;
    localparam int CHANNEL_WIDTH    = 8;
    localparam int UART_BAUD        = 115_200;
    localparam int CLK_HZ           = 50_000_000;
    localparam int UART_BIT_TIME_NS = 1_000_000_000 / UART_BAUD; 


endmodule