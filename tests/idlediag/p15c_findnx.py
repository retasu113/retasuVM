#!/usr/bin/env python3
"""p15c_findnx.py -- find materialisations of &nx_init (VA 0xfffffe000a03ca78)
and of the discriminator 0xb0ff in the APFS exec range of the kernelcache.
File offset = VA - BASE."""
import sys
sys.path.insert(0, '.')
import p15_apfsdis as pd

LO, HI = 0xFFFFFE0009F9D8A0, 0xFFFFFE000B122338
data = pd.data
BASE = pd.BASE

def w(va):
    off = va - BASE
    return int.from_bytes(data[off:off + 4], 'little')

NX = 0xFFFFFE000A03CA78
page = NX & ~0xFFF
hits = []
va = LO
while va < HI - 4:
    insn = w(va)
    if (insn & 0x9F000000) == 0x90000000:  # adrp
        rd = insn & 0x1F
        imm = ((insn >> 3) & 0x1FFFFC) | ((insn >> 29) & 0x3)
        if imm & 0x100000:
            imm -= 0x200000
        tgt_page = (va & ~0xFFF) + (imm << 12)
        if tgt_page == page:
            for j in range(1, 8):
                i2 = w(va + 4 * j)
                if (i2 & 0xFF800000) == 0x91000000:  # add imm
                    rn = (i2 >> 5) & 0x1F
                    im = (i2 >> 10) & 0xFFF
                    if rn == rd and im == (NX & 0xFFF):
                        hits.append(va)
                        break
    va += 4
print('adrp+add &nx_init sites:', [hex(h) for h in hits])
for h in hits:
    print('  near symbol:', pd.sym_near(h))

hits2 = []
va = LO
while va < HI - 4:
    insn = w(va)
    if (insn & 0x7F800000) in (0x52800000, 0x72800000):  # movz/movk
        imm16 = (insn >> 5) & 0xFFFF
        shift = ((insn >> 21) & 0x3) * 16
        if imm16 == 0xB0FF and shift == 0:
            hits2.append(va)
    va += 4
print('mov 0xb0ff sites:', [hex(h) for h in hits2])
for h in hits2:
    print('  near symbol:', pd.sym_near(h))
