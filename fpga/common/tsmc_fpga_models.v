// tsmc_fpga_models.v
// Simple FPGA versions of the TSMC cells used in chip_top.sv.
// Same names and ports, so chip_top.sv compiles unchanged in Quartus.

// IO pad: drives the pin when OEN = 0, reads the pin when IE = 1.
module PDDW1216CDG (
    input  wire I,     // value to drive out
    input  wire DS,    // drive strength (not used on FPGA)
    input  wire OEN,   // 0 = drive the pin, 1 = let go
    inout  wire PAD,   // the physical pin
    output wire C,     // value read from the pin
    input  wire PE,    // pull-down (not used on FPGA)
    input  wire IE     // 1 = read the pin
);
    assign PAD = (OEN == 1'b0) ? I : 1'bz;
    assign C   = (IE  == 1'b1) ? PAD : 1'b0;
endmodule

// Power pads: just power on the chip, nothing to do on FPGA.
module PVDD1CDG (inout wire VDD);    endmodule
module PVSS1CDG (inout wire VSS);    endmodule
module PVDD2CDG (inout wire VDDPST); endmodule
module PVSS2CDG (inout wire VSSPST); endmodule
module PVDD2POC (inout wire VDDPST); endmodule

// Flip-flop with set: SDN = 0 forces Q to 1 right away,
// otherwise Q takes D on each rising clock edge.
module DFSNQD1BWP7T (
    input  wire D,
    input  wire CP,    // clock
    input  wire SDN,   // set, active-low
    output reg  Q
);
    always @(posedge CP or negedge SDN) begin
        if (!SDN) Q <= 1'b1;
        else      Q <= D;
    end
endmodule

// Buffer: output = input. (Only used if DFT_EN is defined.)
module BUFFD0BWP7T (
    input  wire I,
    output wire Z
);
    assign Z = I;
endmodule
