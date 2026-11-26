"""Phase 6: decode the matching dictionaries of all active
waitForMatchingService waits; identify the owner of the unknown stack
0xFFFFFE4B681E4000.
Usage: python3 p6_dict5.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return '?'
    return syms.get(vt - 0x10 - SLIDE, '?')


def decode(obj):
    """OSSymbol/OSString -> its C string (char* at +0x10, or inline)."""
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


DICTS = {
    '[fa] AppleAPFSMedia config': 0xFFFFFE2839DC2840,
    '[88] aes config': 0xFFFFFE2839DC1918,
    'kernel_bootstrap_thread': 0xFFFFFE2839DE1850,
    'unknown-stack waiter': 0xFFFFFE2839DC0C48,
    'thread call kernel #2': 0xFFFFFE2839DC13A0,
    'heap-ref waiter (near PVG)': 0xFFFFFE2839E415A8,
}
for label, daddr in DICTS.items():
    print(f'===== {label}: dict {daddr:#x} class={class_of(daddr)} =====')
    hdr = [Q(daddr + o) for o in range(0, 0x28, 8)]
    print('   hdr:', ' '.join(f'{v:#x}' for v in hdr))
    entries = hdr[4]
    if entries:
        for i in range(3):
            k = Q(entries + i * 16)
            v = Q(entries + i * 16 + 8)
            if not k:
                break
            print(f'   [{i}] {decode(k)!r} ({class_of(k)}) -> '
                  f'{decode(v)!r} ({class_of(v)}) val={v:#x}')
            # one level of nesting for IOPropertyMatch-style dicts
            if class_of(v) == '__ZTV12OSDictionary':
                e2 = Q(v + 0x20)
                if e2:
                    for j in range(3):
                        k2 = Q(e2 + j * 16)
                        v2 = Q(e2 + j * 16 + 8)
                        if not k2:
                            break
                        print(f'        [{j}] {decode(k2)!r} -> '
                              f'{decode(v2)!r} ({class_of(v2)})')

print('\n===== owner of stack 0xFFFFFE4B681E4000 =====')
target = struct.pack('<Q', 0xFFFFFE4B681E4000)
for sva, spa, ln in ctx.segs:
    if not (0xFFFFFE1840000000 <= sva < 0xFFFFFE1850000000):
        continue
    raw = ctx.d.read_pa(spa, ln)
    idx = 0
    while True:
        j = raw.find(target, idx)
        if j < 0:
            break
        idx = j + 8
        hit = sva + j
        # thread struct base candidates: hit-0xE8 (stack field)
        tva = hit - 0xE8
        ti = thread_info(ctx, tva)
        if ti and ti['stack_va'] == 0xFFFFFE4B681E4000:
            print(f'  thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
                  f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x}')
        else:
            print(f'  raw holder at {hit:#x} (not a thread+0xE8)')
