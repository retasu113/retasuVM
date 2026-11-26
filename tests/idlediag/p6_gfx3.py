"""Phase 6: (a) census-independent scan for a thread struct with
id 0x9c in the thread zone; (b) AppleParavirtDisplay object fields
beyond +0xC0 — find the display shared-state page and read its
guest-visible state (event/seq/ack/state words).
Usage: python3 p6_gfx3.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}

print('===== scan thread zone for id 0x9c =====')
hits = 0
for sva, spa, ln in ctx.segs:
    if not (0xFFFFFE1840000000 <= sva < 0xFFFFFE1850000000):
        continue
    try:
        raw = ctx.d.read_pa(spa, ln)
    except ValueError:
        continue
    for off in range(0, ln - 0x7E0, 8):
        if struct.unpack_from('<Q', raw, off + 0x498)[0] != 0x9c:
            continue
        tva = sva + off
        ti = thread_info(ctx, tva)
        if ti and ti['stack_va']:
            hits += 1
            print(f'  thread {tva:#x} id=0x9c name={ti["name"]!r} '
                  f'wait={ti["wait_event"]:#x} '
                  f'waitq={Q(tva + 0x28):#x} stack={ti["stack_va"]:#x}')
print(f'  validated id-0x9c threads: {hits}')

print('\n===== AppleParavirtDisplay fields +0xC0..+0x400 =====')
DISP = 0xFFFFFE2293FDC000
state_ptrs = []
for off in range(0xC0, 0x400, 8):
    v = Q(DISP + off)
    if v and v > 0xFFFFFE0000000000:
        c = syms.get(v - 0x10 - SLIDE, '')
        print(f'  +{off:#05x}: {v:#x} {c}')
        if v >> 40 == 0xFFFFFE8E >> 8 or (v & 0xFFFFFF0000000000) == 0xFFFFFE8E00000000:
            state_ptrs.append((off, v))
print('tag-0x8E pointers:', [(f'{o:#x}', f'{v:#x}') for o, v in state_ptrs])

for off, v in state_ptrs:
    print(f'\n--- candidate state page at {v:#x} (disp+{off:#x}) ---')
    for soff, label in ((0x100, 'event'), (0x200, 'seq'),
                        (0xFA9, 'ack-pending byte'), (0xFC0, 'state')):
        if label.endswith('byte'):
            b = ctx.read_va(v + soff, 1)
            print(f'  +{soff:#x} {label}: {b.hex() if b else None}')
        else:
            print(f'  +{soff:#x} {label}: {Q(v + soff):#x}')
