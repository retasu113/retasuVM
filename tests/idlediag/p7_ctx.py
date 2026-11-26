"""Phase 7: decode a thread's saved machine context (thread +0x148):
print every qword of the context struct, bracket kernel-text values as
candidate saved PCs, and mark values inside the thread's kernel stack
as candidate saved SP/FP. The saved SP bounds the LIVE stack frames
(everything at/above it) from residue (below it).
Usage: python3 p7_ctx.py <dump> <thread_va> [thread_va...]
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
    sp_lo, sp_hi = ti['stack_va'], ti['stack_va'] + 0x4000
    print(f'===== thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
          f'stack={sp_lo:#x}..{sp_hi:#x} saved_ctx={ti["saved_ctx"]:#x} =====')
    raw = ctx.read_va(ti['saved_ctx'], 0x120)
    if raw is None:
        print('  saved_ctx unreadable')
        continue
    for off in range(0, 0x120, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        note = ''
        if sp_lo <= v < sp_hi:
            note = f'  <== STACK ptr (stack offset {v - sp_lo:#x})'
        elif 0xFFFFFE001F000000 <= v < 0xFFFFFE0021000000:
            note = f'  <== TEXT {bracket(v)}'
        if note or v:
            print(f'  ctx+{off:#04x}: {v:#x}{note}')
