"""Phase 14 debug: inspect OSBoolean singleton targets and hunt the
'BSD Name' string/symbol without heap-only filters.

Usage: python3 p14_media_dbg.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, load_syms, SLIDE  # noqa: E402

DRAM = 0x70000000
_syms = {a: n for a, n in load_syms()['syms']}


def clsname(ctx, obj):
    vt = ctx.Qva(obj)
    if vt is None:
        return '?'
    n = _syms.get(vt - 0x10 - SLIDE)
    return n or '?'


def main():
    ctx = Ctx(sys.argv[1])
    for nm in ('_kOSBooleanTrue', '_kOSBooleanFalse'):
        var = link_of(nm) + SLIDE
        tgt = ctx.d.u64_phys(var)
        print(f'{nm}: var@{var:#x} -> {tgt:#x}; qwords at target:')
        raw = ctx.read_va(tgt, 0x20) if tgt else None
        if raw:
            for o in range(0, 0x20, 8):
                print(f'   +{o:#x} {struct.unpack_from("<Q", raw, o)[0]:#018x}')
        print(f'   as object: class={clsname(ctx, tgt)}')
        # maybe the symbol address itself is the object
        print(f'   symbol-as-object class={clsname(ctx, var)}')

    data = open(sys.argv[1], 'rb').read()
    print()
    occ = []
    i = data.find(b'BSD Name\x00')
    while i != -1:
        occ.append(i)
        i = data.find(b'BSD Name\x00', i + 1)
    print(f"'BSD Name' occurrences: {len(occ)}")
    for off in occ:
        vas = ctx.va_cands(off + DRAM)
        print(f'  fileoff {off:#x} VAs {[hex(v) for v in vas]}')
        for va in vas:
            pat = struct.pack('<Q', va)
            j = data.find(pat)
            cnt = 0
            while j != -1 and cnt < 12:
                for pva in ctx.va_cands(j + DRAM):
                    obj = pva - 0x10
                    print(f'    ptr at VA {pva:#x} -> holder obj {obj:#x} '
                          f'class={clsname(ctx, obj)}')
                cnt += 1
                j = data.find(pat, j + 1)


if __name__ == '__main__':
    main()
