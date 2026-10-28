// chip_fpga_top.v
// Top level for FPGA A (the "chip" board, DE1-SoC).
// Puts the unchanged chip_top on the FPGA and connects its 48 pads
// to the two GPIO headers.
//
// Pad to header mapping (simple, in order):
//   PAD[0]  .. PAD[35]  ->  GPIO_0[0] .. GPIO_0[35]
//   PAD[36] .. PAD[47]  ->  GPIO_1[0] .. GPIO_1[11]
// So for example: core_clk  (PAD 44) = GPIO_1[8]
//                 hard_reset (PAD 45) = GPIO_1[9]
// See docs/PINOUT.md for what each PAD does.

module chip_fpga_top (
    inout  wire [35:0] GPIO_0,
    inout  wire [35:0] GPIO_1,
    output wire [9:0]  LEDR
);

    // ---- The chip ----
    chip_top u_chip (
        .PAD    ({GPIO_1[11:0], GPIO_0[35:0]}),  // 48 pads
        .VDDPST (),                              // power pins: not used on FPGA
        .VSSPST (),
        .VDD    (),
        .VSS    ()
    );

    // ---- Status LEDs (quick sanity check) ----
    wire core_clk   = GPIO_1[8];   // PAD 44, comes from the driver board
    wire hard_reset = GPIO_1[9];   // PAD 45, 1 = reset, 0 = run

    // LED 0: on while the chip is held in reset
    assign LEDR[0] = hard_reset;

    // LED 1: blinks when core_clk is arriving (slow counter on core_clk)
    reg [23:0] blink;
    always @(posedge core_clk) blink <= blink + 1'b1;
    assign LEDR[1] = blink[23];

    // Other LEDs off
    assign LEDR[9:2] = 8'b0;

endmodule
