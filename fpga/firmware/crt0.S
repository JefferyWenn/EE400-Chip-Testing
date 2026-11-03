/* Startup: set the stack, clear .bss, jump to main. */

    .section .init, "ax", @progbits
    .global  _start
    .type    _start, @function

_start:
    la   sp, _stack_top

    la   a0, _bss_start
    la   a1, _bss_end
    beq  a0, a1, .Lbss_done
.Lbss_loop:
    sw   zero, 0(a0)
    addi a0, a0, 4
    blt  a0, a1, .Lbss_loop
.Lbss_done:

    call main

.Lhang:
    j    .Lhang

    .size _start, . - _start
