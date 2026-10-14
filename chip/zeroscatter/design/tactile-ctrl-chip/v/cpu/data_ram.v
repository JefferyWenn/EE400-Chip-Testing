// ============================================================
// data_ram.v — Data RAM, 64 × 32-bit flop array, byte-enable write
//
// Read  : combinational, gated by ~init_active so a pre-init read does
//         not present X.
// Write : registered on posedge clk, byte-enable gated, plus zero-walk
//         init FSM that owns the write port until o_init_done.
// ============================================================

`default_nettype none

module data_ram (
    input  wire        clk,
    input  wire        i_rstn,    // POR-init FSM reset (active-low)

    input  wire [3:0]  we,        // byte-enable  (1 bit per byte)
    input  wire [5:0]  waddr,     // word address (64 entries)
    input  wire [31:0] wdata,
    input  wire [5:0]  raddr,
    output wire [31:0] rdata,

    output wire        o_init_done
);

    localparam DEPTH = 64;
    localparam AW    = 6;

    logic [31:0] mem [0:DEPTH-1];

    reg            init_active;
    reg  [AW-1:0]  init_addr;
    assign         o_init_done = ~init_active;

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

    wire [AW-1:0] eff_waddr = init_active ? init_addr : waddr;
    wire   [31:0] eff_wdata = init_active ? 32'h0     : wdata;
    wire    [3:0] eff_we    = init_active ? 4'hF      : we;

    always_ff @(posedge clk) begin
        if (eff_we[0]) mem[eff_waddr][ 7: 0] <= eff_wdata[ 7: 0];
        if (eff_we[1]) mem[eff_waddr][15: 8] <= eff_wdata[15: 8];
        if (eff_we[2]) mem[eff_waddr][23:16] <= eff_wdata[23:16];
        if (eff_we[3]) mem[eff_waddr][31:24] <= eff_wdata[31:24];
    end

    assign rdata = init_active ? 32'h0 : mem[raddr];

endmodule

`default_nettype wire
