#!/usr/bin/env python3
# scan10: test zone-0x23 decode hypothesis PA = low32(v) by looking for the
# known kernel_task pointer value inside candidate thread structs.
# Usage: scan10.py <dump> <hits.txt>
import sys, struct

DUMP, HITS = sys.argv[1], sys.argv[2]
KT = 0xFFFFFE249E0FC0A8
f = open(DUMP, 'rb')

def rd64o(o):
    f.seek(o); return struct.unpack('<Q', f.read(8))[0]

def probe(name, v):
    pa = v & 0xFFFFFFFF
    do = pa - 0x70000000
    print(f"[{name}] v=0x{v:x} -> PA 0x{pa:x} dump_off 0x{do:x}")
    if do < 0 or do + 0x200 > 0x100000000:
        print("    out of range"); return
    found = []
    for i in range(0, 0x200, 8):
        q = rd64o(do + i)
        if q == KT:
            found.append(f"+0x{i:x} == kernel_task")
        elif (q >> 32) in (0xFFFFFE23, 0xFFFFFE24, 0xFFFFFE29, 0xFFFFFE2F, 0xFFFFFE8F, 0xFFFFFE00):
            found.append(f"+0x{i:x} = 0x{q:x}")
    for s in found[:20]:
        print("   ", s)
    if not found:
        qs = [rd64o(do + i) for i in range(0, 0x80, 8)]
        print("    first qwords:", [hex(x) for x in qs])

# cpu_data thread candidates
for nm, v in (("cpu+0x428", 0xFFFFFE239BF5C590), ("cpu+0x430", 0xFFFFFE239BF5F0E0), ("cpu+0x438", 0xFFFFFE239BF5F920)):
    probe(nm, v)

# tro +0x110 samples from the 3-record window
for r in (0xA048150, 0xA048270, 0xA048390):
    probe(f"tro@0x{r:x}+0x110", rd64o(r + 0x110))
