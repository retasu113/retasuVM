#!/usr/bin/env python3
"""Phase 23 (attempt 5): identify the 0x30 stack table via kc_syms;
full 0x30-byte entry dump; PAC-stripped proc enumeration (fsck check).

Usage: p23_threadfind5.py <dump>
"""
import pickle
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402
from p23_threadfind2 import pac_strip  # noqa: E402

DUMP = sys.argv[1]
DRAM = 0x70000000


def main():
    ctx = Ctx(DUMP)
    d = ctx.d
    data = open(DUMP, 'rb').read()
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')

    # ---------- 1. table VA + kc_syms reverse lookup ----------
    print('\n--- 1. table VA + kc_syms reverse lookup ---')
    for va in (0xFFFFFE0024A3A770, 0xFFFFFE00249D4000):
        pa = ctx.pa_of(va)
        print(f'  pa_of({va:#x}) = {pa if pa is None else hex(pa)}')
    try:
        with open('kc_syms.pkl', 'rb') as f:
            syms = pickle.load(f)
        print(f'  kc_syms: {len(syms)} symbols')
        # syms format: dict name->(addr, size) or list of tuples
        items = []
        if isinstance(syms, dict):
            items = [(v[0], v[1] if len(v) > 1 else 0, k)
                     for k, v in syms.items()]
        elif isinstance(syms, (list, tuple)):
            for it in syms:
                if len(it) >= 2:
                    items.append((it[0], it[1] if len(it) > 2 else 0,
                                  it[2] if len(it) > 2 else str(it[0])))
        items.sort()
        for target in (0xFFFFFE0024A3A770, 0xFFFFFE00249D4000, 0xFFFFFE0024A3A000):
            # containing symbol
            cont = None
            below = None
            for addr, size, name in items:
                if addr <= target:
                    below = (addr, size, name)
                    if size and addr <= target < addr + size:
                        cont = (addr, size, name)
            print(f'  target {target:#x}: containing={cont} nearest-below={below}')
    except Exception as e:
        print(f'  kc_syms load failed: {e}')

    # ---------- 2. full 0x30-byte entries (spin entry + neighbours) ----------
    print('\n--- 2. full entries PA 0x77fde730..0x77fdeb50 ---')
    for base in range(0x77fde730, 0x77fdeb50, 0x30):
        q = struct.unpack_from('<6Q', data, base - DRAM)
        print(f'  {base:#x}: q0={q[0]:#018x} q1={q[1]:#018x} '
              f'stack={q[2]:#x} q3={q[3]:#018x} '
              f'+0x20={q[4]:#018x} +0x28={q[5]:#018x}')

    # ---------- 3. PAC-stripped proc enumeration ----------
    print('\n--- 3. proc enumeration (PAC-stripped tro_proc) ---')
    threads = census_threads(ctx)
    infos = {}
    for tva in sorted(threads):
        ti = thread_info(ctx, tva)
        if ti:
            infos[tva] = ti
    p_comm_off = 0x5cc
    seen = {}
    for tva, ti in infos.items():
        try:
            traw = ctx.read_va(tva, 0x900)
            if not traw:
                continue
            tro = struct.unpack_from('<Q', traw, 0x3D8)[0]
            if not (0xFFFFFE0000000000 <= tro <= 0xFFFFFEFFFFFFFFFF):
                continue
            tproc_raw = ctx.Qva(tro + 0x18)
            tproc = pac_strip(tproc_raw)
            if not (0xFFFFFE0000000000 <= tproc <= 0xFFFFFEFFFFFFFFFF):
                continue
            if tproc in seen:
                continue
            pblk = ctx.read_va(tproc, 0x1000)
            if not pblk:
                continue
            comm = pblk[p_comm_off:p_comm_off + 17].split(b'\x00')[0]
            if comm and all(32 <= c < 127 for c in comm):
                seen[tproc] = comm.decode()
                print(f'  proc {tproc:#x}: {comm.decode()!r} '
                      f'(via thread {tva:#x} {ti["name"]})')
        except Exception as e:
            print(f'  thread {tva:#x}: error {e}')
    print(f'  {len(seen)} distinct procs named: {sorted(seen.values())}')
    if 'fsck' in seen.values():
        print('  ** fsck IS present among census-thread procs')
    else:
        print('  fsck NOT among census-thread procs')

    # ---------- 4. does the spin stack's entry index match q0? ----------
    print('\n--- 4. table grid check ---')
    base0 = 0x77fd8010
    spin_pa = 0x77fde760
    idx = (spin_pa - base0) // 0x30
    print(f'  spin entry PA {spin_pa:#x} is grid index {idx} '
          f'({idx:#x}) from base {base0:#x}; '
          f'remainder {(spin_pa - base0) % 0x30}')
    q0 = struct.unpack_from('<Q', data, spin_pa - DRAM)[0]
    print(f'  spin q0={q0:#018x} low={q0 & 0xffffffff:#x} '
          f'high={q0 >> 32:#x} (grid idx {idx:#x})')


if __name__ == '__main__':
    main()
