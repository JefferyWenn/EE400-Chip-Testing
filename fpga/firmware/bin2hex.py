#!/usr/bin/env python3
# Turns firmware.bin into firmware.hex: one 32-bit word per line, for $readmemh.
# Usage: python3 bin2hex.py firmware.bin firmware.hex

import sys
import struct

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.bin> <output.hex>", file=sys.stderr)
        sys.exit(1)

    bin_path, hex_path = sys.argv[1], sys.argv[2]

    with open(bin_path, "rb") as f:
        data = f.read()

    remainder = len(data) % 4
    if remainder:
        data += b"\x00" * (4 - remainder)

    num_words = len(data) // 4
    words = struct.unpack(f"<{num_words}I", data)   # little-endian

    with open(hex_path, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")

    print(f"Wrote {num_words} words → {hex_path}")

if __name__ == "__main__":
    main()
