#!/usr/bin/env python3
"""Read the __sfvwrite prologue bytes from the p23 dump (two physical
copies of the code page: PA 0x83e8897c and 0x845f497c)."""
import struct

D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
DRAM = 0x70000000
for pa in (0x83e8897c, 0x845f497c):
    b = data[pa - DRAM:pa - DRAM + 32]
    print(f"PA {pa:#x}: {b.hex()}")
    print("  u32 LE:", [hex(struct.unpack_from("<I", b, i)[0])
                         for i in range(0, 32, 4)])
