// ============================================================
// instr_ram.v — On-chip instruction RAM, 384 × 32-bit
//
// POR-init FSM (mirrors de/comp/dla/dm.sv pattern). External
// i_ibus_cyc / i_dbus_rcyc / i_dbus_we are MASKED during init by the
// parent (ctrl_top folds o_init_done into perip_rst_n) and the read
// ports are reset to 0 so no X leaks even if the gate misses. Sim TBs
// must wait on o_init_done before $readmemh.
// ============================================================
`default_nettype none
module instr_ram #(
    parameter DEPTH = 256   // words (1KB)
)(
    input  wire        clk,
    input  wire        i_rstn,   // POR-init FSM reset (active-low)

    input  wire [8:0]  i_ibus_adr,
    output reg  [31:0] o_ibus_rdt,
    input  wire        i_ibus_cyc,

    input  wire [8:0]  i_dbus_raddr,
    output reg  [31:0] o_dbus_rdt,
    input  wire        i_dbus_rcyc,

    input  wire        i_dbus_we,
    input  wire [8:0]  i_dbus_waddr,
    input  wire [31:0] i_dbus_wdata,

    output wire        o_init_done
);
    reg [31:0] mem [0:DEPTH-1];

    localparam AW = $clog2(DEPTH);
    reg            init_active;
    reg  [AW-1:0]  init_addr;
    assign         o_init_done = ~init_active;

    wire           eff_we    = init_active ? 1'b1            : i_dbus_we;
    wire [8:0]     eff_waddr = init_active ? {{(9-AW){1'b0}}, init_addr}
                                           : i_dbus_waddr;
    wire [31:0]    eff_wdata = init_active ? 32'h0           : i_dbus_wdata;

    always_ff @(posedge clk) begin
        if (!i_rstn) begin
            init_active <= 1'b1;
            init_addr   <= '0;
        end else if (init_active) begin
            if (init_addr == AW'(DEPTH-1)) begin
                init_active <= 1'b0;
                init_addr   <= '0;
            end else begin
                init_addr   <= init_addr + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!i_rstn)
            o_ibus_rdt <= 32'h0;
        else if (i_ibus_cyc & ~init_active)
            o_ibus_rdt <= mem[i_ibus_adr];
    end

    always_ff @(posedge clk) begin
        if (!i_rstn)
            o_dbus_rdt <= 32'h0;
        else if (i_dbus_rcyc & ~init_active)
            o_dbus_rdt <= mem[i_dbus_raddr];
    end

    always_ff @(posedge clk) begin
        if (eff_we)
            mem[eff_waddr] <= eff_wdata;
    end
endmodule
`default_nettype wire
