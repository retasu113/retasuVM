"""Phase 7: FP-chain walk of a blocked thread. The saved context at
thread +0x148 carries SP (ctx+0x50) and FP (ctx+0x60); walking the
frame records [FP]=prevFP, [FP+8]=LR from there gives the TRUE live
call chain (no residue). LR values are symbol-bracketed.
Usage: python3 p7_fp.py <dump> <thread_va> [thread_va...]
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, make_sym  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()

for tva in (int(x, 0) for x in sys.argv[2:]):
    ti = thread_info(ctx, tva)
    base = ti['stack_va']
    craw = ctx.read_va(ti['saved_ctx'], 0x70)
    sp = struct.unpack_from('<Q', craw, 0x50)[0]
    fp = struct.unpack_from('<Q', craw, 0x60)[0]
    print(f'===== thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
          f'wait={ti["wait_event"]:#x} saved_sp=+{sp - base:#x} '
          f'saved_fp=+{fp - base:#x} =====')
    seen = set()
    cur = fp
    for depth in range(40):
        if not (base <= cur < base + 0x4000) or cur in seen:
            print(f'  chain ends at fp={cur:#x}')
            break
        seen.add(cur)
        raw = ctx.read_va(cur, 16)
        if raw is None:
            print(f'  fp {cur:#x} unreadable')
            break
        prev, lr = struct.unpack('<QQ', raw)
        print(f'  frame +{cur - base:#05x}: lr={lr:#x}  {bracket(lr)}')
        if prev == 0 or prev == cur:
            print('  chain ends (prev=0/self)')
            break
        cur = prev
