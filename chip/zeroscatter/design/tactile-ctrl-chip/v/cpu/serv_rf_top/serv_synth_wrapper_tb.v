`timescale 1ns/1ps
`default_nettype none

module serv_synth_wrapper_tb;

reg clk;
reg rst;

initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

initial begin
    rst = 1;
    #50 rst = 0;
end

wire [31:0] ibus_adr;
wire ibus_cyc;
reg [31:0] ibus_rdt;
reg ibus_ack;

wire [31:0] dbus_adr;
wire [31:0] dbus_dat;
wire [3:0] dbus_sel;
wire dbus_we;
wire dbus_cyc;

reg [31:0] dbus_rdt;
reg dbus_ack;

wire [8:0] waddr;
wire [1:0] wdata;
wire wen;

wire [8:0] raddr;
reg [1:0] rdata;

serv_synth_wrapper dut (
    .clk(clk),
    .i_rst(rst),
    .i_timer_irq(1'b0),

    .o_ibus_adr(ibus_adr),
    .o_ibus_cyc(ibus_cyc),
    .i_ibus_rdt(ibus_rdt),
    .i_ibus_ack(ibus_ack),

    .o_dbus_adr(dbus_adr),
    .o_dbus_dat(dbus_dat),
    .o_dbus_sel(dbus_sel),
    .o_dbus_we(dbus_we),
    .o_dbus_cyc(dbus_cyc),
    .i_dbus_rdt(dbus_rdt),
    .i_dbus_ack(dbus_ack),

    .o_waddr(waddr),
    .o_wdata(wdata),
    .o_wen(wen),
    .o_raddr(raddr),
    .i_rdata(rdata)
);

initial begin
    ibus_rdt = 32'h00000013; // NOP
    ibus_ack = 0;

    dbus_rdt = 32'h0;
    dbus_ack = 0;

    rdata = 0;

    #10000 $finish;
end

always @(posedge clk) begin
    ibus_ack <= ibus_cyc;
    dbus_ack <= dbus_cyc;
end

endmodule

`default_nettype wire
