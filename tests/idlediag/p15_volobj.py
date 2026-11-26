"""Phase 15: locate the APFS volume objects behind the mounts in the
p13 panic dump and read the candidate read-only field at +0x354.

Method: for each apfs mount (p14 walk), scan the mount struct for a
qword V such that *(V+0x378) == mount VA — handle_mount stores the
back-pointer mp at volobj+0x378 (disasm 0xa04c494). Validate V as a
volume object: name cstr at V+0x22d8, *(V+0xc0) = apsb with 'APSB'
magic at +0x20 and vol_uuid at +0xF0 matching the msgbuf ground
truth (System 840693E4..., Recovery 81F579FB...).

Usage: python3 p15_volobj.py <dump>
Run in the directory containing p4_lib.py/p5_common.py/p14_mounts.py.
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402
import p14_mounts as pm  # noqa: E402

DRAM = 0x70000000


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()

    # --- reuse p14's seed + walk ---
    rt = pm.link_of('_apfs_vfsops') + pm.SLIDE
    pat = struct.pack('<Q', rt)
    head_va = None
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
                head_va = info['prevf']
        i = data.find(pat, i + 1)
    assert seed, 'root mount not found'
    mounts = []
    cur = ctx.Qva(head_va)
    seen = set()
    while cur and cur not in seen:
        seen.add(cur)
        mounts.append(pm.mount_info(ctx, cur))
        cur = ctx.Qva(cur + 0x00)
    print(f'{len(mounts)} mounts')

    for m in mounts:
        print(f"\n== mount {m['base']:#x} on {m['mnton']} from {m['fromn']} "
              f"flag={m['flag']:#x}")
        if m['fstype'] != 'apfs':
            continue
        base = m['base']
        raw = ctx.read_va(base, 0xC00)
        cands = []
        for off in range(0, 0xC00, 8):
            v = struct.unpack_from('<Q', raw, off)[0]
            if not (0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF):
                continue
            if ctx.Qva(v + 0x378) == base:
                cands.append((off, v))
        print(f'  volobj candidates (backptr +0x378 == mp): '
              f'{[(hex(o), hex(v)) for o, v in cands]}')
        for off, v in cands:
            name = ctx.read_cstr(v + 0x22d8, 64)
            apsb = ctx.Qva(v + 0xC0)
            magic = ctx.read_va(apsb + 0x20, 4) if apsb else None
            uuid_raw = ctx.read_va(apsb + 0xF0, 16) if apsb else None
            uuid_s = None
            if uuid_raw:
                u = uuid_raw
                uuid_s = (f'{u[0:4].hex()}-{u[4:6].hex()}-{u[6:8].hex()}-'
                          f'{u[8:10].hex()}-{u[10:16].hex()}').upper()
            print(f'  volobj {v:#x} (via mount+{off:#x}): name={name!r} '
                  f'apsb={apsb:#x} magic={magic} uuid={uuid_s}')
            f354 = ctx.d.u32_pa(ctx.pa_of(v + 0x354))
            f350 = ctx.d.u32_pa(ctx.pa_of(v + 0x350))
            print(f'  ** +0x354 (apfs_readonly?) = {f354:#x} ({f354})   '
                  f'+0x350 = {f350:#x}')
            # neighbourhood dump u32 +0x300..+0x3e0
            nb = ctx.read_va(v + 0x300, 0xE0)
            words = struct.unpack('<56I', nb)
            for k in range(0, 56, 4):
                row = ' '.join(f'{w:08x}' for w in words[k:k + 4])
                print(f'    +{0x300 + k * 4:#05x}: {row}')
            for o, ln in ((0x120, 'u64'), (0x138, 'u64'), (0x148, 'u64'),
                          (0x370, 'u64'), (0x380, 'u64')):
                print(f'    +{o:#x} = {ctx.Qva(v + o):#x}')
            print(f'    +0x3a8 u32 = {ctx.d.u32_pa(ctx.pa_of(v + 0x3A8)):#x}')


if __name__ == '__main__':
    main()
