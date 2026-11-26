#!/usr/bin/env python3
"""Phase 26: debug the TTBR0 walk for fsck user VAs. Trace walk() for the
Mach-O header VA and the PC/SP, at both root levels. Also dump the raw
L1 entries of the root table.
Run on the PC. Usage: p26_walkdbg.py <dump>
"""
import struct
import sys

sys.path.insert(0, ".")
from p4_lib import Dump, walk

DUMP = sys.argv[1]
ROOT = 0x85B70000

d = Dump(DUMP)
out = open("p26_walkdbg_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


for va in (0x100C0C000, 0x100C947C0, 0x16F1F3CF8, 0x180000000):
    for rl in (0, 1):
        pa = walk(d, ROOT, va, 14, rl, trace=False)
        log(f"VA {va:#x} root_level={rl} -> PA {pa if pa is None else hex(pa)}")

log("\n--- root table L1 entries (first 32) ---")
for i in range(32):
    e = d.u64_pa(ROOT + i * 8)
    if e:
        log(f"  L1[{i}] = {e:#018x} (type {e & 3})")
log("\n--- L1 idx for 0x100c0c000 = (va>>36)&0x7ff ---")
log(f"  idx = {(0x100C0C000 >> 36) & 0x7FF}")
log(f"  L0 idx (bit47) = {(0x100C0C000 >> 47) & 1}")
out.close()
print("wrote p26_walkdbg_out.txt")
