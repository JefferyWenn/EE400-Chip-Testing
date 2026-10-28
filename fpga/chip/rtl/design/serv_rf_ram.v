/*
 * serv_rf_ram.v : SRAM-based RF storage for SERV
 *
 * SPDX-FileCopyrightText: 2019 Olof Kindgren <olof@award-winning.me>
 * SPDX-License-Identifier: ISC
 */
module serv_rf_ram
  #(parameter width=0,
    parameter csr_regs=4,
    parameter depth=32*(32+csr_regs)/width)
   (input wire i_clk,
    input wire i_rstn,                       // POR-init FSM reset
    input wire [$clog2(depth)-1:0] i_waddr,
    input wire [width-1:0] 	   i_wdata,
    input wire 			   i_wen,
    input wire [$clog2(depth)-1:0] i_raddr,
    input wire			   i_ren,
    output wire [width-1:0] 	   o_rdata,
    output wire                    o_init_done);

   reg [width-1:0] 		   memory [0:depth-1];
   reg [width-1:0] 		   rdata ;

   // POR-init FSM (matches de/comp/dla/dm.sv pattern). On i_rstn 0→1, walks
   // every address writing 0; asserts o_init_done after the last write.
   // External i_wen / i_ren are MASKED during init so caller cannot poison.
   // ASIC: FPGA M9K / TSMC SRAMs power up to 0, but the FSM walks them
   // explicitly anyway so sim semantics match silicon. `initial` values
   // give a clean t=0 state for VCS without xprop=xmerge fights.
   // Reset (i_rstn=0) forces init_active=1 + init_addr=0 in the always
   // block below. No `reg x = 0;` declaration-time initializers — ASIC
   // tapeout requires every reg to settle via the reset clause.
   localparam AW = $clog2(depth);
   reg                init_active;
   reg [AW-1:0]       init_addr;
   assign             o_init_done = ~init_active;

   wire eff_wen              = init_active ? 1'b1            : i_wen;
   wire [AW-1:0] eff_waddr   = init_active ? init_addr       : i_waddr;
   wire [width-1:0] eff_wdata = init_active ? {width{1'b0}}  : i_wdata;

   always_ff @(posedge i_clk) begin
      if (!i_rstn) begin
         init_active <= 1'b1;
         init_addr   <= {AW{1'b0}};
         rdata       <= {width{1'b0}};
      end else if (init_active) begin
         memory[eff_waddr] <= eff_wdata;
         if (init_addr == depth-1) begin
            init_active <= 1'b0;
            init_addr   <= {AW{1'b0}};
         end else begin
            init_addr   <= init_addr + 1'b1;
         end
      end else begin
         if (eff_wen)
            memory[eff_waddr] <= eff_wdata;
         rdata <= i_ren ? memory[i_raddr] : {width{1'b0}};
      end
   end

   /* Reads from reg x0 needs to return 0
    Check that the part of the read address corresponding to the register
    is zero and gate the output
    width LSB of reg index $clog2(width)
    2     4                1
    4     3                2
    8     2                3
    16    1                4
    32    0                5
    */
   reg regzero;

   // POR reset regzero too — without it xprop=xmerge sees an X on the
   // o_rdata mask the first cycle after rstn rises (regzero gates rdata
   // to 0 for reads of x0; we want a deterministic 0 even pre-first-read).
   always_ff @(posedge i_clk) begin
      if (!i_rstn)
        regzero <= 1'b0;
      else
        regzero <= !(|i_raddr[$clog2(depth)-1:5-$clog2(width)]);
   end

   assign o_rdata = rdata & ~{width{regzero}};

`ifdef SERV_CLEAR_RAM
   integer i;
   initial
     for (i=0;i<depth;i=i+1)
       memory[i] = {width{1'd0}};
`endif
endmodule
