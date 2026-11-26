"""Phase 15 continuation: given a dump and a volobj VA, print
volobj+0xd0 (container struct S), the byte at S+0x15b, u32 at
S+0x158, and S's first 0x48 bytes.

Usage: python3 p15c_probe.py <dump> <volobj-va-hex> [more...]
"""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402


def main():
    ctx = Ctx(sys.argv[1])
    for a in sys.argv[2:]:
        vo = int(a, 0)
        d0 = ctx.Qva(vo + 0xD0)
        print(f'volobj {vo:#x}: +0xd0 = {d0:#x}')
        if not d0:
            continue
        b = ctx.read_va(d0 + 0x15B, 1)
        w = ctx.d.u32_pa(ctx.pa_of(d0 + 0x158))
        print(f'   S+0x15b byte = {b.hex() if b else None} (bit0='
              f'{(b[0] & 1) if b else None})  S+0x158 u32 = {w:#x}')
        for o in (0x0, 0x8, 0x10, 0x18, 0x38, 0xC0, 0xC8):
            print(f'   S+{o:#x} = {ctx.Qva(d0 + o):#x}')


if __name__ == '__main__':
    main()
