#!/usr/bin/env python3
"""Phase-5 frozen check: byte-compare key regions between dump1 and dump2
of the SAME boot (argv: dump1 dump2)."""
import hashlib
import sys

sys.path.insert(0, '.')
from p5_common import Ctx

d1, d2 = sys.argv[1], sys.argv[2]
b1 = open(d1, 'rb').read()
b2 = open(d2, 'rb').read()
DRAM = 0x70000000
ctx = Ctx(d1)


def region(va, ln):
    pa = ctx.pa_of(va)
    if pa is None:
        return None
    o = pa - DRAM
    return b1[o:o + ln], b2[o:o + ln]


def cmp(va, ln, label):
    r = region(va, ln)
    if r is None:
        print(f'{label}: VA {va:#x} unmapped')
        return
    x, y = r
    same = x == y
    ndiff = sum(1 for i in range(0, ln, 8)
                if x[i:i + 8] != y[i:i + 8])
    print(f'{label}: {"IDENTICAL" if same else f"DIFFERS ({ndiff} qwords)"} '
          f'md5_1={hashlib.md5(x).hexdigest()} md5_2={hashlib.md5(y).hexdigest()}')


# msgbuf ring (PA-fixed)
o = 0x76A22484 - DRAM
m1, m2 = b1[o:o + 128 * 1024], b2[o:o + 128 * 1024]
print(f'msgbuf ring: {"IDENTICAL" if m1 == m2 else "DIFFERS"} '
      f'md5_1={hashlib.md5(m1).hexdigest()} md5_2={hashlib.md5(m2).hexdigest()}')

# config threads (VAs from dump-1 census of this boot)
for tid, va in [('7c IOResources', 0xFFFFFE184A0D3010),
                ('88 aes', 0xFFFFFE184A0CC040),
                ('cd VirtIO', 0xFFFFFE184A482020),
                ('f9 APFSMedia', 0xFFFFFE184A48B808),
                ('fa APFSMedia', 0xFFFFFE184A48F010),
                ('102 APFSMedia', 0xFFFFFE184A47C838)]:
    cmp(va, 0x600, f'thread {tid} struct[0x600]')

# shared event element + waitq struct
cmp(0xFFFFFE3511F3B6D0, 0x100, 'event element [0x100]')
cmp(0xFFFFFE1DF00CD2A0, 0x100, 'waitq (+0x028 target) [0x100]')

# whole-dump diff fraction (8-byte granularity, sampled every 0x1000)
diff = tot = 0
for o in range(0, len(b1), 0x1000):
    tot += 1
    if b1[o:o + 8] != b2[o:o + 8]:
        diff += 1
print(f'whole-dump sampled qword diff: {diff}/{tot} '
      f'({100.0 * diff / tot:.2f}% of sampled pages touched)')
