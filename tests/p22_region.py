#!/usr/bin/env python3
"""Phase 22: dump the process-memory region PA 0x80930000-0x80931000
(containing the iovec entry (0x16d0cf4a0,8) and the 0x800000000 field)
and decode the __suio / FILE / vfprintf state around it."""
import struct

D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
BASE_PA = 0x80930000
BASE_OFF = BASE_PA - 0x70000000
region = data[BASE_OFF:BASE_OFF + 0x1000]
print(f"region PA {BASE_PA:#x}..{BASE_PA + 0x1000:#x} (file {BASE_OFF:#x})")
print("offset   PA            qword               ascii")
for i in range(0, 0x1000, 8):
    v = struct.unpack_from("<Q", region, i)[0]
    if v == 0:
        continue
    b = struct.pack("<Q", v)
    asc = ""
    if all(32 <= c < 127 or c == 0 for c in b):
        asc = repr(b)
    print(f"+{i:#06x} {BASE_PA + i:#x} {v:#018x} {asc}")
