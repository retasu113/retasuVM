"""Phase 15: probe volobj+0xd0 target and its +0x15b byte (the
apfs_mount_livefs read-only override source) in a dump.

Usage: python3 p15_d0probe.py <dump>
"""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

OBJS = {
    'p13': {
        'Recovery': 0xfffffe1ef4038000,
        'System': 0xfffffe1ef4032000,
        'Data': 0xfffffe1ef4035000,
    },
}


def main():
    ctx = Ctx(sys.argv[1])
    for name, vo in OBJS['p13'].items():
        d0 = ctx.Qva(vo + 0xD0)
        print(f'{name}: volobj {vo:#x} +0xd0 = {d0:#x}')
        if not d0:
            continue
        b = ctx.read_va(d0 + 0x15B, 1)
        bit0 = (b[0] & 1) if b else None
        print(f'   byte at target+0x15b = {b.hex() if b else None} bit0={bit0}')
        qs = []
        for o in (0x0, 0x8, 0x10, 0x28, 0x40, 0x78, 0xB8, 0xF0):
            v = ctx.Qva(d0 + o)
            qs.append(f'+{o:#x}={v:#x}' if v is not None else f'+{o:#x}=?')
        print('   ' + ' '.join(qs))
        print(f'   cstr target+0x200: {ctx.read_cstr(d0 + 0x200, 40)!r}')
        print(f'   u32 target+0x158: '
              f'{ctx.d.u32_pa(ctx.pa_of(d0 + 0x158)):#x}')


if __name__ == '__main__':
    main()
