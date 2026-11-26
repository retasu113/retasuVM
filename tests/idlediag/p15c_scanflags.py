#!/usr/bin/env python3
"""p15c_scanflags.py -- census of byte loads/stores at offsets
0x158..0x16b (the nx flag cluster) in the APFS exec range."""
import sys, struct
sys.path.insert(0, '.')
import p15_apfsdis as pd

data, BASE = pd.data, pd.BASE
LO, HI = 0xFFFFFE0009F9D8A0, 0xFFFFFE000B122338

def w(va):
    return struct.unpack_from('<I', data, va - BASE)[0]

OFFS = list(range(0x158, 0x16C))
found = {o: [] for o in OFFS}
va = LO
while va < HI - 4:
    insn = w(va)
    # ldrb imm12: 0x39400000 ; strb imm12: 0x39000000
    if (insn & 0xFFC00000) in (0x39400000, 0x39000000):
        im = (insn >> 10) & 0xFFF
        if im in found:
            kind = 'ldrb' if (insn & 0xFFC00000) == 0x39400000 else 'strb'
            found[im].append((va, kind))
    va += 4
for o in OFFS:
    lst = found[o]
    if not lst:
        continue
    print(f'--- offset {o:#x}: {len(lst)} accesses ---')
    seen = {}
    for va, kind in lst:
        sy, off = pd.sym_near(va)
        key = (sy[1] if sy else '?', kind)
        seen.setdefault(key, []).append(va)
    for (fn, kind), vas in sorted(seen.items()):
        print(f'   {kind} in {fn}: {len(vas)}x e.g. {vas[0]:#x}')
