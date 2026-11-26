#!/usr/bin/env python3
"""Phase 24: dump the kernel-heap region around the TTBR0-root struct
(p24: PA 0x78e886f8; p23: PA 0x78e88178) to identify the pmap/task/proc
struct that owns the spinning process's page tables. Compares the two
boots field-by-field."""
import struct
import sys

DRAM = 0x70000000

def region(dump_path, base, half=0x100):
    data = open(dump_path, "rb").read()
    off = base - DRAM
    print(f"--- {dump_path} region PA {base:#x} +- {half:#x} ---")
    for i in range(-half, half, 8):
        v = struct.unpack_from("<Q", data, off + i)[0]
        if v == 0:
            continue
        print(f"  {base + i:#x} {v:#018x}")

region("/home/retasu/retasuvm/inst/imagetest/home_p24/dram_fpend_cycle1.bin",
       0x78e886f8)
region("/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin",
       0x78e88178)
