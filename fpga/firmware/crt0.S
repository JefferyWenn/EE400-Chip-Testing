/* crt0.S — Minimal SERV RV32I startup
 *
 * Runs before main(). Responsibilities:
 *   1. Set stack pointer = top of data_ram (dbus 0x0000-0x07FF)
 *   2. Zero .bss section in data_ram
 *   3. Call main()
 *
 * No .data copy loop needed: all const arrays (dla_blob.h) are in .rodata
 * which lives in IRAM and is directly readable by SERV via the dbus IRAM
 * window at 0x0800-0x0FFF (see ctrl_top.sv and link.ld).
 */

    .section .init, "ax", @progbits
    .global  _start
    .type    _start, @function

_start:
    /* 1. Stack pointer — top of data_ram (2 KB = 0x0800) */
    la   sp, _stack_top

    /* 2. Zero .bss in data_ram (mutable uninitialised globals) */
    la   a0, _bss_start
    la   a1, _bss_end
    beq  a0, a1, .Lbss_done
.Lbss_loop:
    sw   zero, 0(a0)
    addi a0, a0, 4
    blt  a0, a1, .Lbss_loop
.Lbss_done:

    /* 3. Run firmware — never returns */
    call main

    /* Hang if main() ever returns (should not happen) */
.Lhang:
    j    .Lhang

    .size _start, . - _start
