#!/usr/bin/env python3
"""Phase 23: find the thread struct's `threads` (global list) queue offset
by matching qwords against known thread VAs, then walk the global list
from a known thread to enumerate ALL threads (incl. the spinning one).

Usage: p23_threadfind9.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402
from p23_threadfind2 import pac_strip  # noqa: E402

DUMP = sys.argv[1]
DRAM = 0x70000000
P_COMM_OFF = 0x5CC
IDLE = 0xFFFFFE1DE8056818  # idle #0, validated thread


def main():
    ctx = Ctx(DUMP)
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')
    # known thread VAs from the validated scan (re-derive cheaply via census
    # + the 14 extra from threadfind6: hardcode the validated set by
    # re-running the C-scan validation is expensive; instead use census
    # threads + the fsck/launchd extras discovered).
    from p5_common import census_threads, thread_info
    known = {}
    for tva in census_threads(ctx):
        ti = thread_info(ctx, tva)
        if ti:
            known[tva] = ti['id']
    # add the 14 extra validated threads (from threadfind6 output)
    extra = {
        0xfffffe1de805d828: 0x74, 0xfffffe1de8064838: 0x8c,
        0xfffffe1de8051828: 0xa3, 0xfffffe1de8053808: 0xb5,
        0xfffffe1de8062020: 0xbf, 0xfffffe1de8061828: 0xc6,
        0xfffffe1de804c040: 0xe6, 0xfffffe1de8158040: 0xee,
        0xfffffe1de8154838: 0xf9, 0xfffffe1de8155828: 0xfc,
        0xfffffe1de8156020: 0x109, 0xfffffe1de819f010: 0x11b,
        0xfffffe1de8181828: 0x152, 0xfffffe1de8182020: 0x153,
    }
    known.update(extra)
    print(f'{len(known)} known thread VAs')

    # find queue-link offsets in the idle thread struct
    raw = ctx.read_va(IDLE, 0x900)
    print('\n--- qword offsets in idle thread struct holding a known thread VA ---')
    hits = {}
    for off in range(0, 0x900, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v in known:
            hits.setdefault(off, []).append((v, known[v]))
    for off, lst in sorted(hits.items()):
        print(f'  +{off:#x}: {lst}')

    # walk the global list from the idle thread using each candidate offset
    for off in sorted(hits):
        print(f'\n--- walk global list via +{off:#x} (next pointer) ---')
        seen = []
        cur = IDLE
        for _ in range(300):
            if cur in seen:
                print(f'  loop back to {cur:#x} after {len(seen)} threads')
                break
            seen.append(cur)
            traw = ctx.read_va(cur, 0x900)
            if not traw:
                print(f'  cannot read thread {cur:#x}')
                break
            nxt = struct.unpack_from('<Q', traw, off)[0]
            if nxt == IDLE:
                print(f'  closed the loop after {len(seen)} threads')
                break
            if not (0xFFFFFE0000000000 <= nxt <= 0xFFFFFEFFFFFFFFFF):
                print(f'  next {nxt:#x} out of range after {len(seen)} threads')
                break
            cur = nxt
        else:
            print(f'  hit 300-thread cap, {len(seen)} threads so far')
        print(f'  walked {len(seen)} threads via +{off:#x}')
        # identify each walked thread (id, stack, proc)
        new = []
        for tva in seen:
            if tva in known:
                continue
            traw = ctx.read_va(tva, 0x900)
            if not traw:
                continue
            cid = struct.unpack_from('<Q', traw, 0x498)[0]
            stk = struct.unpack_from('<Q', traw, 0xE8)[0]
            tro = struct.unpack_from('<Q', traw, 0x3D8)[0]
            comm = '?'
            try:
                tproc = pac_strip(ctx.Qva(tro + 0x18))
                pblk = ctx.read_va(tproc, 0x1000)
                if pblk:
                    c = pblk[P_COMM_OFF:P_COMM_OFF + 17].split(b'\x00')[0]
                    if c and all(32 <= ch < 127 for ch in c):
                        comm = c.decode()
            except Exception:
                pass
            new.append((tva, cid, stk, comm))
        if new:
            print(f'  NEW threads found via this walk ({len(new)}):')
            for tva, cid, stk, comm in sorted(new, key=lambda r: r[1]):
                mark = '  <<<< SPIN STACK' if stk == 0xFFFFFE8EB65F4000 else ''
                print(f'    thread {tva:#x} id={cid:#x} stack={stk:#x} '
                      f'proc={comm!r}{mark}')
        else:
            print('  no new threads via this walk')


if __name__ == '__main__':
    main()
