#!/usr/bin/env python3
"""Phase 23: find the spinning thread's struct, walk thread->task->proc_ro->p_comm.

Step A: census threads, find the one whose kernel stack VA is
0xFFFFFE8EB65F4000 (the spinning thread, phase 21 §3b). Fallback: scan
the dump for that qword; candidate thread base = hit - 0xE8
(kernel_stack field offset from the census field map).
Step B: calibrate bsd_info_ro / p_comm offsets on kernel_task: scan its
task struct for a pointer (raw or PAC-stripped) to a struct containing
b'kernel_task\\0'.
Step C: for the spinning thread, PAC-strip-scan its first 0x900 bytes for
a task pointer; read bsd_info_ro at the calibrated offset; read p_comm.
PAC strip for a 48-bit kernel VA: clear bits 63:48, re-sign-extend bit 47.

Usage: p23_threadfind.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

DUMP = sys.argv[1]
SPIN_STACK = 0xFFFFFE8EB65F4000


def pac_strip(q):
    """Strip a PAC-signed kernel pointer to canonical form."""
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def main():
    ctx = Ctx(DUMP)
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')

    # --- Step B first: calibrate on kernel_task ---
    print('\n--- Step B: calibrate bsd_info_ro / p_comm offsets on kernel_task ---')
    raw = ctx.read_va(ctx.task_va, 0x1000)
    if raw is None:
        print('  cannot read kernel_task struct')
        return
    calib = []
    for o in range(0, 0x1000, 8):
        q = struct.unpack_from('<Q', raw, o)[0]
        for cand, how in ((q, 'raw'), (pac_strip(q), 'stripped')):
            if not (0xFFFFFE0000000000 <= cand <= 0xFFFFFEFFFFFFFFFF):
                continue
            if cand == ctx.task_va:
                continue
            try:
                blk = ctx.read_va(cand, 0x400)
            except Exception:
                blk = None
            if not blk:
                continue
            j = blk.find(b'kernel_task\x00')
            if j >= 0:
                print(f'  task+{o:#x} ({how}) -> {cand:#x} : '
                      f'"kernel_task" at +{j:#x} in target')
                calib.append((o, cand, j))
    if not calib:
        print('  NO calibration hit — kernel_task proc_ro not found this way')

    # --- Step A: find the spinning thread ---
    print('\n--- Step A: find thread with kernel stack 0xFFFFFE8EB65F4000 ---')
    threads = census_threads(ctx)
    print(f'census: {len(threads)} threads')
    spin_tva = None
    for tva in sorted(threads):
        ti = thread_info(ctx, tva)
        if ti is None:
            continue
        if ti['stack_va'] == SPIN_STACK:
            spin_tva = tva
            print(f'  SPIN THREAD in census: {tva:#x} id={ti["id"]:#x} '
                  f'name={ti["name"]!r} wait={ti["wait_event"]:#x} '
                  f'state=0x{ti["state_byte"]:02x}')
    if spin_tva is None:
        print('  not in census — scanning dump for the stack-VA qword ...')
        data = open(DUMP, 'rb').read()
        pat = struct.pack('<Q', SPIN_STACK)
        i = data.find(pat)
        while i != -1:
            if i % 8 == 0:
                base_pa = (0x70000000 + i) - 0xE8
                base_va_cands = ctx.va_cands(base_pa)
                for bva in base_va_cands:
                    ti = thread_info(ctx, bva)
                    if ti and ti['stack_va'] == SPIN_STACK:
                        print(f'  SPIN THREAD by scan: {bva:#x} '
                              f'id={ti["id"]:#x} name={ti["name"]!r}')
                        spin_tva = bva
            i = data.find(pat, i + 1)
    if spin_tva is None:
        print('  SPIN THREAD NOT FOUND')
        return

    # --- Step C: walk thread -> task -> proc_ro -> p_comm ---
    print(f'\n--- Step C: walk thread {spin_tva:#x} -> task -> proc_ro ---')
    traw = ctx.read_va(spin_tva, 0x900)
    if traw is None:
        print('  cannot read thread struct')
        return
    for o in range(0, 0x900, 8):
        q = struct.unpack_from('<Q', traw, o)[0]
        for cand, how in ((q, 'raw'), (pac_strip(q), 'stripped')):
            if not (0xFFFFFE0000000000 <= cand <= 0xFFFFFEFFFFFFFFFF):
                continue
            if cand == ctx.task_va:
                continue
            # validate: candidate task struct must yield a printable p_comm
            # at the calibrated bsd_info_ro offset (if calibrated)
            for (boff, _c, poff) in calib:
                try:
                    bro = ctx.Qva(cand + boff)
                except Exception:
                    bro = None
                if bro is None:
                    continue
                bro = pac_strip(bro)
                if not (0xFFFFFE0000000000 <= bro <= 0xFFFFFEFFFFFFFFFF):
                    continue
                try:
                    pblk = ctx.read_va(bro, 0x200)
                except Exception:
                    pblk = None
                if not pblk:
                    continue
                comm = pblk[poff:poff + 17].split(b'\x00')[0]
                if comm and all(32 <= c < 127 for c in comm):
                    print(f'  thread+{o:#x} ({how}) -> task {cand:#x} '
                          f'bsd_info_ro @{boff:#x} = {bro:#x} '
                          f'p_comm@{poff:#x} = {comm!r}')
                    # also print p_pid if the field before p_comm looks sane
                    print(f'  proc_ro bytes around p_comm: '
                          f'{pblk[max(0, poff - 16):poff + 24].hex()}')
                    return
    print('  no task->proc_ro walk converged')


if __name__ == '__main__':
    main()
