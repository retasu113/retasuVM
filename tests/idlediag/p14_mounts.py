"""Phase 14: walk the kernel mountlist in a DRAM dump; report
mnt_flag (MNT_RDONLY?) for every mount, identified by the embedded
vfsstatfs strings.

Layout — EMPIRICALLY CALIBRATED on the root mount of
home_p13blk/dram_fpend.bin (found via the _apfs_vfsops pointer;
cross-validated by: empty-TAILQ self-pointers in the two work
queues, f_blocks x f_bsize == the 44.11 GB main container, root
mnton '/', from '/dev/disk3s1s1', f_flags == mnt_flag):
  struct mount:
    +0x00 mnt_list.tqe_next   +0x08 mnt_list.tqe_prev
    +0x10 mnt_count           +0x28 mnt_op   +0x30 mnt_vtable
    +0x38 mnt_vnodecovered
    +0x70 mnt_flag u32        +0x74 mnt_kern_flag u32
    +0x84 mnt_vfsstat: f_bsize@+0x84, f_flags@+0xCC (u64),
          f_fstypename@+0xD4[16], f_mntonname@+0xE4[1024],
          f_mntfromname@+0x4E4[1024]
  (Header-derived offsets from xnu-11417 mount_internal.h put
  mnt_vfsstat 4 bytes later; the in-kernel packing differs by 4 B
  somewhere before f_flags. The calibrated values above are what
  the dump proves; both flag words are read and cross-checked.)
  mountlist head VA is recovered from the root mount's tqe_prev
  (it points at the head in static kernel data).

Usage: python3 p14_mounts.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, SLIDE  # noqa: E402

DRAM = 0x70000000
OFF_FLAG = 0x70
OFF_KERN = 0x74
OFF_FFLAGS = 0xCC
OFF_FSTYPE = 0xD4
OFF_MNTON = 0xE4
OFF_FROMN = 0x4E4

MNT_BITS = {
    0x00000001: 'RDONLY', 0x00000002: 'SYNCHRONOUS', 0x00000004: 'NOEXEC',
    0x00000008: 'NOSUID', 0x00000010: 'NODEV', 0x00000020: 'UNION',
    0x00000040: 'ASYNC', 0x00000080: 'CPROTECT', 0x00000100: 'EXPORTED',
    0x00000200: 'REMOVABLE', 0x00000400: 'QUARANTINE', 0x00001000: 'LOCAL',
    0x00002000: 'QUOTA', 0x00004000: 'ROOTFS', 0x00008000: 'DOVOLFS',
    0x00100000: 'DONTBROWSE', 0x00200000: 'IGNORE_OWNERSHIP',
    0x00400000: 'AUTOMOUNTED', 0x00800000: 'JOURNALED',
    0x01000000: 'NOUSERXATTR', 0x02000000: 'DEFWRITE',
    0x04000000: 'MULTILABEL', 0x08000000: 'NOFOLLOW',
    0x10000000: 'NOATIME', 0x40000000: 'SNAPSHOT', 0x80000000: 'STRICTATIME',
}


def dec_flags(v):
    names = [n for b, n in sorted(MNT_BITS.items()) if v & b]
    known = 0
    for b in MNT_BITS:
        known |= b
    if v & ~known:
        names.append(f'UNK{v & ~known:#x}')
    return '|'.join(names) if names else '(none)'


def cstr_at(ctx, va, maxlen):
    raw = ctx.read_va(va, maxlen)
    if raw is None:
        return None
    end = raw.find(b'\x00')
    if end < 0:
        return None
    try:
        s = raw[:end].decode('ascii')
    except UnicodeDecodeError:
        return None
    return s if all(32 <= ord(c) < 127 for c in s) else None


def mount_info(ctx, base):
    u32 = lambda o: ctx.d.u32_pa(ctx.pa_of(base + o))  # noqa: E731
    return dict(
        base=base,
        flag=u32(OFF_FLAG), kern=u32(OFF_KERN),
        fflags=ctx.Qva(base + OFF_FFLAGS),
        fstype=cstr_at(ctx, base + OFF_FSTYPE, 16),
        mnton=cstr_at(ctx, base + OFF_MNTON, 300),
        fromn=cstr_at(ctx, base + OFF_FROMN, 300),
        next=ctx.Qva(base + 0x00), prevf=ctx.Qva(base + 0x08),
        op=ctx.Qva(base + 0x28),
    )


def main():
    ctx = Ctx(sys.argv[1])
    data = open(sys.argv[1], 'rb').read()

    # 1) find one apfs mount via the vfsops pointer, get the head VA
    rt = link_of('_apfs_vfsops') + SLIDE
    pat = struct.pack('<Q', rt)
    head_va = None
    seed = None
    i = data.find(pat)
    while i != -1 and seed is None:
        for hva in ctx.va_cands(i + DRAM):
            if hva < 0xFFFFFE1000000000:
                continue
            base = hva - 0x28
            info = mount_info(ctx, base)
            if info['mnton'] == '/' and info['fstype'] == 'apfs':
                seed = base
                head_va = info['prevf']
        i = data.find(pat, i + 1)
    assert seed, 'root mount not found'
    print(f'root mount {seed:#x}; mountlist head VA {head_va:#x} '
          f'(first={ctx.Qva(head_va):#x})')

    # 2) walk the TAILQ from the head
    mounts = []
    cur = ctx.Qva(head_va)
    seen = set()
    while cur and cur not in seen:
        seen.add(cur)
        mounts.append(mount_info(ctx, cur))
        cur = ctx.Qva(cur + 0x00)
    print(f'mountlist walk: {len(mounts)} mounts')
    print()
    for m in mounts:
        rd = 'RDONLY' if m['flag'] & 1 else 'rw    '
        print(f'{m["base"]:#018x} {str(m["fstype"]):<7} {rd} '
              f'flag={m["flag"]:#010x} kern={m["kern"]:#010x} '
              f'fflags={m["fflags"]:#x}')
        print(f'{"":>18} on {m["mnton"]}  from {m["fromn"]}')
        print(f'{"":>18} {dec_flags(m["flag"])}')
    ro = [m for m in mounts if m['flag'] & 1]
    print()
    print(f'TOTAL {len(mounts)} mounts; MNT_RDONLY on {len(ro)}:')
    for m in ro:
        print(f'  {m["mnton"]} ({m["fstype"]}, from {m["fromn"]})')


if __name__ == '__main__':
    main()
