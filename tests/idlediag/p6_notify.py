"""Phase 6: (1) confirm OSSymbol string decode via char* at +0x10;
(2) scan the whole dump for _IOServiceNotifier instances and list the
ACTIVE waits (ref field +0x40 != 0): the waiting thread is identified by
whose kernel stack contains the ref address.
Usage: python3 p6_notify.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
d = load_syms()
exact = {a: n for a, n in d['syms']}
NOTIF_VT = None
for a, n in d['syms']:
    if n == '__ZTV18_IOServiceNotifier':
        NOTIF_VT = a + SLIDE + 0x10
print(f'notifier vtable runtime = {NOTIF_VT:#x}')


def symstr(obj):
    p = Q(obj + 0x10)
    if p:
        return ctx.read_cstr(p, 96)
    return None


print('type symbol of [fa] notifier:',
      repr(symstr(0xFFFFFE1DF00F0A20)))

threads = census_threads(ctx)
by_stack = {}
for tva in threads:
    ti = thread_info(ctx, tva)
    if ti and ti['stack_va']:
        by_stack[ti['stack_va']] = (tva, ti)

pat = struct.pack('<Q', NOTIF_VT)
print('--- _IOServiceNotifier instances with ref != 0 (active waits) ---')
n = 0
for sva, spa, ln in ctx.segs:
    raw = ctx.d.read_pa(spa, ln)
    idx = 0
    while True:
        j = raw.find(pat, idx)
        if j < 0 or j % 8:
            if j < 0:
                break
            idx = j + 1
            continue
        idx = j + 8
        obj = sva + j
        ref = Q(obj + 0x40)
        handler = Q(obj + 0x28)
        matching = Q(obj + 0x18)
        n += 1
        owner = None
        if ref:
            for sva2, (tva, ti) in by_stack.items():
                if sva2 <= ref < sva2 + 0x4000:
                    owner = (tva, ti)
                    break
        hn = exact.get(handler - SLIDE, '?') if handler else '?'
        print(f'  notifier {obj:#x} handler={hn} matching={matching:#x} '
              f'ref={ref:#x}')
        if owner:
            tva, ti = owner
            print(f'      WAITER thread {tva:#x} id={ti["id"]:#x} '
                  f'name={ti["name"]!r}')
print(f'total notifier instances: {n}')
