/* Memory: 1 KB instruction RAM, 256 B data RAM.
 * The CPU reads constants through a second window at 0x0800,
 * so .rodata is stored after the code but used at 0x0800 + offset.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    iram (rx) : ORIGIN = 0x0000, LENGTH = 1K
    dram (rw) : ORIGIN = 0x0000, LENGTH = 256
}

SECTIONS {
    .text : {
        KEEP(*(.init))
        *(.text .text.*)
        . = ALIGN(4);
    } > iram

    .rodata (0x0800 + SIZEOF(.text)) : AT(SIZEOF(.text)) {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    }

    ASSERT(SIZEOF(.text) + SIZEOF(.rodata) <= 1024,
           "firmware does not fit in the 1 KB instruction RAM")

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > dram

    /* stack starts at the top of data RAM */
    _stack_top = 0x0100;

    /DISCARD/ : { *(.eh_frame) *(.note*) *(.comment) *(.riscv.attributes) }
}
