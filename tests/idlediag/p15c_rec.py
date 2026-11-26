#!/usr/bin/env python3
"""p15c_rec.py <dump> <S-va> -- find pointers to the nx struct S in the
dump and classify: volobj slots (S at +0xd0 of a struct whose +0xc0 is an
apsb) vs container-record slots (S at +0x08, name string at +0x20)."""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    sva = int(sys.argv[2], 0)
    data = open(sys.argv[1], 'rb').read()
    pat = struct.pack('<Q', sva)
    hits = []
    i = data.find(pat)
    while i != -1:
        hits.append(i + DRAM)
        i = data.find(pat, i + 1)
    print(f'pointers to S {sva:#x}: {len(hits)}')
    for pa in hits:
        for va in ctx.va_cands(pa):
            # record hypothesis: S at rec+8
            rec = va - 8
            try:
                name = ctx.read_cstr(rec + 0x20, 40)
                flags = ctx.d.u32_pa(ctx.pa_of(rec + 0x18))
                nxt = ctx.Qva(rec)
                vn = ctx.Qva(rec + 0x10)
            except Exception:
                name, flags, nxt, vn = None, None, None, None
            print(f'  ptr at VA {va:#x}: as rec+8 -> rec {rec:#x} '
                  f'flags={flags:#x} next={nxt:#x} vnode={vn:#x} '
                  f'name={name!r}')


if __name__ == '__main__':
    main()
