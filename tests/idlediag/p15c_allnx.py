#!/usr/bin/env python3
"""p15c_allnx.py <dump> -- find every in-memory APFS container (nx) struct
in a dump: locate 'NXSB' superblock copies, map to VA candidates, find
structs S with S+0x38 == S+0xc0 == sb, print S, block_count, S+0x15b."""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    magic = struct.pack('<I', 0x4253584E)
    sb_pas = []
    i = data.find(magic)
    while i != -1:
        # magic at sb+0x20 -> sb PA:
        sb_pas.append(i + DRAM - 0x20)
        i = data.find(magic, i + 1)
    print(f'NXSB copies: {len(sb_pas)}')
    seen = set()
    for pa in sb_pas:
        for sbva in ctx.va_cands(pa):
            # find pointers to sbva in the dump
            pat = struct.pack('<Q', sbva)
            j = data.find(pat)
            while j != -1:
                loc_pa = j + DRAM
                for locva in ctx.va_cands(loc_pa):
                    for base_off in (0x38, 0xC0):
                        sva = locva - base_off
                        if sva in seen:
                            continue
                        try:
                            if ctx.Qva(sva + 0x38) != sbva:
                                continue
                            if ctx.Qva(sva + 0xC0) != sbva:
                                continue
                            if ctx.d.u32_pa(ctx.pa_of(sva + 0x30)) != 0x1000:
                                continue
                        except Exception:
                            continue
                        seen.add(sva)
                        bc = ctx.Qva(sbva + 0x28)
                        b = ctx.read_va(sva + 0x15B, 1)
                        b162 = ctx.read_va(sva + 0x162, 1)
                        print(f'S {sva:#x} sb {sbva:#x} blocks={bc:#x} '
                              f'(~{bc * 4096 / 1e9:.2f} GB) '
                              f'+0x15b={b.hex() if b else "?"} '
                              f'+0x162={b162.hex() if b162 else "?"}')
                j = data.find(pat, j + 1)


if __name__ == '__main__':
    main()
