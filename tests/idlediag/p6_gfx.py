"""Phase 6: (1) find the 'gfx' config thread via its heap name string;
(2) proper FP-walk from the saved arm_saved_state (fp @ ctx+0xE8,
lr @ ctx+0xF0, pc @ ctx+0x100) for [fa], [7c] and any gfx candidate;
(3) identify the heap object referencing [fa]'s stack event.

Usage: python3 p6_gfx.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, make_sym, DRAM  # noqa: E402

ctx = Ctx(sys.argv[1])
sym = make_sym()
data = open(sys.argv[1], 'rb').read()
Q = ctx.Qva
MSGBUF_LO, MSGBUF_HI = 0x76A20000, 0x76A80000

# --- 1. gfx heap name aliases + referrers ---
gfx_pas = set()
i = data.find(b"IOConfigThread_'gfx'")
while i != -1:
    pa = i + DRAM
    if not (MSGBUF_LO <= pa < MSGBUF_HI):
        gfx_pas.add(pa)
    i = data.find(b"IOConfigThread_'gfx'", i + 1)
aliases = set()
for pa in gfx_pas:
    aliases.update(ctx.va_cands(pa))
print(f'gfx name instances: {len(gfx_pas)} PAs, aliases: '
      f'{[hex(a) for a in sorted(aliases)]}')

gfx_threads = []
for av in sorted(aliases):
    pat = struct.pack('<Q', av)
    j = data.find(pat)
    while j != -1:
        if j % 8 == 0:
            hit_pa = j + DRAM
            for hva in ctx.va_cands(hit_pa):
                tva = hva - 0x7D8
                ti = thread_info(ctx, tva)
                if ti and ti['name'] and 'gfx' in ti['name']:
                    gfx_threads.append(tva)
                    print(f'  FOUND gfx thread {tva:#x} id={ti["id"]:#x} '
                          f'wait={ti["wait_event"]:#x} '
                          f'waitq={Q(tva + 0x28):#x} '
                          f'stack={ti["stack_va"]:#x} '
                          f'state=0x{ti["state_byte"]:02x}')
        j = data.find(pat, j + 1)
if not gfx_threads:
    print('  no gfx thread found via name pointers')

# --- 2. FP-walk from saved state ---
TEXT_LO, TEXT_HI = 0xFFFFFE001E000000, 0xFFFFFE0023400000


def fp_walk(tva, label):
    ti = thread_info(ctx, tva)
    stack = ti['stack_va']
    ctxp = Q(tva + 0x148)
    print(f'\n== FP walk {label}: {ti["name"]!r} id={ti["id"]:#x} '
          f'stack={stack:#x} saved_ctx_ptr={ctxp if ctxp is None else hex(ctxp)}')
    if not ctxp:
        return
    base = ctxp
    fp = Q(base + 0xE8)
    lr = Q(base + 0xF0)
    pc = Q(base + 0x100)
    print(f'   saved: pc={pc if pc is None else hex(pc)} '
          f'({sym(pc) if pc else ""}) lr={lr if lr is None else hex(lr)} '
          f'fp={fp if fp is None else hex(fp)}')
    seen = set()
    cur = fp
    for depth in range(32):
        if not cur or cur in seen or not (stack <= cur < stack + 0x4000):
            break
        seen.add(cur)
        nfp = Q(cur)
        nlr = Q(cur + 8)
        print(f'   [{depth:2d}] fp=stack+{cur - stack:#05x} '
              f'lr={nlr if nlr is None else hex(nlr)} -> '
              f'{sym(nlr) if nlr else ""}')
        cur = nfp


fp_walk(0xFFFFFE184A48F010, '[fa] APFSMedia')
fp_walk(0xFFFFFE184A0D3010, '[7c] IOResources')
for t in gfx_threads:
    fp_walk(t, '[9c?] gfx')

# --- 3. heap object referencing [fa]'s stack event ---
HOLD = 0xFFFFFE23960FE580
print(f'\n== heap object at {HOLD:#x} (its +0x40 -> [fa] stack event) ==')
for off in range(-0x80, 0x100, 8):
    v = Q(HOLD + off)
    note = ''
    if v and TEXT_LO <= v < TEXT_HI:
        note = f' -> {sym(v)}'
    print(f'  {off:+#06x}: {v if v is None else hex(v)}{note}')
