/* link.ld - memory layout of the control chip (SERV CPU)
 *
 *   Instruction RAM : 1 KB (256 words), firmware is loaded here over UART
 *   Data RAM        : 256 bytes at 0x0000-0x00FF (globals + stack)
 *
 *   The CPU reads constant data (.rodata) through a second window into
 *   the instruction RAM: address 0x0800 + offset.
 *   So .rodata is LOADED right after the code, but USED at 0x0800 + that offset.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    iram (rx) : ORIGIN = 0x0000, LENGTH = 1K
    dram (rw) : ORIGIN = 0x0000, LENGTH = 256
}

SECTIONS {
    /* Code, starting at address 0 (crt0.S first) */
    .text : {
        KEEP(*(.init))
        *(.text .text.*)
        . = ALIGN(4);
    } > iram

    /* Constants: used at 0x0800 + offset, loaded right after the code */
    .rodata (0x0800 + SIZEOF(.text)) : AT(SIZEOF(.text)) {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    }

    ASSERT(SIZEOF(.text) + SIZEOF(.rodata) <= 1024,
           "firmware does not fit in the 1 KB instruction RAM")

    /* Variables in data RAM (zeroed by crt0.S) */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > dram

    /* Stack starts at the top of the 256-byte data RAM and grows down */
    _stack_top = 0x0100;

    /DISCARD/ : { *(.eh_frame) *(.note*) *(.comment) *(.riscv.attributes) }
}
