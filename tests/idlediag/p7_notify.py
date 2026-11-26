"""Phase 7: all ACTIVE waitForMatchingService waits in a dump
(_IOServiceNotifier instances with ref != 0), each with its decoded
matching dictionary and the waiter thread identified by whose kernel
stack contains the ref address. Generalized from p6_notify/p6_dict5.
Usage: python3 p7_notify.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}
exact = {a + SLIDE: n for a, n in load_syms()['syms']}
NOTIF_VT = None
for a, n in load_syms()['syms']:
    if n == '__ZTV18_IOServiceNotifier':
        NOTIF_VT = a + SLIDE + 0x10
print(f'notifier vtable runtime = {NOTIF_VT:#x}')


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return '?'
    return syms.get(vt - 0x10 - SLIDE, '?')


def decode(obj):
    if not obj:
        return None
    p = Q(obj + 0x10)
    if p and 0xFFFFFE0000000000 <= p < 0xFFFFFF0000000000:
        s = ctx.read_cstr(p, 96)
        if s and all(32 <= ord(c) < 127 for c in s):
            return s
    for off in (0x10, 0x18, 0x14, 0x20):
        s = ctx.read_cstr(obj + off, 96)
        if s and len(s) >= 2 and all(32 <= ord(c) < 127 for c in s):
            return s
    return None


def decode_dict(daddr, depth=0):
    out = []
    if not daddr or class_of(daddr) != '__ZTV12OSDictionary':
        return out
    entries = Q(daddr + 0x20)
    if not entries:
        return out
    for i in range(6):
        k = Q(entries + i * 16)
        v = Q(entries + i * 16 + 8)
        if not k:
            break
        out.append('  ' * depth + f'{decode(k)!r} -> {decode(v)!r} '
                                   f'({class_of(v)})')
        if class_of(v) == '__ZTV12OSDictionary':
            out += decode_dict(v, depth + 1)
    return out


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
    if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
        continue  # MMIO-mapped segment, not in the DRAM dump file
    raw = ctx.d.read_pa(spa, ln)
    idx = 0
    while True:
        j = raw.find(pat, idx)
        if j < 0:
            break
        idx = j + 1
        if j % 8:
            continue
        idx = j + 8
        obj = sva + j
        ref = Q(obj + 0x40)
        if not ref:
            continue
        handler = Q(obj + 0x28)
        matching = Q(obj + 0x18)
        n += 1
        owner = None
        for sva2, (tva, ti) in by_stack.items():
            if sva2 <= ref < sva2 + 0x4000:
                owner = (tva, ti)
                break
        hn = exact.get(handler, '?') if handler else '?'
        print(f'notifier {obj:#x} handler={hn} ref={ref:#x}')
        if owner:
            tva, ti = owner
            print(f'    WAITER thread {tva:#x} id={ti["id"]:#x} '
                  f'name={ti["name"]!r} wait={ti["wait_event"]:#x}')
        else:
            print(f'    WAITER not a stack ref (heap ref {ref:#x})')
        for line in decode_dict(matching):
            print(f'    dict {line}')
print(f'total active notifiers: {n}')
