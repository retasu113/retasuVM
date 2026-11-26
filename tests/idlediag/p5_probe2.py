#!/usr/bin/env python3
"""Phase-5 probe round 2 (argv: dump [dump_phase1])."""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

THREADS = {
    '7c IOResources': 0xFFFFFE184A0D3010,
    '88 aes': 0xFFFFFE184A0CC040,
    'cd VirtIO': 0xFFFFFE184A482020,
    'f9 APFSMedia': 0xFFFFFE184A48B808,
    'fa APFSMedia': 0xFFFFFE184A48F010,
    '102 APFSMedia': 0xFFFFFE184A47C838,
}
for name, t in THREADS.items():
    print(f'{name}: +0x000={Q(t):#x} +0x008={Q(t + 8):#x} '
          f'+0x018={Q(t + 0x18):#x} +0x028={Q(t + 0x28):#x} '
          f'+0x7D8={Q(t + 0x7D8):#x}')

WQ = 0xFFFFFE1DF00CD2A0
print(f'--- waitq chain walk from {WQ:#x} ---')
cur, seen = WQ, set()
for i in range(6):
    if cur in seen or cur is None:
        break
    seen.add(cur)
    vals = [Q(cur + o) for o in (0x00, 0x08, 0x10, 0x18, 0x48)]
    print(f'  wq {cur:#x}: ' + ' '.join(
        f'+{o:#x}={v:#x}' if v is not None else f'+{o:#x}=?'
        for o, v in zip((0x00, 0x08, 0x10, 0x18, 0x48), vals)))
    cur = vals[3]

# live elements in the event's 16K page: 16B elements [hdr, payload]
EV = 0xFFFFFE3511F3B6D8
page = EV & ~0x3FFF
print(f'--- non-common elements in event page {page:#x} ---')
for off in range(0, 0x4000, 16):
    h, p = Q(page + off), Q(page + off + 8)
    if h != 0x0000010F22000000 or p != 0:
        print(f'  elem {page + off:#x}: hdr={h:#x} payload={p:#x}')

# phase-1 cross-check if a second dump is given
if len(sys.argv) > 2:
    c1 = Ctx(sys.argv[2])
    Q1 = c1.Qva
    # phase-1 shared waiters (phase-4 VAs)
    for name, t in [('7c', 0xFFFFFE239BF24838), ('dd', 0xFFFFFE239BDE1828)]:
        w = Q1(t + 0x28)
        print(f'phase1 {name}: +0x028={w:#x} '
              f'wq+0x48={Q1(w + 0x48) if w else None} '
              f'wq+0x08={Q1(w + 8) if w else None} '
              f'wq+0x10={Q1(w + 0x10) if w else None}')
