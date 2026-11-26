"""Phase 15: dump the shared struct at volobj+0xd0 (0xfffffe194e304900
in p13) — first 0x200 bytes as qwords, any embedded cstrings, and
find dump-wide pointers TO it (who references it).

Usage: python3 p15_devprobe.py <dump> <struct-va-hex>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    base = int(sys.argv[2], 0)
    raw = ctx.read_va(base, 0x200)
    for off in range(0, 0x200, 16):
        a, b = struct.unpack_from('<QQ', raw, off)
        print(f'+{off:#05x}: {a:#018x} {b:#018x}')
    # cstrings inside
    for off in range(0, 0x200):
        c = raw[off]
        if 32 <= c < 127 and (off == 0 or raw[off - 1] == 0):
            end = raw.find(b'\x00', off)
            s = raw[off:end]
            if len(s) >= 4:
                try:
                    print(f'  cstr +{off:#x}: {s.decode()!r}')
                except UnicodeDecodeError:
                    pass
    # who points at it?
    pat = struct.pack('<Q', base)
    refs = []
    i = data.find(pat)
    while i != -1:
        refs.append(i + DRAM)
        i = data.find(pat, i + 1)
    print(f'{len(refs)} pointers to {base:#x}:')
    for pa in refs[:24]:
        vas = ctx.va_cands(pa)
        print(f'  at PA {pa:#x} VA candidates {vas}')


if __name__ == '__main__':
    main()
