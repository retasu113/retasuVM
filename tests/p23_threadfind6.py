#!/usr/bin/env python3
"""Phase 23 (attempt 6): validate C-scan thread candidates via the
thread_ro back-pointer (tro_owner == thread VA, pa_of matches), then
walk each validated thread to its proc's p_comm (proc+0x5cc).
Finds the spinning thread even if the census missed it.

Usage: p23_threadfind6.py <dump> <candidates.txt>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402
from p23_threadfind2 import pac_strip  # noqa: E402

DUMP = sys.argv[1]
CAND = sys.argv[2]
DRAM = 0x70000000
SPIN_STACK = 0xFFFFFE8EB65F4000
P_COMM_OFF = 0x5CC


def main():
    ctx = Ctx(DUMP)
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')
    cands = []
    for line in open(CAND):
        parts = line.split()
        if not parts or not parts[0].isdigit():
            continue
        off = int(parts[0])
        kv = dict(p.split('=', 1) for p in parts[1:])
        cands.append((off, int(kv['id'], 0), int(kv['tro'], 0),
                      int(kv['stk'], 0)))
    print(f'{len(cands)} candidates')
    valid = []
    for off, cid, tro, stk in cands:
        pa = DRAM + off
        tro_pa = ctx.pa_of(tro)
        if tro_pa is None:
            continue
        # thread_ro: tro_owner at +0x00
        owner = struct.unpack_from('<Q', ctx.d.read_pa(tro_pa, 8), 0)[0]
        if not (0xFFFFFE0000000000 <= owner <= 0xFFFFFEFFFFFFFFFF):
            continue
        if ctx.pa_of(owner) != pa:
            continue
        # validated: this is a real thread struct at PA=pa, VA=owner
        valid.append((pa, owner, cid, tro, stk))
    print(f'{len(valid)} validated thread structs')
    # walk each to p_comm
    results = []
    for pa, tva, cid, tro, stk in valid:
        comm = '?'
        pid = None
        try:
            tproc_raw = ctx.Qva(tro + 0x18)
            tproc = pac_strip(tproc_raw)
            if 0xFFFFFE0000000000 <= tproc <= 0xFFFFFEFFFFFFFFFF:
                pblk = ctx.read_va(tproc, 0x1000)
                if pblk:
                    c = pblk[P_COMM_OFF:P_COMM_OFF + 17].split(b'\x00')[0]
                    if c and all(32 <= ch < 127 for ch in c):
                        comm = c.decode()
                    # p_pid: u32 at proc+0x50 (after p_mlock); try a few
                    # offsets and pick a small plausible pid
                    for po in (0x50, 0x54, 0x58, 0x5c):
                        v = struct.unpack_from('<I', pblk, po)[0]
                        if 0 < v < 100000:
                            pid = v
                            break
        except Exception:
            pass
        results.append((tva, cid, stk, comm, pid))
    # census ids for comparison
    try:
        from p5_common import census_threads, thread_info
        cens = set()
        for tva in census_threads(ctx):
            ti = thread_info(ctx, tva)
            if ti:
                cens.add(ti['id'])
    except Exception as e:
        print(f'census load failed: {e}')
        cens = set()
    print(f'census ids: {len(cens)} (max {max(cens) if cens else 0:#x})')
    print('\n--- validated threads NOT in the census ---')
    for tva, cid, stk, comm, pid in sorted(results, key=lambda r: r[1]):
        if cid not in cens:
            mark = '  <<<< SPIN STACK' if stk == SPIN_STACK else ''
            print(f'  thread {tva:#x} id={cid:#x} stack={stk:#x} '
                  f'proc={comm!r} pid={pid}{mark}')
    print('\n--- all validated threads (id, stack, proc) ---')
    for tva, cid, stk, comm, pid in sorted(results, key=lambda r: r[1]):
        mark = '  <<<< SPIN STACK' if stk == SPIN_STACK else ''
        print(f'  id={cid:#x} thread={tva:#x} stack={stk:#x} '
              f'proc={comm!r} pid={pid}{mark}')
    spins = [r for r in results if r[2] == SPIN_STACK]
    if spins:
        print(f'\n*** SPINNING THREAD FOUND: {spins} ***')
    else:
        print('\n(no validated thread holds the spin stack at +0xE8)')


if __name__ == '__main__':
    main()
