#!/usr/bin/env python3
"""Phase 22: scan the p23 dump for the spinning thread's TTBR0.
Anchor: VA 0x19B87C9EC must walk to PA 0x83e889ec or 0x845f49ec
(the two physical copies of the __sfvwrite code page).
16K granule, root L0 (2 entries, bit 47) or L1.
Signature of a TTBR0 L0 table: entry0 = table desc (bits 0b11, 16K-aligned
PA in DRAM), entry1 = 0, rest of first 1 KiB = 0."""
import struct

DRAM_BASE = 0x70000000
D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
N = len(data)
print(f"dump {N} B")

def u64(off):
    return struct.unpack_from("<Q", data, off)[0]

def walk(root_pa, va, root_level):
    granule = 14
    idx_bits = 11
    page_size = 1 << granule
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = granule + (3 - level) * idx_bits
        idx = (va >> shift) & ((1 << idx_bits) - 1)
        if level == root_level and root_level == 0:
            idx = (va >> 47) & 0x1
            shift = 47
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
            base = entry & 0x0000FFFFFFFFC000
            return base + (va & (page_size - 1))
        if typ == 0x3:
            table_pa = entry & 0x0000FFFFFFFFC000
            continue
        if typ == 0x1:
            oa_mask = (~0) & ~((1 << shift) - 1) & 0x0000FFFFFFFFFFFF
            base = entry & oa_mask
            return base + (va & ((1 << shift) - 1))
        return None
    return None

TARGET_VA = 0x19B87C9EC
GOOD_PAS = {0x83e889ec, 0x845f49ec}
STACK_VA = 0x16d0cf4a0

# scan 16K-aligned pages for L0 signature
cands = []
for off in range(0, N - 0x4000 + 8, 0x4000):
    e0 = u64(off)
    if (e0 & 0x3) != 0x3:
        continue
    pa0 = e0 & 0x0000FFFFFFFFC000
    if pa0 < DRAM_BASE or pa0 >= DRAM_BASE + N or (pa0 & 0x3FFF):
        continue
    e1 = u64(off + 8)
    if e1 != 0:
        continue
    # rest of first 1 KiB should be zero
    if data[off + 16:off + 1024].strip(b"\x00"):
        continue
    cands.append(DRAM_BASE + off)
print(f"L0-signature candidates: {len(cands)}")

for root_pa in cands:
    for rl in (0, 1):
        got = walk(root_pa, TARGET_VA, rl)
        if got in GOOD_PAS:
            stack_pa = walk(root_pa, STACK_VA, rl)
            print(f"*** TTBR0 candidate root_pa={root_pa:#x} root_level={rl} "
                  f"code VA->{got:#x} stack VA->{stack_pa}")
        elif got is not None:
            print(f"  root_pa={root_pa:#x} rl={rl} code->{got:#x} (not the anchor)")
print("scan done")
