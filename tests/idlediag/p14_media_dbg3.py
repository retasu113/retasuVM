"""Phase 14 debug 3: raw headers of OSDictionary candidates whose
count@+0x10 looks implausible.

Usage: python3 p14_media_dbg3.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, SLIDE  # noqa: E402

DRAM = 0x70000000
HEAP_MIN = 0xFFFFFE1000000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    vt = link_of('__ZTV12OSDictionary') + SLIDE + 0x10
    pat = struct.pack('<Q', vt)
    shown = 0
    i = data.find(pat)
    while i != -1 and shown < 8:
        for va in ctx.va_cands(i + DRAM):
            if va < HEAP_MIN:
                continue
            pa = ctx.pa_of(va + 0x10)
            cnt = ctx.d.u32_pa(pa) if pa else None
            if cnt is not None and 0 < cnt <= 512:
                continue
            raw = ctx.read_va(va, 0x30)
            if raw is None:
                continue
            qs = [struct.unpack_from('<Q', raw, o)[0]
                  for o in range(0, 0x30, 8)]
            print(f'dict {va:#x} count@10={cnt} hdr: ' +
                  ' '.join(f'{q:#018x}' for q in qs))
            shown += 1
        i = data.find(pat, i + 1)


if __name__ == '__main__':
    main()
