"""Phase 15: find a volume object anywhere in a dump by its volume
UUID: locate the in-memory apsb (uuid at +0xF0), get its VA
candidates, then find pointers to it at volobj+0xC0 and read the
volobj fields.

Usage: python3 p15_findvol.py <dump> <uuid-hex-32>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    uuid = bytes.fromhex(sys.argv[2])
    hits = []
    i = data.find(uuid)
    while i != -1:
        hits.append(i)
        i = data.find(uuid, i + 1)
    print(f'uuid hits: {len(hits)}')
    for h in hits:
        apsb_pa = h + DRAM - 0xF0
        for ava in ctx.va_cands(apsb_pa):
            pat = struct.pack('<Q', ava)
            j = data.find(pat)
            while j != -1:
                vol_pa = j + DRAM - 0xC0
                for vva in ctx.va_cands(vol_pa):
                    if ctx.Qva(vva + 0xC0) != ava:
                        continue
                    name = ctx.read_cstr(vva + 0x22d8, 48)
                    u32 = lambda o: ctx.d.u32_pa(ctx.pa_of(vva + o))  # noqa: E731
                    print(f'volobj {vva:#x} name={name!r} '
                          f'+0x354={u32(0x354)} +0x18c={u32(0x18C):#x} '
                          f'+0x120={ctx.Qva(vva + 0x120):#x} '
                          f'+0x3a8={u32(0x3A8):#x} '
                          f'+0x378={ctx.Qva(vva + 0x378):#x} '
                          f'+0x138={ctx.Qva(vva + 0x138):#x}')
                j = data.find(pat, j + 1)


if __name__ == '__main__':
    main()
