# Makefile — ctrl-chip SERV RV32I firmware
#
# Targets:
#   make              → firmware_with_dla.hex  (default)
#   make clean        → remove build artifacts
#
# Toolchain: riscv64-unknown-elf-* with -march=rv32i (works for RV32I)
# Install on Ubuntu/WSL: sudo apt install gcc-riscv64-unknown-elf
# Install on macOS:      brew install riscv-software-src/riscv/riscv-gnu-toolchain

CROSS   ?= riscv64-unknown-elf
CC       = $(CROSS)-gcc
OBJCOPY  = $(CROSS)-objcopy
OBJDUMP  = $(CROSS)-objdump

ARCH_FLAGS = -march=rv32i -mabi=ilp32

CFLAGS  = $(ARCH_FLAGS) \
          -O2 \
          -std=c11 \
          -nostdlib \
          -ffreestanding \
          -Wall -Wextra

LDFLAGS = -T link.ld \
          -nostdlib \
          $(ARCH_FLAGS)

SRCS    = crt0.S firmware.c
OBJS    = $(SRCS:.S=.o)
OBJS   := $(OBJS:.c=.o)

TARGET  = firmware_with_dla

.PHONY: all clean disasm

all: $(TARGET).hex

# Link
$(TARGET).elf: $(OBJS) link.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

# Compile C
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Assemble
%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

# Binary strip
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# Hex (one 32-bit word per line, big-endian) for $readmemh
$(TARGET).hex: $(TARGET).bin
	python3 bin2hex.py $< $@

# Optional: human-readable disassembly
disasm: $(TARGET).elf
	$(OBJDUMP) -d -M no-aliases $< > $(TARGET).dis

clean:
	rm -f $(OBJS) $(TARGET).elf $(TARGET).bin $(TARGET).hex $(TARGET).dis
