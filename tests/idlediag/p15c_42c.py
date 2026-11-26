#!/usr/bin/env python3
"""p15c_42c.py <dump> <S-va> -- follow S+0x280 to the AppleAPFSContainer
object, print its +0x42c word, vtable, and +0x6e0 byte."""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402


def main():
    ctx = Ctx(sys.argv[1])
    sva = int(sys.argv[2], 0)
    cont = ctx.Qva(sva + 0x280)
    print(f'S {sva:#x}: +0x280 (container svc) = {cont:#x}')
    if not cont:
        return
    w = ctx.d.u32_pa(ctx.pa_of(cont + 0x42C))
    print(f'   svc+0x42c = {w:#x}  bit0 = {w & 1}')
    print(f'   svc+0x00 (vtable) = {ctx.Qva(cont):#x}')
    b = ctx.read_va(cont + 0x6E0, 1)
    print(f'   svc+0x6e0 = {b.hex() if b else None}')
    for o in (0x428, 0x430, 0x438, 0x440):
        print(f'   svc+{o:#x} = {ctx.Qva(cont + o):#x}')


if __name__ == '__main__':
    main()
