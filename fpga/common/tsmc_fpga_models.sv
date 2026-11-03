// FPGA stand-ins for the TSMC cells in chip_top.sv.
// Same names and ports, so the chip code compiles unchanged.

// I/O pad: drives the pin when OEN = 0, reads it when IE = 1
module PDDW1216CDG (
    input  logic I,
    input  logic DS,
    input  logic OEN,
    inout  wire  PAD,
    output logic C,
    input  logic PE,
    input  logic IE
);
    assign PAD = (OEN == 1'b0) ? I : 1'bz;
    assign C   = (IE  == 1'b1) ? PAD : 1'b0;
endmodule

// power pads do nothing on the FPGA
module PVDD1CDG (inout wire VDD);    endmodule
module PVSS1CDG (inout wire VSS);    endmodule
module PVDD2CDG (inout wire VDDPST); endmodule
module PVSS2CDG (inout wire VSSPST); endmodule
module PVDD2POC (inout wire VDDPST); endmodule

// flip-flop with active-low set
module DFSNQD1BWP7T (
    input  logic D,
    input  logic CP,
    input  logic SDN,
    output logic Q
);
    always @(posedge CP or negedge SDN) begin
        if (!SDN) Q <= 1'b1;
        else      Q <= D;
    end
endmodule

module BUFFD0BWP7T (
    input  logic I,
    output logic Z
);
    assign Z = I;
endmodule
