"""Phase 6: (a) full annotated kernel stack of the shared waiters
[7c] and [102] — every kernel-text pointer with its symbol bracket, in
stack order, to name the exact blocking call path; (b) roster of all
heap "IOConfigThread_..." name strings mapped back to thread structs.
Usage: python3 p6_stack.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, make_sym  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()

for tva, label in ((0xFFFFFE184A0D3010, '[7c] IOResources'),
                   (0xFFFFFE184A47C838, '[102] AppleAPFSMedia')):
    ti = thread_info(ctx, tva)
    print(f'===== stack of {label} thread {tva:#x} =====')
    raw = ctx.read_va(ti['stack_va'], 0x4000)
    for off in range(0, 0x4000, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if 0xFFFFFE001F000000 <= v < 0xFFFFFE0021000000:
            print(f'  +{off:#06x}: {v:#x}  {bracket(v)}')

print('\n===== heap IOConfigThread_ name roster =====')
pat = b"IOConfigThread_'"
names = []
for sva, spa, ln in ctx.segs:
    if ln > (1 << 28):
        continue
    raw = ctx.d.read_pa(spa, ln)
    idx = 0
    while True:
        j = raw.find(pat, idx)
        if j < 0:
            break
        idx = j + 1
        s = ctx.read_cstr(sva + j, 64)
        if s and sva + j > 0xFFFFFE2000000000:  # heap tags only
            names.append((sva + j, s))
threads = census_threads(ctx)
by_name_ptr = {}
for tva in threads:
    np = Q(tva + 0x7D8)
    if np:
        by_name_ptr[np] = tva
for nva, s in sorted(set(names)):
    tva = by_name_ptr.get(nva)
    extra = ''
    if tva:
        ti = thread_info(ctx, tva)
        extra = (f' -> thread {tva:#x} id={ti["id"]:#x} '
                 f'wait={ti["wait_event"]:#x}')
    print(f'  {nva:#x} {s!r}{extra}')
