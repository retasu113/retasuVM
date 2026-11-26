#!/usr/bin/env python3
"""Phase 24: verify the SP-misalignment hypothesis and walk the frame chain.

- Recomputes __vfprintf's SP from __sfvwrite's live x29 and checks SP%16.
- Reads the stack slots that decide the uio layout:
    [sp,#0x110] (iov array base), [sp,#0x130] (fp slot), [sp,#0x138] (real uio.iov)
- Walks the FP chain from __sfvwrite's x29, recording FP%16 and saved LR.
Usage: p24_fpwalk.py <dump>
"""
import struct
import sys

DUMP = sys.argv[1]
DRAM = 0x70000000
TTBR0 = 0x85bcc000
data = open(DUMP, "rb").read()
N = len(data)

def u64(off):
    return struct.unpack_from("<Q", data, off)[0]

def walk(root_pa, va, root_level=1):
    granule, idx_bits, page_size = 14, 11, 1 << 14
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = granule + (3 - level) * idx_bits
        idx = (va >> shift) & ((1 << idx_bits) - 1)
        if level == root_level and root_level == 0:
            idx = (va >> 47) & 0x1
        off = table_pa - DRAM + idx * 8
        if off < 0 or off + 8 > N:
            return None
        entry = u64(off)
        if entry & 0x1 == 0:
            return None
        typ = entry & 0x3
        if level == 3:
            if typ != 0x3:
                return None
            return (entry & 0x0000FFFFFFFFC000) + (va & (page_size - 1))
        if typ == 0x3:
            table_pa = entry & 0x0000FFFFFFFFC000
            continue
        if typ == 0x1:
            oa_mask = (~0) & ~((1 << shift) - 1) & 0x0000FFFFFFFFFFFF
            return (entry & oa_mask) + (va & ((1 << shift) - 1))
        return None
    return None

def read_va(va, n):
    buf = b""
    while len(buf) < n:
        cur = va + len(buf)
        pa = walk(TTBR0, cur & ~0x3FFF)
        if pa is None:
            return None
        off = cur & 0x3FFF
        take = min(n - len(buf), 0x4000 - off)
        buf += data[pa - DRAM + off: pa - DRAM + off + take]
    return buf

def q(va):
    b = read_va(va, 8)
    return struct.unpack("<Q", b)[0] if b else None

X29 = 0x16efd28f8   # live x29 (__sfvwrite FP)
SP = X29 + 0x10     # __sfvwrite entry SP (x29 = sp_entry - 0x10)
print(f"live x29 (__sfvwrite FP) = {X29:#x}  (%16 = {X29 % 16})")
print(f"SP at __sfvwrite entry    = {SP:#x}  (%16 = {SP % 16})")
print(f"__vfprintf FP (saved x29) = {q(X29):#x}  (%16 = {q(X29) % 16})")
print()
print("--- stack slots (SP-relative, __vfprintf frame) ---")
for name, off in (("fp slot   [sp,#0x130]", 0x130),
                  ("uio.iov   [sp,#0x138]", 0x138),
                  ("uio.iovcnt[sp,#0x140]", 0x140),
                  ("uio.resid [sp,#0x144]", 0x144),
                  ("iov base  [sp,#0x110]", 0x110)):
    va = SP + off
    v = q(va)
    print(f"  {name} VA {va:#x} = {v if v is None else hex(v)}")
print()
print("--- the two uio readings ---")
print(f"  uio as passed to __sfvwrite (x20=0x16efd2a38):")
print(f"    iov    = {q(0x16efd2a38):#x}")
print(f"    iovcnt = {struct.unpack('<I', read_va(0x16efd2a40, 4))[0]} (low32 of qword {q(0x16efd2a40):#x})")
print(f"    resid  = {struct.unpack('<I', read_va(0x16efd2a44, 4))[0]}")
print(f"  real uio (sp+0x138 = 0x16efd2a40):")
print(f"    iov    = {q(0x16efd2a40):#x}")
print(f"    iovcnt = {struct.unpack('<I', read_va(0x16efd2a48, 4))[0]}")
print(f"    resid  = {struct.unpack('<I', read_va(0x16efd2a4c, 4))[0]}")
print(f"  iov array at {q(0x16efd2a40):#x}:")
base = q(0x16efd2a40)
for i in range(3):
    print(f"    iov[{i}] ptr={q(base + i*16)} len={q(base + i*16 + 8)}")
print()
print("--- FP chain walk (from __sfvwrite x29) ---")
fp = X29
seen = set()
for depth in range(24):
    if fp is None or fp in seen or not (0x16e000000 <= fp < 0x170000000):
        print(f"  stop: fp={fp if fp is None else hex(fp)}")
        break
    seen.add(fp)
    saved_fp = q(fp)
    saved_lr = q(fp + 8)
    unslid = saved_lr - 0x1bbc8000 if saved_lr else None
    print(f"  depth {depth}: FP {fp:#x} (%16={fp % 16})  savedLR {saved_lr if saved_lr is None else hex(saved_lr)} (unslid {unslid if unslid is None else hex(unslid)})  savedFP {saved_fp if saved_fp is None else hex(saved_fp)}")
    fp = saved_fp
