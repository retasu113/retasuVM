#!/usr/bin/env python3
"""Phase 22: read the spinning thread's USER STACK via TTBR0 (root 0x85b68000).
Dump the 16 KiB stack pages around x29=0x16d0ce8f8 / x22=0x16d0cf4a0,
decode the __sfvwrite frame (saved regs) and the data buffer being written."""
import struct

DRAM_BASE = 0x70000000
D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
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
        off = table_pa - DRAM_BASE + idx * 8
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

TTBR0 = 0x85b68000
X29 = 0x16d0ce8f8
X22 = 0x16d0cf4a0

# Walk the stack pages: the page containing x29/x22 is VA 0x16d0cc000
# (0x16d0ce8f8 & ~0x3fff). Also probe neighbours.
for base in (0x16d0cc000, 0x16d0c8000, 0x16d0c4000, 0x16d0c0000, 0x16d0d0000):
    pa = walk(TTBR0, base)
    print(f"stack page VA {base:#x} -> PA {pa if pa is None else hex(pa)}")

# Dump the page containing x29/x22: VA 0x16d0cc000
PAGE_BASE = 0x16d0cc000
pa0 = walk(TTBR0, PAGE_BASE)
page = data[pa0 - DRAM_BASE: pa0 - DRAM_BASE + 0x4000]
open("/tmp/p22_stackpage.bin", "wb").write(page)
print(f"\npage VA {PAGE_BASE:#x} -> PA {pa0:#x}, saved to /tmp/p22_stackpage.bin")

def q(va):
    off = va - PAGE_BASE
    return struct.unpack_from("<Q", page, off)[0]

print(f"\n--- __sfvwrite frame (x29={X29:#x}) saved regs ---")
for name, va in (("saved x29 (caller FP)", X29), ("saved x30 (LR)", X29 + 8),
                 ("saved x19 (caller)", X29 - 8), ("saved x20 (caller)", X29 - 0x10),
                 ("saved x21 (caller)", X29 - 0x18), ("saved x22 (caller)", X29 - 0x20),
                 ("saved x23 (caller)", X29 - 0x28), ("saved x24 (caller)", X29 - 0x30),
                 ("saved x25 (caller)", X29 - 0x38), ("saved x26 (caller)", X29 - 0x40),
                 ("saved x27 (caller)", X29 - 0x48), ("saved x28 (caller)", X29 - 0x50)):
    print(f"  {name:24s} [{va:#x}] = {q(va):#018x}")

print(f"\n--- data buffer at x22={X22:#x} (first 512 B, printable) ---")
off = X22 - PAGE_BASE
buf = page[off:off + 512]
print(repr(buf[:256]))
print(repr(buf[256:512]))
print(f"\n--- stack region x29-0x200 .. x22+0x200, non-zero qwords ---")
for va in range(X29 - 0x200, X22 + 0x200, 8):
    v = q(va)
    if v:
        asc = ""
        b = struct.pack("<Q", v)
        if all(32 <= c < 127 or c == 0 for c in b):
            asc = repr(b)
        print(f"  [{va:#x}] = {v:#018x} {asc}")
