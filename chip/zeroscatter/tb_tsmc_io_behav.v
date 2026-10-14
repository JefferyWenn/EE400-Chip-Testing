`timescale 1ps/1ps

// Lightweight simulation-only models for the TSMC180 pad cells used by
// chip_top.sv. These keep RTL simulation focused on the chip_top PAD map
// without pulling in the foundry transistor-level pad model.
//
// Used by chip_top_tb.sv via cfg/tb.yml.

module PDDW1216CDG (
    input  wire I,
    input  wire DS,
    input  wire OEN,
    inout  wire PAD,
    output wire C,
    input  wire PE,
    input  wire IE
);
    assign PAD = OEN ? 1'bz : I;
    assign C   = IE  ? PAD  : 1'b0;
endmodule

module PVDD2POC (inout wire VDDPST);
endmodule

module PVSS2CDG (inout wire VSSPST);
endmodule

module PVDD1CDG (inout wire VDD);
endmodule

module PVSS1CDG (inout wire VSS);
endmodule

module PVDD2CDG (inout wire VDDPST);
endmodule
