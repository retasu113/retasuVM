"""Phase 7: raw annotated dump of a thread's kernel-stack range:
every qword classified as TEXT (symbol bracket), HEAP object (vtable
class), STACK ptr, or plain value. For manual frame reconstruction.
Usage: python3 p7_raw.py <dump> <thread_va> <lo_off_hex> <hi_off_hex>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, make_sym, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()
syms = {a: n for a, n in load_syms()['syms']}

tva = int(sys.argv[2], 0)
lo = int(sys.argv[3], 0)
hi = int(sys.argv[4], 0)
ti = thread_info(ctx, tva)
print(f'thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
      f'wait={ti["wait_event"]:#x} stack={ti["stack_va"]:#x}')
raw = ctx.read_va(ti['stack_va'], 0x4000)
for off in range(lo, hi, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    note = ''
    if 0xFFFFFE001F000000 <= v < 0xFFFFFE0021000000:
        note = f'TEXT {bracket(v)}'
    elif 0xFFFFFE1000000000 <= v < 0xFFFFFE8000000000:
        vt = Q(v)
        c = syms.get(vt - 0x10 - SLIDE) if vt else None
        note = f'OBJ class={c}' if c else 'heap ptr'
    elif ti['stack_va'] <= v < ti['stack_va'] + 0x4000:
        note = f'STACK +{v - ti["stack_va"]:#x}'
    if v or note:
        print(f'  +{off:#06x}: {v:#018x}  {note}')
