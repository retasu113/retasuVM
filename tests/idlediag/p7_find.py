"""Phase 7: locate thread structs via their name-string pointer.
A thread's +0x7D8 field holds the VA of its heap name string; scanning
the dump for that VA finds the struct even when the record census
misses it (gfx/IOResources at fpms1). For each hit, the candidate base
is hit-0x7D8; validate via id/stack and print full wait state.
Usage: python3 p7_find.py <dump> <name_va> [name_va...]
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

for arg in sys.argv[2:]:
    target = int(arg, 0)
    pat = struct.pack('<Q', target)
    print(f'===== holders of name string {target:#x} '
          f'({ctx.read_cstr(target, 64)!r}) =====')
    for sva, spa, ln in ctx.segs:
        if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
            continue
        raw = ctx.d.read_pa(spa, ln)
        idx = 0
        while True:
            j = raw.find(pat, idx)
            if j < 0:
                break
            idx = j + 8
            hit = sva + j
            tva = hit - 0x7D8
            ti = thread_info(ctx, tva)
            ok = ti and ti['stack_va'] and ti['name'] == ctx.read_cstr(
                target, 64)
            print(f'  hit {hit:#x}: candidate thread {tva:#x} '
                  f'plausible={bool(ok)}'
                  + (f' id={ti["id"]:#x} wait={ti["wait_event"]:#x} '
                     f'waitq={Q(tva + 0x28):#x} ts={Q(tva + 0x30):#x} '
                     f'state=0x{ti["state_byte"]:02x} '
                     f'stack={ti["stack_va"]:#x}' if ti else ''))
