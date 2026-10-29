#!/usr/bin/env python3
"""bin2hex.py — Convert a raw binary to one 32-bit word per line hex file.

Usage:
    python3 bin2hex.py firmware.bin firmware.hex

The output format is compatible with Verilog $readmemh:
    one word per line, 8 hex digits, no 0x prefix, no spaces.

Words are read little-endian (as produced by riscv-elf objcopy -O binary
for a little-endian RISC-V target). The last word is zero-padded if the
binary length is not a multiple of 4.
"""

import sys
import struct

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.bin> <output.hex>", file=sys.stderr)
        sys.exit(1)

    bin_path, hex_path = sys.argv[1], sys.argv[2]

    with open(bin_path, "rb") as f:
        data = f.read()

    # Pad to multiple of 4 bytes
    remainder = len(data) % 4
    if remainder:
        data += b"\x00" * (4 - remainder)

    num_words = len(data) // 4
    words = struct.unpack(f"<{num_words}I", data)   # little-endian 32-bit words

    with open(hex_path, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")

    print(f"Wrote {num_words} words → {hex_path}")

if __name__ == "__main__":
    main()
