"""Phase 6: [fa]-role thread stack-event forensics + FP-walk comparison.

Usage: python3 p6_fa.py <dump> <fa_thread_va> [extra_thread_va ...]
- FP-walk each thread from its saved context, symbolicating every frame.
- For the first thread (the [fa] role): dissect the stack-resident event
  (bytes around it, its waitq's full struct + queue, dump-wide holders
  of the event address), and identify which FP frame owns the event.
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, make_sym, DRAM  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
sym = make_sym()
data = open(dump, 'rb').read()
TEXT_LO, TEXT_HI = 0xFFFFFE001E000000, 0xFFFFFE0023400000


def fp_walk(tva, ti):
    stack = ti['stack_va']
    sraw = ctx.read_va(stack, 0x4000)
    print(f"== FP walk: {ti['name']!r} id={ti['id']:#x} "
          f"wait={ti['wait_event']:#x} stack={stack:#x} "
          f"saved_ctx={ti['saved_ctx']:#x}")
    if sraw is None or not ti['saved_ctx']:
        print('   (no stack / no saved ctx)')
        return []
    frames = []  # (fp_off, lr)
    off = ti['saved_ctx'] - stack
    seen = set()
    for depth in range(40):
        if off in seen or not (0 <= off < 0x4000 - 16):
            break
        seen.add(off)
        fp = struct.unpack_from('<Q', sraw, off)[0]
        lr = struct.unpack_from('<Q', sraw, off + 8)[0]
        frames.append((off, lr))
        print(f'   [{depth:2d}] fp_off={off:#06x} lr={lr:#x} -> {sym(lr)}')
        if not (stack <= fp < stack + 0x4000):
            break
        off = fp - stack
    return frames


targets = [int(a, 16) for a in sys.argv[2:]]
infos = {}
for tva in targets:
    ti = thread_info(ctx, tva)
    infos[tva] = ti
    fp_walk(tva, ti)
    print()

fa = targets[0]
ti = infos[fa]
stack = ti['stack_va']
ev = ti['wait_event']
print(f'===== [fa] event forensics: event={ev:#x} '
      f'(stack+{ev - stack:#x}) =====')
sraw = ctx.read_va(stack, 0x4000)
eoff = ev - stack
for off in range(eoff - 0x40, eoff + 0x60, 8):
    v = struct.unpack_from('<Q', sraw, off)[0]
    note = ''
    if TEXT_LO <= v < TEXT_HI:
        note = f' -> {sym(v)}'
    elif stack <= v < stack + 0x4000:
        note = f' (stack+{v - stack:#x})'
    print(f'   stack+{off:#06x}: {v:#018x}{note}')

wq = ctx.Qva(fa + 0x28)
print(f'\n[fa] waitq = {wq:#x}')
if wq:
    for off in range(0, 0x60, 8):
        v = ctx.Qva(wq + off)
        note = ''
        if v is not None and stack <= v < stack + 0x4000:
            note = f' (stack+{v - stack:#x})'
        print(f'   wq+{off:#04x}: {v if v is None else hex(v)}{note}')

print(f'\n--- dump-wide holders of [fa] event {ev:#x} ---')
pat = struct.pack('<Q', ev)
j = data.find(pat)
n = 0
while j != -1:
    if j % 8 == 0:
        n += 1
        hpa = j + DRAM
        print(f'   PA {hpa:#x} VAs {[hex(v) for v in ctx.va_cands(hpa)]}')
    j = data.find(pat, j + 1)
print(f'   {n} aligned holders')

# who else waits on an event inside [fa]'s stack page range?
print('\n--- threads waiting on events in [fa] stack range ---')
from p5_common import census_threads  # noqa: E402
for tva in census_threads(ctx):
    t2 = thread_info(ctx, tva)
    if t2 and stack <= t2['wait_event'] < stack + 0x4000:
        print(f"   {t2['name']!r} id={t2['id']:#x} thread={tva:#x} "
              f"wait={t2['wait_event']:#x}")
