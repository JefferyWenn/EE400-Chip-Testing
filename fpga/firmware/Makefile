# Makefile - build the control chip firmware
#
#   make          -> firmware.hex (one 32-bit word per line)
#   make install  -> also copy it to ../driver/firmware.hex (built into the driver FPGA)
#   make dis      -> firmware.dis (disassembly, to look at the code)
#
# Needs the xPack RISC-V compiler, e.g. in ~/tools:
#   export PATH=~/tools/xpack-riscv-none-elf-gcc-13.2.0-2/bin:$PATH

CROSS   ?= riscv-none-elf
CC       = $(CROSS)-gcc
OBJCOPY  = $(CROSS)-objcopy
OBJDUMP  = $(CROSS)-objdump
SIZE     = $(CROSS)-size

# rv32i only, small code (-Os) because the instruction RAM is only 1 KB
CFLAGS   = -march=rv32i -mabi=ilp32 -Os -std=c11 -nostdlib -ffreestanding -Wall
LDFLAGS  = -march=rv32i -mabi=ilp32 -nostdlib -T link.ld

all: firmware.hex

firmware.elf: crt0.S firmware.c dla_blob.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ crt0.S firmware.c
	$(SIZE) $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.hex: firmware.bin
	python3 bin2hex.py $< $@

install: firmware.hex
	cp firmware.hex ../driver/firmware.hex

dis: firmware.elf
	$(OBJDUMP) -d $< > firmware.dis

clean:
	rm -f firmware.elf firmware.bin firmware.hex firmware.dis

.PHONY: all install dis clean
