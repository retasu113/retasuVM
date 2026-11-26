#!/usr/bin/env python3
"""Phase 26: find VAs for the 3 PAs holding the PCB pointer qword, and dump
the surrounding structs (to identify the thread struct owning the PCB).
Also: find which census thread struct's machine.upcb == PCB (scan a range
of plausible offsets within each thread struct for the PCB qword)."""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx, census_threads

DUMP = sys.argv[1]
PCB = 0xFFFFFE18502ADEE0
PAS = [0x79DAFEA8, 0x80948138, 0x80948140]

ctx = Ctx(DUMP)

for pa in PAS:
    cands = ctx.va_cands(pa)
    print(f"PA {pa:#x} -> VA candidates: {[hex(c) for c in cands]}")
    for va in cands:
        # dump 0x100 B centered 0x40 before the qword
        base = va - 0x40
        raw = ctx.read_va(base, 0x100)
        if raw is None:
            print(f"  VA {va:#x}: unreadable")
            continue
        print(f"  struct around VA {va:#x} (base {base:#x}):")
        for off in range(0, 0x100, 8):
            v = struct.unpack_from("<Q", raw, off)[0]
            mark = " <-- PCB PTR" if base + off == va else ""
            print(f"    +{off:#04x} = {v:#018x}{mark}")

# scan census threads for the PCB qword anywhere in the first 0x1000 B
print("\n--- scanning census thread structs for PCB qword ---")
found = []
for tva in census_threads(ctx):
    raw = ctx.read_va(tva, 0x1000)
    if raw is None:
        continue
    for off in range(0, 0x1000 - 8, 8):
        v = struct.unpack_from("<Q", raw, off)[0]
        if v == PCB:
            found.append((tva, off))
            print(f"  thread {tva:#x}: PCB qword at +{off:#x}")
if not found:
    print("  (no census thread struct contains the PCB qword in its first 0x1000 B)")
