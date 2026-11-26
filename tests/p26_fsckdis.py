#!/usr/bin/env python3
"""Phase 26: dump fsck __TEXT bytes around the FIRE PC (0x100c947c0) via
the TTBR0 walk (root 0x85b70000, root_level=1), so the function can be
disassembled locally. Also dump the SP page's first bytes (to confirm the
stack page is resident) and the bytes at the stack top - 0x308 region.
Run on the PC. Usage: p26_fsckdis.py <dump>
Outputs: p26_fsckdis_out.txt + p26_fsck_pc.bin (raw bytes around PC)
"""
import struct
import sys

sys.path.insert(0, ".")
from p4_lib import Dump, walk

DUMP = sys.argv[1]
ROOT = 0x85B70000
PC = 0x100C947C0
SP = 0x16F1F3CF8

d = Dump(DUMP)
out = open("p26_fsckdis_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


def read_uva(va, n):
    pa = walk(d, ROOT, va, 14, 1)
    if pa is None:
        return None
    return d.read_pa(pa, n)


# PC window: 0x200 bytes before PC to 0x200 after (may cross pages)
start = PC - 0x200
blob = b""
for chunk_va in range(start, PC + 0x200, 0x4000):
    b = read_uva(chunk_va, 0x4000)
    if b is None:
        b = b"\x00" * 0x4000
    blob += b
# trim to the window
blob = blob[:0x400]
open("p26_fsck_pc.bin", "wb").write(blob)
log(f"PC window {start:#x}..{PC + 0x200:#x} ({len(blob)} B) -> p26_fsck_pc.bin")
log(f"PC offset in blob: {PC - start:#x}")
# hex dump of the 64 bytes at PC
pc_off = PC - start
log("bytes at PC (32 B):")
log("  " + blob[pc_off:pc_off + 32].hex())
log("bytes 64 B before PC:")
log("  " + blob[pc_off - 64:pc_off].hex())

# SP page resident?
spb = read_uva(SP & ~0x3FFF, 0x4000)
log(f"\nSP page VA {SP & ~0x3FFF:#x} resident: {spb is not None}")
if spb is not None:
    off = SP - (SP & ~0x3FFF)
    log(f"bytes at SP (32 B): {spb[off:off + 32].hex()}")
    log(f"bytes at SP+0x138 (real uio per p24) (32 B): {spb[off + 0x138:off + 0x138 + 32].hex()}")
out.close()
print("wrote p26_fsckdis_out.txt and p26_fsck_pc.bin")
