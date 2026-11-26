"""Phase 14 calibration: find mount structs via the static vfsops
pointers they reference, then read the true field offsets off one
known mount (root, mnton '/').

Usage: python3 p14_calib.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, SLIDE  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    for name in ('_apfs_vfsops', '_autofs_vfsops', '_lifs_vfsops',
                 '_tmpfs_vfsops'):
        link = link_of(name)
        if link is None:
            print(name, 'no symbol')
            continue
        rt = link + SLIDE
        pat = struct.pack('<Q', rt)
        hits = []
        i = data.find(pat)
        while i != -1:
            hits.append(i)
            i = data.find(pat, i + 1)
        print(f'{name}: runtime {rt:#x}, {len(hits)} raw hits')
        for h in hits:
            pa = h + DRAM
            vas = ctx.va_cands(pa)
            heap = [v for v in vas if v >= 0xFFFFFE1000000000]
            if not heap:
                continue
            hva = heap[0]
            print(f'  hit fileoff {h:#x} VA {hva:#x}')
            # dump qwords from hva-0x40 to hva+0x120, annotate strings
            base = hva - 0x40
            raw = ctx.read_va(base, 0x560)
            if raw is None:
                continue
            for off in range(0, 0x160, 8):
                q = struct.unpack_from('<Q', raw, off)[0]
                print(f'    +{off - 0x40:+#06x} {q:#018x}')
            # strings in the wider window
            for off in range(0, len(raw) - 4):
                if raw[off:off + 1].isalpha() or raw[off:off + 1] == b'/':
                    end = raw.find(b'\x00', off)
                    if end - off >= 2:
                        s = raw[off:end]
                        try:
                            t = s.decode('ascii')
                        except UnicodeDecodeError:
                            continue
                        if all(32 <= ord(c) < 127 for c in t):
                            print(f'    str @{off - 0x40:+#06x}: {t!r}')
                            # skip past this string
            print()


if __name__ == '__main__':
    main()
