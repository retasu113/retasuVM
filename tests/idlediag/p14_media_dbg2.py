"""Phase 14 debug 2: raw-dump a sample of OSDictionary candidates.

Usage: python3 p14_media_dbg2.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, load_syms, SLIDE  # noqa: E402

DRAM = 0x70000000
HEAP_MIN = 0xFFFFFE1000000000
_syms = {a: n for a, n in load_syms()['syms']}


def cls(ctx, obj):
    vt = ctx.Qva(obj)
    if vt is None:
        return '?'
    return _syms.get(vt - 0x10 - SLIDE, '?')


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    vt = link_of('__ZTV12OSDictionary') + SLIDE + 0x10
    pat = struct.pack('<Q', vt)
    dicts = []
    i = data.find(pat)
    while i != -1:
        for va in ctx.va_cands(i + DRAM):
            if va >= HEAP_MIN:
                dicts.append(va)
        i = data.find(pat, i + 1)
    print(f'candidates: {len(dicts)}')
    import collections
    cntstat = collections.Counter()
    samples = []
    for dobj in sorted(set(dicts)):
        pa = ctx.pa_of(dobj + 0x10)
        cnt = ctx.d.u32_pa(pa) if pa else None
        arr = ctx.Qva(dobj + 0x20)
        cntstat[(cnt is not None and 0 < cnt <= 512,
                 arr is not None and arr >= HEAP_MIN)] += 1
        if len(samples) < 6 and cnt and 0 < cnt <= 64 and arr:
            samples.append((dobj, cnt, arr))
    print('count/arr plausibility:', dict(cntstat))
    for dobj, cnt, arr in samples:
        print(f'== dict {dobj:#x} count={cnt} entries@{arr:#x}')
        raw = ctx.read_va(arr, min(cnt, 6) * 16)
        if raw is None:
            print('   entries unreadable')
            continue
        for j in range(min(cnt, 6)):
            k, v = struct.unpack_from('<QQ', raw, j * 16)
            kc = cls(ctx, k)
            kp = ctx.Qva(k + 0x10) if k else None
            ks = ctx.read_cstr(kp, 64) if kp else None
            print(f'   [{j}] key={k:#x} cls={kc} strptr={kp} str={ks!r}')
            print(f'       val={v:#x} cls={cls(ctx, v)}')


if __name__ == '__main__':
    main()
