#!/usr/bin/env python3
# scan9: cpu_data cross-reference + found-stack ownership + stack top dump.
# Usage: scan9.py <dump> <hits.txt>
import sys, struct

DUMP, HITS = sys.argv[1], sys.argv[2]
DRAM = 0x70000000
OFF = 0xFFFFFDFFAC000000
C8F = 0xFFFFFE8F414E0000
f = open(DUMP, 'rb')

def rd64o(o):
    f.seek(o); return struct.unpack('<Q', f.read(8))[0]

def rdbytes(o, n):
    f.seek(o); return f.read(n)

# tro records
hits = [int(x, 16) for x in open(HITS).read().split()]
runs = []
i = 0
while i < len(hits):
    j = i
    while j + 1 < len(hits) and hits[j + 1] - hits[j] == 0x120:
        j += 1
    if j - i + 1 >= 8:
        runs.append((i, j))
    i = j + 1
recs = []
for (a, b) in runs:
    for k in range(a, b + 1):
        recs.append(hits[k])
fld = {0x20: {}, 0x38: {}, 0x40: {}, 0x110: {}}
for r in recs:
    for off in fld:
        fld[off].setdefault(rd64o(r + off), []).append(r)
print(f"[tro] records={len(recs)}")

# 1) cpu_data dump + cross-reference
CPU = 0x39C6000
print(f"[cpu_data] dump_off=0x{CPU:x}")
for i in range(0, 0x600, 8):
    v = rd64o(CPU + i)
    if v == 0:
        continue
    notes = []
    for off, m in fld.items():
        if v in m:
            notes.append(f"== tro+0x{off:x} of rec(s) {[hex(x) for x in m[v][:3]]}")
    if v - C8F >= DRAM and v - C8F < DRAM + 0x100000000:
        notes.append(f"C8F->PA 0x{v - C8F:x}")
    if v - OFF >= DRAM and v - OFF < DRAM + 0x100000000:
        notes.append(f"OFF->PA 0x{v - OFF:x}")
    print(f"   +0x{i:03x}: 0x{v:016x} {' '.join(notes)}")

# 2) which tro's +0x40 (C8F) lands in the found stack neighbourhood?
print("[stack-owner] tro +0x40 C8F-decoded into [0x76a80000,0x76ac0000):")
for v, rs in fld[0x40].items():
    pa = v - C8F
    if 0x76A80000 <= pa < 0x76AC0000:
        print(f"   v=0x{v:x} -> PA 0x{pa:x} recs={[hex(x) for x in rs[:3]]}")

# 3) found stack: qwords around chain top and region top
print("[stack] region dump_off 0x6a90000: nonzero qwords 0x6a9c000..0x6aa0000:")
for o in range(0x6A9C000, 0x6AA0000, 8):
    v = rd64o(o)
    if v:
        print(f"   0x{o:x}: 0x{v:016x}")
