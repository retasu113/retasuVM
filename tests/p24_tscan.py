#!/usr/bin/env python3
"""Phase 24: scan the p24 dump for __darwin_arm_thread_state64 snapshots
and check the SP alignment of every userspace thread found.

Layout (osfmk/arm64/thread_state.h, __darwin_arm_thread_state64):
  __x[0..28] at +0x00..+0xE8, __fp +0xE8, __lr +0xF0, __sp +0xF8,
  __pc +0x100, __cpsr +0x108 (u32).
A snapshot is recognized by: __sp in [0x160000000,0x170000000),
__fp in the same range (or 0), __pc a userspace code VA (0x100000000+
or 0x19... cache range), __cpsr small (< 0x80000000), and at least one
of __x[16]/__x[17]/__lr a code VA.
Usage: p24_tscan.py <dump>
"""
import struct
import sys

DUMP = sys.argv[1]
data = open(DUMP, "rb").read()
N = len(data)
DRAM = 0x70000000

def is_stack(v):
    return 0x160000000 <= v < 0x170000000

def is_code(v):
    # code VAs: executable/cache ranges, EXCLUDING the user stack range
    return ((0x100000000 <= v < 0x160000000)
            or (0x170000000 <= v < 0x400000000))

hits = []
for off in range(0, N - 0x110, 8):
    sp = struct.unpack_from("<Q", data, off + 0xF8)[0]
    if not is_stack(sp):
        continue
    pc = struct.unpack_from("<Q", data, off + 0x100)[0]
    if not (0x100000000 <= pc < 0x400000000):
        continue
    fp = struct.unpack_from("<Q", data, off + 0xE8)[0]
    if fp != 0 and not is_stack(fp):
        continue
    lr = struct.unpack_from("<Q", data, off + 0xF0)[0]
    if lr != 0 and not (0x100000000 <= lr < 0x400000000):
        continue
    cpsr = struct.unpack_from("<I", data, off + 0x108)[0]
    if cpsr > 0xF0000000:
        continue
    x16 = struct.unpack_from("<Q", data, off + 0x80)[0]
    x17 = struct.unpack_from("<Q", data, off + 0x88)[0]
    if not (is_code(x16) or is_code(x17) or is_code(lr)):
        continue
    # require the x-registers to look sane (no absurd kernel VAs in x0..x15
    # except as data pointers; just require x0..x3 not be kernel VAs)
    bad = False
    for i in range(4):
        v = struct.unpack_from("<Q", data, off + i * 8)[0]
        if 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF:
            bad = True
    if bad:
        continue
    hits.append(off)

print(f"{len(hits)} thread_state64 candidates")
seen = set()
for off in hits:
    pa = DRAM + off
    sp = struct.unpack_from("<Q", data, off + 0xF8)[0]
    pc = struct.unpack_from("<Q", data, off + 0x100)[0]
    fp = struct.unpack_from("<Q", data, off + 0xE8)[0]
    lr = struct.unpack_from("<Q", data, off + 0xF0)[0]
    cpsr = struct.unpack_from("<I", data, off + 0x108)[0]
    x0 = struct.unpack_from("<Q", data, off)[0]
    x19 = struct.unpack_from("<Q", data, off + 0x98)[0]
    x20 = struct.unpack_from("<Q", data, off + 0xA0)[0]
    key = (sp, pc)
    if key in seen:
        continue
    seen.add(key)
    print(f"  PA {pa:#x}: SP {sp:#x} (%16={sp % 16}) PC {pc:#x} "
          f"FP {fp:#x} LR {lr:#x} CPSR {cpsr:#x} x0={x0:#x} "
          f"x19={x19:#x} x20={x20:#x}")
