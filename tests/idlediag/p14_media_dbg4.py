"""Phase 14 debug 4: for slab OSDictionary candidates, decode up to
24 entries from the +0x20 array and compare with header u32s.

Usage: python3 p14_media_dbg4.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, load_syms, SLIDE  # noqa: E402

_syms = {a: n for a, n in load_syms()['syms']}


def cls(ctx, obj):
    vt = ctx.Qva(obj)
    if vt is None:
        return '?'
    return _syms.get(vt - 0x10 - SLIDE, '?')


def kstr(ctx, k):
    if not k or cls(ctx, k) not in ('__ZTV8OSSymbol', '__ZTV8OSString'):
        return None
    p = ctx.Qva(k + 0x10)
    return ctx.read_cstr(p, 64) if p else None


def main():
    ctx = Ctx(sys.argv[1])
    for dobj in (0xfffffe2ee3e58018, 0xfffffe2ee3e58040,
                 0xfffffe2ee3e58090, 0xfffffe2ee3cf4590):
        raw = ctx.read_va(dobj, 0x28)
        u32 = [struct.unpack_from('<I', raw, o)[0]
               for o in range(0x08, 0x20, 4)]
        arr = ctx.Qva(dobj + 0x20)
        print(f'dict {dobj:#x} u32@08..1c={u32} entries@{arr:#x}')
        eraw = ctx.read_va(arr, 24 * 16)
        n = 0
        for j in range(24):
            k, v = struct.unpack_from('<QQ', eraw, j * 16)
            ks = kstr(ctx, k)
            if ks is None:
                print(f'   [{j}] key={k:#x} NOT a string symbol -> stop')
                break
            print(f'   [{j}] {ks!r} -> {v:#x} ({cls(ctx, v)})')
            n += 1
        print(f'   decodable entries: {n}')
        print()


if __name__ == '__main__':
    main()
