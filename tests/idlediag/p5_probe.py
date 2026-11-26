#!/usr/bin/env python3
"""Phase-5 targeted probes on one dump (argv: dump)."""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, make_sym

ctx = Ctx(sys.argv[1])
_sym = make_sym()
data = open(sys.argv[1], 'rb').read()
DRAM = 0x70000000


def hexdump(va, span_lo, span_hi, label):
    print(f'--- {label} around {va:#x} ---')
    for off in range(-span_lo, span_hi, 16):
        a = va + off
        q1, q2 = ctx.Qva(a), ctx.Qva(a + 8)
        if q1 is None:
            continue
        s1 = _sym(q1) if 0xFFFFFE0000000000 <= q1 < 0xFFFFFE0040000000 else ''
        print(f'  {off:+#06x}: {q1:#018x} {q2:#018x} {s1}')


WAITERS = [0xFFFFFE184A0D3010, 0xFFFFFE184A48B808, 0xFFFFFE184A47C838]
SHARED28 = 0xFFFFFE1DF00CD2A0

# 1. the identical +0x028 target
hexdump(SHARED28, 0x80, 0x100, 'shared +0x028 target')

# 2. who points at each waiter thread struct (waitq linkage?)
for t in WAITERS:
    pat = struct.pack('<Q', t)
    holders = []
    j = data.find(pat)
    while j != -1 and len(holders) < 24:
        holders.append(ctx.va_cands(j + DRAM))
        j = data.find(pat, j + 1)
    print(f'holders of thread {t:#x}: {holders}')

# 3. IOKit job globals' targets (from p5_globals on this dump family)
hexdump(0xFFFFFE3511FF6F10, 0x20, 0x60, 'gJobsLock target (link A7D4470)')
hexdump(0xFFFFFE2293F6FC00, 0x20, 0x60, 'link A7D4530 target (pingConfig+startMatching)')
hexdump(0xFFFFFE3511FF7600, 0x20, 0x60, 'link A7D4480 target (startMatching)')

# 4. event array extent: elements are 16B [tag, payload]; walk out from
# the event while the tag slot keeps the 0x0000010f22...... shape
EV = 0xFFFFFE3511F3B6D8
ev_pa = ctx.pa_of(EV)


def tag_at(pa):
    return struct.unpack_from('<Q', data, pa - DRAM)[0]


lo = ev_pa
while lo - 0x10 >= DRAM:
    t = tag_at(lo - 0x10)
    if (t >> 24) != 0x0000010F22 and t != 0:
        break
    lo -= 0x10
hi = ev_pa
while hi + 0x10 < DRAM + len(data):
    t = tag_at(hi + 0x10)
    if (t >> 24) != 0x0000010F22 and t != 0:
        break
    hi += 0x10
print(f'event array approx PA span: {lo:#x}..{hi:#x} '
      f'({(hi - lo) // 16} elements of 16B)')
for pa in (lo, lo + 0x10, hi - 0x10):
    vas = ctx.va_cands(pa)
    print(f'  elem PA {pa:#x} VAs {vas} tag={tag_at(pa):#x} '
          f'payload={tag_at(pa + 8):#x}')
