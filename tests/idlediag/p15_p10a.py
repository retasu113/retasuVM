"""Phase 15: in the p10a dump (boot stopped right after root mount,
BEFORE the pivot — Recovery never mounted), read volobj+0x354 for
all main-container volume objects. If Recovery is already 1 there,
the field is set at container-load/mountroot time, not by the
Recovery mount itself.

Also reads the APFS kext global apfs_vfsop_mount.already_rooted
(link 0xfffffe000a999fb8) in the given dump.

Usage: python3 p15_p10a.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, SLIDE  # noqa: E402
import p14_mounts as pm  # noqa: E402

DRAM = 0x70000000


def find_volobjs(ctx, data):
    """Root mount -> System volobj via back-pointer; then arena scan."""
    rt = link_of('_apfs_vfsops') + SLIDE
    pat = struct.pack('<Q', rt)
    seed = None
    i = data.find(pat)
    while i != -1 and seed is None:
        for hva in ctx.va_cands(i + DRAM):
            if hva < 0xFFFFFE1000000000:
                continue
            base = hva - 0x28
            info = pm.mount_info(ctx, base)
            if info['mnton'] == '/' and info['fstype'] == 'apfs':
                seed = base
        i = data.find(pat, i + 1)
    assert seed, 'root mount not found'
    raw = ctx.read_va(seed, 0xC00)
    sysvol = None
    for off in range(0, 0xC00, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF:
            if ctx.Qva(v + 0x378) == seed:
                sysvol = v
    assert sysvol, 'system volobj not found'
    print(f'root mount {seed:#x}, System volobj {sysvol:#x}')
    out = []
    lo = sysvol - 0x100000
    hi = sysvol + 0x100000
    va = lo
    while va < hi:
        p = ctx.Qva(va + 0xC0)
        if p and ctx.read_va(p + 0x20, 4) == b'APSB':
            uu = ctx.read_va(p + 0xF0, 16)
            uus = (f'{uu[0:4].hex()}-{uu[4:6].hex()}-{uu[6:8].hex()}-'
                   f'{uu[8:10].hex()}-{uu[10:16].hex()}').upper() if uu else '?'
            out.append((va, uus))
        va += 0x1000
    return out


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()
    g = ctx.d.read_phys(0xfffffe000a999fb8 + SLIDE, 1)[0]
    print(f'already_rooted global = {g}')
    for va, uus in find_volobjs(ctx, data):
        u32 = lambda o: ctx.d.u32_pa(ctx.pa_of(va + o))  # noqa: E731
        name = ctx.read_cstr(va + 0x22d8, 48)
        print(f'volobj {va:#x} name={name!r} uuid={uus} '
              f'+0x354={u32(0x354)} +0x18c={u32(0x18C):#x} '
              f'+0x120={ctx.Qva(va + 0x120):#x} +0x3a8={u32(0x3A8):#x} '
              f'+0x378={ctx.Qva(va + 0x378):#x}')


if __name__ == '__main__':
    main()
