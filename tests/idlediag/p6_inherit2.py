"""Phase 6: scan the thread zone for ANY holder of the chain turnstiles
CD840 / CFF40 (candidate thread+0x30), and validate the container as a
thread struct even if the record census missed it.
Usage: python3 p6_inherit2.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

for target, label in ((0xFFFFFE1DF00CD840, 'chain ts #2'),
                      (0xFFFFFE1DF00CFF40, 'chain ts #3')):
    pat = struct.pack('<Q', target)
    print(f'--- holders of {label} {target:#x} ---')
    for sva, spa, ln in ctx.segs:
        if not (0xFFFFFE1840000000 <= sva < 0xFFFFFE1850000000):
            continue
        try:
            raw = ctx.d.read_pa(spa, ln)
        except ValueError:
            continue
        idx = 0
        while True:
            j = raw.find(pat, idx)
            if j < 0:
                break
            idx = j + 8
            hit = sva + j
            tva = hit - 0x30
            ti = thread_info(ctx, tva)
            ok = ti and ti['stack_va']
            print(f'  holder {hit:#x}: candidate thread {tva:#x} '
                  f'valid={bool(ok)}'
                  + (f' id={ti["id"]:#x} name={ti["name"]!r} '
                     f'wait={ti["wait_event"]:#x}' if ok else ''))
