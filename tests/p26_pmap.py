#!/usr/bin/env python3
"""Phase 26: read launchd's and fsck's pmap structs (ttep at +0x08 is the
physical TTBR0 root per osfmk/arm/pmap/pmap.h). Compare with the +0x218
field used by the phase-24 calibration. Determines whose TTBR0 root
0x85b70000 really is.
Run on the PC. Usage: p26_pmap.py <dump>
Outputs: p26_pmap_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx

DUMP = sys.argv[1]
LAUNCHD_PMAP = 0xFFFFFE2299FE1090
FSCK_PMAP = 0xFFFFFE2299FE12A0

ctx = Ctx(DUMP)
out = open("p26_pmap_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


def qva(va):
    b = ctx.read_va(va, 8)
    return struct.unpack("<Q", b)[0] if b else None


for name, pmap in (("launchd", LAUNCHD_PMAP), ("fsck", FSCK_PMAP)):
    log(f"--- {name} pmap @ {pmap:#x} ---")
    for off in (0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38,
                0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78,
                0x200, 0x208, 0x210, 0x218, 0x220, 0x228, 0x230):
        v = qva(pmap + off)
        log(f"  pmap+{off:#04x} = {v if v is None else hex(v)}")
    log("")
out.close()
print("wrote p26_pmap_out.txt")
