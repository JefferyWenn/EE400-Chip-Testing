/* link.ld — SERV RV32I linker script for ctrl-chip Harvard memory map
 *
 * Physical memory (what firmware_loader writes into):
 *   IRAM  0x0000 – 0x07FF  (2 KB, 512 × 32-bit words)
 *
 * SERV address spaces:
 *   ibus (instruction fetch): 0x0000 – 0x07FF  → IRAM
 *   dbus (data load/store):
 *     0x0000 – 0x07FF  → data_ram  (stack, .bss, mutable globals)
 *     0x0800 – 0x0FFF  → IRAM dbus read port  (.rodata, dla_blob arrays)
 *
 * Section layout inside the single physical IRAM:
 *
 *   Word 0                       .text  (code)
 *   Word SIZEOF(.text)/4         .rodata (dla_blob arrays, string literals)
 *   ...                          (no .data — all const)
 *
 * .bss lives in data_ram (VMA 0x0000 – 0x07FF) and is zeroed by crt0.S.
 * Stack grows down from 0x0800 (top of data_ram, set in crt0.S).
 *
 * To generate firmware.hex (one 32-bit word per line, big-endian):
 *   riscv32-unknown-elf-objcopy -O binary firmware.elf firmware.bin
 *   python3 bin2hex.py firmware.bin firmware.hex
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    iram    (rx)  : ORIGIN = 0x00000000, LENGTH = 2K
    irodata (r)   : ORIGIN = 0x00000800, LENGTH = 2K
    dram    (rw)  : ORIGIN = 0x00000000, LENGTH = 2K
}

SECTIONS {
    /* ------------------------------------------------------------------ */
    /* .text — executable code, placed at start of IRAM                   */
    /* VMA == LMA == IRAM base                                             */
    /* ------------------------------------------------------------------ */
    .text : {
        KEEP(*(.init))          /* crt0.S _start must be first */
        *(.text .text.*)
        . = ALIGN(4);
    } > iram

    /* ------------------------------------------------------------------ */
    /* .rodata — read-only data (dla_blob arrays, string literals)         */
    /* VMA: dbus window 0x0800 + SIZEOF(.text)                            */
    /* LMA: immediately after .text in physical IRAM                       */
    /*                                                                     */
    /* SERV lh/lw uses dbus_addr = VMA, so bit[11]=1 → IRAM dbus port.   */
    /* dbus_addr[10:2] = (VMA - 0x0800) / 4 = SIZEOF(.text)/4 = word idx */
    /* That is exactly where firmware_loader placed the word in IRAM.     */
    /* ------------------------------------------------------------------ */
    .rodata : AT(LOADADDR(.text) + SIZEOF(.text)) {
        . = ORIGIN(irodata) + SIZEOF(.text);
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > irodata

    /* ------------------------------------------------------------------ */
    /* .bss — uninitialised globals, zeroed by crt0.S                     */
    /* Lives in data_ram (VMA 0x0000–0x07FF), no LMA needed (NOLOAD)     */
    /* ------------------------------------------------------------------ */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > dram

    /* Stack symbol — top of data_ram (crt0.S: la sp, _stack_top) */
    _stack_top = ORIGIN(dram) + LENGTH(dram);

    /* Discard C++ exception tables and debug info to keep IRAM lean */
    /DISCARD/ : {
        *(.eh_frame)
        *(.note*)
    }
}
