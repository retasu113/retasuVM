"""Phase 4 step 18: identify the object containing the shared wait_event
0xFFFFFE2FEA093818 — scan backwards for a vtable pointer (__ZTV symbol)
or a known-global start; also scan forwards.
"""
import bisect
import json
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk

D1 = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(D1)
ROOT = 0x77B98000
GATE = 0xFFFFFE2FEA093818
SLIDE = 0x182B4000

syms = sorted(json.load(open('kc_syms_mine.json'))['syms'])
saddrs = [s[0] for s in syms]


def sym(rtva):
    link = rtva - SLIDE
    i = bisect.bisect_right(saddrs, link) - 1
    if i >= 0:
        return f'{syms[i][1]} +{link - syms[i][0]:#x}'
    return '?'


def Q(va):
    pa = walk(d, ROOT, va, 14, 1)
    return None if pa is None else d.u64_pa(pa)


print('scan GATE-0x4000 .. GATE+0x100 for vtable-like pointers:')
for off in range(-0x4000, 0x100, 8):
    v = Q(GATE + off)
    if v is None:
        continue
    s = sym(v)
    if '__ZTV' in s or 'gMetaClass' in s:
        print(f'  GATE{off:+#x}: {v:#x} -> {s}')
print('done')
# also: what symbol range is the GATE page in? dump first qwords of the
# containing 16K page
page = GATE & ~0x3FFF
print(f'GATE page base {page:#x}:')
for off in range(0, 0x100, 8):
    v = Q(page + off)
    if v:
        print(f'  +{off:#04x}: {v:#018x}  {sym(v) if v > 0xFFFFFE0000000000 else ""}')
