#!/usr/bin/env python3
"""Phase 23 (attempt 2): identify the spinning process.

Step A: locate the spinning thread's struct by scanning for the kernel
stack VA qword (0xFFFFFE8EB65F4000); test every base offset for the
thread signature (plausible id at +0x498, stack match at +0xE8).
Step B: calibrate proc_ro / p_comm / bsd_info_ro / t_task offsets on
kernel_task (whose VA is known):
  - scan dump for qword == kernel_task VA; each occurrence V is a raw
    pointer to kernel_task. A proc_ro has pr_task at +0x08, so V-0x08 is
    a proc_ro candidate; validate by pr_proc at +0x00 pointing to a proc
    whose +0x18 (p_proc_ro) points back at V-0x08. Find b'kernel_task'
    inside that proc's first 0x400 bytes -> p_comm offset.
  - scan kernel_task's struct for a qword == proc_ro VA (raw/stripped)
    -> bsd_info_ro offset in struct task.
  - scan a known census thread's struct for a PAC-stripped kernel_task
    VA -> t_task offset in struct thread.
Step C: apply to the spinning thread: t_task -> task -> bsd_info_ro ->
proc_ro -> pr_proc -> proc -> p_comm (+ p_pid from the proc bytes).

Usage: p23_threadfind2.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

DUMP = sys.argv[1]
SPIN_STACK = 0xFFFFFE8EB65F4000
DRAM = 0x70000000


def pac_strip(q):
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def is_kernel_va(v):
    return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF


def main():
    ctx = Ctx(DUMP)
    d = ctx.d
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')
    data = open(DUMP, 'rb').read()

    # ---------- Step A: stack-VA occurrences ----------
    print('\n--- Step A: stack-VA qword occurrences ---')
    pat = struct.pack('<Q', SPIN_STACK)
    occs = []
    i = data.find(pat)
    while i != -1:
        if i % 8 == 0:
            occs.append(i)
        i = data.find(pat, i + 1)
    print(f'  {len(occs)} aligned occurrence(s) of {SPIN_STACK:#x}')
    spin_tva = None
    for off in occs:
        pa = DRAM + off
        print(f'  @PA {pa:#x} (file {off:#x})')
        # dump +-0x40 for context
        for j in range(-0x40, 0x48, 8):
            v = struct.unpack_from('<Q', data, off + j)[0]
            if v:
                print(f'    {pa + j:#x} {v:#018x}')
        # test every base offset for thread signature
        for base_off in range(0, 0x900, 8):
            base_pa = pa - base_off
            for bva in ctx.va_cands(base_pa):
                ti = thread_info(ctx, bva)
                if ti and ti['stack_va'] == SPIN_STACK and 0 < ti['id'] < 0x10000:
                    print(f'  ** SPIN THREAD struct at {bva:#x} '
                          f'(hit at +{base_off:#x}) id={ti["id"]:#x} '
                          f'name={ti["name"]!r} state=0x{ti["state_byte"]:02x}')
                    spin_tva = bva
    if spin_tva is None:
        print('  no thread struct validated for the stack VA')

    # ---------- Step B1: proc_ro via kernel_task pointer occurrences ----------
    print('\n--- Step B1: proc_ro calibration via kernel_task VA occurrences ---')
    pat = struct.pack('<Q', ctx.task_va)
    occs = []
    i = data.find(pat)
    while i != -1:
        if i % 8 == 0:
            occs.append(i)
        i = data.find(pat, i + 1)
    print(f'  {len(occs)} aligned occurrence(s) of kernel_task VA')
    proc_ro_va = None
    p_comm_off = None
    for off in occs:
        pa = DRAM + off
        for bva in ctx.va_cands(pa):
            # candidate proc_ro at bva - 0x08 (pr_task field)
            pro = bva - 0x08
            try:
                pr_proc = ctx.Qva(pro + 0x00)
                pr_task = ctx.Qva(pro + 0x08)
            except Exception:
                continue
            if pr_task != ctx.task_va:
                continue
            if not is_kernel_va(pr_proc):
                continue
            # validate: proc's p_proc_ro (+0x18) points back at pro
            back = ctx.Qva(pr_proc + 0x18)
            if back != pro:
                continue
            # find "kernel_task" inside the proc's first 0x400 bytes
            pblk = ctx.read_va(pr_proc, 0x400)
            if not pblk:
                continue
            j = pblk.find(b'kernel_task\x00')
            if j >= 0:
                print(f'  ** proc_ro at {pro:#x} (pr_task occ at {bva:#x}); '
                      f'proc at {pr_proc:#x}; p_comm at proc+{j:#x}')
                proc_ro_va = pro
                p_comm_off = j
                # print pid-ish ints near the proc start
                print(f'     proc head qwords: '
                      f'{[hex(struct.unpack_from("<Q", pblk, k)[0]) for k in range(0, 0x60, 8)]}')
    if proc_ro_va is None:
        print('  proc_ro NOT calibrated')

    # ---------- Step B2: bsd_info_ro offset in struct task ----------
    print('\n--- Step B2: bsd_info_ro offset in struct task ---')
    bsd_off = None
    if proc_ro_va is not None:
        raw = ctx.read_va(ctx.task_va, 0x1000)
        for o in range(0, 0x1000, 8):
            q = struct.unpack_from('<Q', raw, o)[0]
            if q == proc_ro_va or pac_strip(q) == proc_ro_va:
                print(f'  task+{o:#x} -> proc_ro {proc_ro_va:#x} '
                      f'({"raw" if q == proc_ro_va else "stripped"})')
                bsd_off = o
    if bsd_off is None:
        print('  bsd_info_ro offset NOT found')

    # ---------- Step B3: t_task offset in struct thread ----------
    print('\n--- Step B3: t_task offset in struct thread (known census thread) ---')
    t_task_off = None
    threads = census_threads(ctx)
    print(f'  census: {len(threads)} threads')
    for tva in sorted(threads):
        ti = thread_info(ctx, tva)
        if ti is None or ti['name'] != 'idle #0':
            continue
        traw = ctx.read_va(tva, 0x900)
        for o in range(0, 0x900, 8):
            q = struct.unpack_from('<Q', traw, o)[0]
            if pac_strip(q) == ctx.task_va and q != ctx.task_va:
                print(f'  thread {tva:#x} (idle #0): +{o:#x} stripped -> '
                      f'kernel_task (raw {q:#018x})')
                t_task_off = o
                break
        if t_task_off is not None:
            break
    if t_task_off is None:
        print('  t_task offset NOT found (no stripped kernel_task ptr in idle thread)')

    # ---------- Step C: apply to the spinning thread ----------
    print('\n--- Step C: spin thread -> task -> proc_ro -> proc -> p_comm ---')
    if spin_tva is None:
        print('  no spin thread struct — cannot walk')
        return
    if t_task_off is None or bsd_off is None or p_comm_off is None:
        print(f'  missing calibration (t_task={t_task_off} bsd={bsd_off} '
              f'p_comm={p_comm_off}) — cannot walk')
        return
    traw = ctx.read_va(spin_tva, 0x900)
    tq = struct.unpack_from('<Q', traw, t_task_off)[0]
    task_va = pac_strip(tq)
    print(f'  thread+{t_task_off:#x} = {tq:#018x} -> task {task_va:#x}')
    if not is_kernel_va(task_va):
        print('  task VA not a kernel VA — walk fails')
        return
    bro = ctx.Qva(task_va + bsd_off)
    bro = pac_strip(bro)
    print(f'  task+{bsd_off:#x} -> proc_ro {bro:#x}')
    pr_proc = ctx.Qva(bro + 0x00)
    pr_task = ctx.Qva(bro + 0x08)
    print(f'  proc_ro: pr_proc={pr_proc:#x} pr_task={pr_task:#x} '
          f'(task match: {pr_task == task_va or pac_strip(pr_task) == task_va})')
    pblk = ctx.read_va(pr_proc, 0x400)
    comm = pblk[p_comm_off:p_comm_off + 17].split(b'\x00')[0]
    print(f'  ** SPINNING PROCESS: p_comm = {comm!r} (proc {pr_proc:#x})')
    print(f'     proc head: {[hex(struct.unpack_from("<Q", pblk, k)[0]) for k in range(0, 0x60, 8)]}')


if __name__ == '__main__':
    main()
