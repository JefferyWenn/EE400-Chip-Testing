// JTAG-controlled scan chain integrity testbench for chip_top.
//
// Drives the JTAG TAP (PAD[20]=TCK, PAD[21]=TMS, PAD[22]=TDI, PAD[26]=TDO)
// to load the INTEST instruction and shift a known pattern through the
// internal scan chain. PAD[0] (chip clk) is driven in lockstep with TCK
// during shift so each TCK cycle = one chain shift.
//
// Run against a *gate-level* netlist (post-syn or post-PAR). Build with
// `+define+DFT_EN`.

`timescale 1ps/1ps
module chip_top_tb_scan;

    // ---------- Parameters ----------
    parameter integer CHAIN_LEN  = 1185;       // matches Genus DFTchains report
    parameter integer TCK_HALF   = 5000;       // 100 MHz scan rate (1ps timescale)
    parameter integer FLUSH_BITS = CHAIN_LEN + 16;

    // OpenCores tap_top instruction encodings (from tap_defines.v).
    // EXTEST is what gates the internal scan chain via extest_select_o.
    parameter logic [3:0] IR_EXTEST = 4'b0000;

    // ---------- Pads ----------
    wire [47:0] pad;
    wire vdd_io = 1'b1;
    wire vss_io = 1'b0;

    reg clk_r        = 1'b0;
    reg hard_reset_r = 1'b1;
    reg tms_r        = 1'b1;       // start in Test-Logic-Reset
    reg tdi_r        = 1'b0;
    reg tck_r        = 1'b0;

    // PAD[0] is driven in lockstep with TCK during shift (board-level tie)
    assign pad[0]  = tck_r;
    assign pad[13] = hard_reset_r;
    assign pad[20] = tck_r;
    assign pad[21] = tms_r;
    assign pad[22] = tdi_r;
    wire   tdo_w   = pad[26];

    chip_top uut (
        .PAD(pad),
        .VDDPST(vdd_io),
        .VSSPST(vss_io),
        .VDD(vdd_io),
        .VSS(vss_io)
    );

    // ---------- TCK / scan_clk generation ----------
    // (no free-running clock — every TCK edge is explicit)
    task tck_pulse;
        begin
            #(TCK_HALF) tck_r = 1'b1;
            #(TCK_HALF) tck_r = 1'b0;
        end
    endtask

    // Drive TMS for next TCK rising edge, then pulse TCK
    task tms_clock(input bit tms_val);
        begin
            tms_r = tms_val;
            tck_pulse();
        end
    endtask

    // Walk the TAP through Test-Logic-Reset (TMS=1 for 5+ TCKs)
    task tap_reset;
        integer k;
        begin
            for (k = 0; k < 6; k = k + 1) tms_clock(1'b1);
        end
    endtask

    // From Test-Logic-Reset (or Run-Test/Idle), navigate to Shift-IR
    task tap_to_shift_ir;
        begin
            tms_clock(1'b0);  // -> Run-Test/Idle
            tms_clock(1'b1);  // -> Select-DR-Scan
            tms_clock(1'b1);  // -> Select-IR-Scan
            tms_clock(1'b0);  // -> Capture-IR
            tms_clock(1'b0);  // -> Shift-IR
        end
    endtask

    // From Shift-IR, exit and update IR (current shifted value becomes ir_reg)
    task tap_update_ir;
        begin
            tms_clock(1'b1);  // -> Exit1-IR (last bit shifted on this edge)
            tms_clock(1'b1);  // -> Update-IR
            tms_clock(1'b0);  // -> Run-Test/Idle
        end
    endtask

    // From Run-Test/Idle, navigate to Shift-DR
    task tap_to_shift_dr;
        begin
            tms_clock(1'b1);  // -> Select-DR-Scan
            tms_clock(1'b0);  // -> Capture-DR
            tms_clock(1'b0);  // -> Shift-DR
        end
    endtask

    // Shift one bit out (TDO sampled before TCK rising) and one bit in (TDI on rising edge)
    task shift_dr_bit(input bit tdi_val, output bit tdo_val);
        begin
            tdi_r   = tdi_val;
            tdo_val = tdo_w;          // sample TDO before TCK rises
            tms_clock(1'b0);          // stay in Shift-DR
        end
    endtask

    // Load 4-bit IR with `value`. Caller is responsible for being in Shift-IR.
    task shift_ir_load(input logic [3:0] value);
        integer k;
        bit unused;
        begin
            for (k = 0; k < 3; k = k + 1) begin
                tdi_r = value[k];
                tms_clock(1'b0);
            end
            tdi_r = value[3];
            tms_clock(1'b1);  // last bit + Exit1-IR transition
            tms_clock(1'b1);  // Update-IR
            tms_clock(1'b0);  // Run-Test/Idle
        end
    endtask

    // ---------- Test ----------
    integer i;
    integer mismatches = 0;
    bit observed;

    function bit gen_bit(input integer idx);
        return idx[0];
    endfunction

    initial begin
        $display("[scan-tb] starting JTAG-controlled scan chain integrity test (CHAIN_LEN=%0d)", CHAIN_LEN);

        // Reset
        #(TCK_HALF*2);
        hard_reset_r = 1'b0;
        #(TCK_HALF*2);

        // 1. Reset TAP and load EXTEST instruction (selects the chain)
        tap_reset();
        tap_to_shift_ir();
        shift_ir_load(IR_EXTEST);

        // 2. Navigate to Shift-DR. scan_en will assert on the first TCK
        //    rising edge inside Shift-DR.
        tap_to_shift_dr();

        // 3. Shift FLUSH_BITS through the chain. Capture TDO each cycle and
        //    compare against the expected pattern (delayed by CHAIN_LEN).
        for (i = 0; i < FLUSH_BITS; i = i + 1) begin
            shift_dr_bit(gen_bit(i), observed);
            if (i >= CHAIN_LEN) begin
                bit expected;
                expected = gen_bit(i - CHAIN_LEN);
                if (observed !== expected) begin
                    mismatches = mismatches + 1;
                    if (mismatches < 8)
                        $display("[scan-tb] mismatch at i=%0d: got %b, expected %b",
                                 i, observed, expected);
                end
            end
        end

        if (mismatches == 0)
            $display("[scan-tb] PASS: chain of length %0d shifts cleanly via JTAG", CHAIN_LEN);
        else
            $display("[scan-tb] FAIL: %0d mismatches", mismatches);
        $finish;
    end

    initial begin
        #(TCK_HALF * 2 * (FLUSH_BITS + 64) * 2);  // x2 for TAP overhead
        $display("[scan-tb] WATCHDOG timeout");
        $finish;
    end

endmodule
