"""Phase 7: annotated kernel stack of one or more threads, plus an
object census of the stack: every distinct heap object referenced from
the stack is class-resolved via its vtable symbol. This names the
candidate/provider objects a blocked config thread was working on
inside doServiceMatch -> probeCandidates -> startCandidate.
Usage: python3 p7_stack.py <dump> <thread_va> [thread_va...]
"""
import struct
import sys
from collections import Counter

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, make_sym, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return None
    return syms.get(vt - 0x10 - SLIDE)


for tva in (int(x, 0) for x in sys.argv[2:]):
    ti = thread_info(ctx, tva)
    print(f'===== thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
          f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x} '
          f'state=0x{ti["state_byte"]:02x} =====')
    raw = ctx.read_va(ti['stack_va'], 0x4000)
    print('-- kernel-text return addresses (stack order) --')
    for off in range(0, 0x4000, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if 0xFFFFFE001F000000 <= v < 0xFFFFFE0021000000:
            print(f'  +{off:#06x}: {v:#x}  {bracket(v)}')
    print('-- distinct heap objects referenced from stack (by class) --')
    objs = Counter()
    example = {}
    for off in range(0, 0x4000, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if 0xFFFFFE1000000000 <= v < 0xFFFFFE8000000000:
            c = class_of(v)
            if c:
                objs[c] += 1
                example.setdefault(c, v)
    for c, n in objs.most_common():
        print(f'  {c}  x{n}  e.g. {example[c]:#x}')
