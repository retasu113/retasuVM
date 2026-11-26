#!/usr/bin/env python3
"""Phase 22: dump the kernel-heap region around PA 0x78e88178 (the single
occurrence of the TTBR0 root 0x85b68000) to identify the pmap/task/proc
struct that owns the spinning process's page tables.
Also reverse-map: which VA in the spinning process maps to PA 0x80930000
(the thread_state page) -- walk the process TTBR0's L1/L2/L3 tables."""
import struct

DRAM_BASE = 0x70000000
D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
N = len(data)

def u64(off):
    return struct.unpack_from("<Q", data, off)[0]

# --- region around the TTBR0 occurrence ---
BASE = 0x78e88178
OFF = BASE - DRAM_BASE
print(f"region around PA {BASE:#x} (file {OFF:#x}), +-0x100:")
for i in range(-0x100, 0x100, 8):
    v = struct.unpack_from("<Q", data, OFF + i)[0]
    if v == 0:
        continue
    b = struct.pack("<Q", v)
    asc = ""
    if all(32 <= c < 127 or c == 0 for c in b):
        asc = repr(b)
    print(f"  {BASE + i:#x} {v:#018x} {asc}")

# --- reverse-map PA 0x80930000 via TTBR0 root 0x85b68000 ---
# Walk the L1 table (root, rl=1): 2048 entries, each covers 2^36 VA (16K granule L1).
TTBR0 = 0x85b68000
TARGET_PA_PAGE = 0x80930000
print(f"\nreverse-map: L1 entries of TTBR0 {TTBR0:#x} pointing into PA 0x80930000's region:")
l1 = TTBR0 - DRAM_BASE
for i in range(2048):
    e = u64(l1 + i * 8)
    if (e & 0x3) == 0x3:
        pa = e & 0x0000FFFFFFFFC000
        # L1 entry covers VA [i*2^36, (i+1)*2^36)
        va_base = i << 36
        if 0x100000000 <= va_base < 0x400000000:
            print(f"  L1[{i}] VA base {va_base:#x} -> L2 table PA {pa:#x}")
