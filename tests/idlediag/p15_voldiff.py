"""Phase 15: diff the six main-container volume objects and their
in-memory apsb structs in the p13 dump; find every field that
discriminates {System, Recovery} (volobj +0x354 == 1) from
{s2, s4, s5, s6} (+0x354 == 0).

Usage: python3 p15_voldiff.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

objs = {
    's1sys': 0xfffffe1ef4032000,
    's2': 0xfffffe1ef4035000,
    's3rec': 0xfffffe1ef4038000,
    's4': 0xfffffe1ef403b000,
    's5pre': 0xfffffe1ef403e000,
    's6': 0xfffffe1ef4041000,
    's1snap': 0xfffffe1ef4071000,
}
BASE_KEYS = ['s1sys', 's2', 's3rec', 's4', 's5pre', 's6']


def main():
    ctx = Ctx(sys.argv[1])
    blobs = {k: ctx.read_va(va, 0x400) for k, va in objs.items()}
    print('== volobj u32 offsets differing among the 6 base objects ==')
    for off in range(0, 0x400, 4):
        vals = {k: struct.unpack_from('<I', blobs[k], off)[0]
                for k in BASE_KEYS}
        if len(set(vals.values())) > 1:
            snap = struct.unpack_from('<I', blobs['s1snap'], off)[0]
            row = '  '.join(f'{k}={v:#x}' for k, v in vals.items())
            print(f'  +{off:#05x}: {row}  snap={snap:#x}')

    apsbs = {}
    for k in BASE_KEYS:
        ap = ctx.Qva(objs[k] + 0xC0)
        apsbs[k] = ctx.read_va(ap, 0x500)
    print('== apsb u64 offsets differing among the 6 volumes ==')
    for off in range(0, 0x500, 8):
        vals = {k: struct.unpack_from('<Q', apsbs[k], off)[0]
                for k in BASE_KEYS}
        if len(set(vals.values())) > 1:
            row = '  '.join(f'{k}={v:#x}' for k, v in vals.items())
            print(f'  +{off:#05x}: {row}')
    print('== apsb u32 offsets differing (finer) ==')
    for off in range(0, 0x500, 4):
        vals = {k: struct.unpack_from('<I', apsbs[k], off)[0]
                for k in BASE_KEYS}
        if len(set(vals.values())) > 1:
            row = '  '.join(f'{k}={v:#x}' for k, v in vals.items())
            print(f'  +{off:#05x}: {row}')


if __name__ == '__main__':
    main()
