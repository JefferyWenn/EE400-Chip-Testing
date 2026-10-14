`timescale 1ns/1ps
`default_nettype none

module serv_rf_top_tb;
  // Clock / Reset
  reg clk;
  reg i_rst;
  reg i_timer_irq;
  // Instruction bus
  wire [31:0] o_ibus_adr;
  wire        o_ibus_cyc;
  reg  [31:0] i_ibus_rdt;
  reg         i_ibus_ack;
  // Data bus
  wire [31:0] o_dbus_adr;
  wire [31:0] o_dbus_dat;
  wire [3:0]  o_dbus_sel;
  wire        o_dbus_we;
  wire        o_dbus_cyc;
  reg  [31:0] i_dbus_rdt;
  reg         i_dbus_ack;
  // Extension interface
  wire [31:0] o_ext_rs1;
  wire [31:0] o_ext_rs2;
  wire [2:0]  o_ext_funct3;
  reg  [31:0] i_ext_rd;
  reg         i_ext_ready;
  // MDU
  wire        o_mdu_valid;


  // Instantiate serv_rf_top DUT
  serv_rf_top #(
    .RESET_PC       (32'd0),
    .COMPRESSED     (1'b0),
    .ALIGN          (1'b0),
    .MDU            (1'b0),
    .PRE_REGISTER   (1),
    .RESET_STRATEGY ("MINI"),
    .DEBUG          (1'b0),
    .WITH_CSR       (1),
    .W              (1)
  ) dut (
    .clk(clk),
    .i_rst(i_rst),
    .i_timer_irq(i_timer_irq),

    .o_ibus_adr(o_ibus_adr),
    .o_ibus_cyc(o_ibus_cyc),
    .i_ibus_rdt(i_ibus_rdt),
    .i_ibus_ack(i_ibus_ack),

    .o_dbus_adr(o_dbus_adr),
    .o_dbus_dat(o_dbus_dat),
    .o_dbus_sel(o_dbus_sel),
    .o_dbus_we(o_dbus_we),
    .o_dbus_cyc(o_dbus_cyc),
    .i_dbus_rdt(i_dbus_rdt),
    .i_dbus_ack(i_dbus_ack),

    .o_ext_rs1(o_ext_rs1),
    .o_ext_rs2(o_ext_rs2),
    .o_ext_funct3(o_ext_funct3),
    .i_ext_rd(i_ext_rd),
    .i_ext_ready(i_ext_ready),

    .o_mdu_valid(o_mdu_valid)
  );

  // Clock generation: 10 ns period
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Reset / default inputs
  initial begin
    i_rst       = 1'b1;
    i_timer_irq = 1'b0;

    i_ibus_rdt  = 32'h0000_0013; // NOP = addi x0, x0, 0
    i_ibus_ack  = 1'b0;

    i_dbus_rdt  = 32'h0000_0000;
    i_dbus_ack  = 1'b0;

    i_ext_rd    = 32'h0000_0000;
    i_ext_ready = 1'b0;

    // Hold reset for a few cycles
    #40;
    i_rst = 1'b0;

    // Run for a while, then finish
    #3000;
    $finish;
  end

  // ----------------------------------------------------------------
  // Simple instruction/data memory model
  // - Always returns NOP on instruction fetch
  // - Always returns zero on data read
  // - Acknowledge one cycle after request
  // ----------------------------------------------------------------
  always @(posedge clk) begin
    if (i_rst) begin
      i_ibus_ack <= 1'b0;
      i_dbus_ack <= 1'b0;
      i_ibus_rdt <= 32'h0000_0013;
      i_dbus_rdt <= 32'h0000_0000;
    end
    else begin
      i_ibus_ack <= o_ibus_cyc;
      i_dbus_ack <= o_dbus_cyc;

      // Always feed NOP instruction
      i_ibus_rdt <= 32'h0000_0013;

      // Always return zero on data bus reads
      i_dbus_rdt <= 32'h0000_0000;
    end
  end

  // ----------------------------------------------------------------
  // Optional debug prints
  // ----------------------------------------------------------------
  always @(posedge clk) begin
    if (!i_rst) begin
      if (o_ibus_cyc && i_ibus_ack) begin
        $display("[%0t] IFETCH adr=%08x instr=%08x",
                 $time, o_ibus_adr, i_ibus_rdt);
      end

      if (o_dbus_cyc && i_dbus_ack) begin
        $display("[%0t] DBUS adr=%08x we=%0b sel=%x wdata=%08x rdata=%08x",
                 $time, o_dbus_adr, o_dbus_we, o_dbus_sel, o_dbus_dat, i_dbus_rdt);
      end

      if (o_mdu_valid) begin
        $display("[%0t] MDU request asserted", $time);
      end
    end
  end

endmodule

`default_nettype wire

