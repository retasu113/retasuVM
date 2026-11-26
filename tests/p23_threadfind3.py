#!/usr/bin/env python3
"""Phase 23 (attempt 3): identify the spinning process via thread_ro.

Facts established in attempt 2:
- The stack-VA qword occurs ONCE, inside a 22-entry 0x30-stride array at
  PA 0x77fde730 (q1 == 0x008a9c8a00000000, q3 == 0x0000014c00810001).
  The SPIN entry is #2: q0 = 0x8000022880000226, stack = 0xFFFFFE8EB65F4000.
  None of the 22 stack VAs is in the 83-thread census.
- thread_ro (XNU osfmk/kern/thread.h): tro_owner +0x00, tro_cred +0x08,
  tro_realcred +0x10, tro_proc +0x18, tro_proc_ro +0x20, tro_task +0x28.
  The thread struct holds t_tro (offset TBD by calibration).

This script:
  1. Calibrates t_tro offset on the idle thread: scan its struct for a
     pointer P with *(P+0x00)==thread VA and stripped *(P+0x28)==kernel_task.
  2. Calibrates p_comm offset: idle thread -> tro_proc -> proc struct;
     find b'kernel_task\\0' in its first 0x400 bytes.
  3. Finds the spin thread struct by scanning the thread zone for
     thread_id 0x226 or 0x228 with kernel_stack == 0xFFFFFE8EB65F4000.
  4. Walks spin thread -> t_tro -> tro_proc -> proc -> p_comm (+ p_pid
     from the proc bytes) and prints the spinning process's name.
     Also checks fsck: scans all found procs for p_comm == 'fsck'.

Usage: p23_threadfind3.py <dump>
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
    threads = census_threads(ctx)
    print(f'census: {len(threads)} threads')
    infos = {}
    for tva in sorted(threads):
        ti = thread_info(ctx, tva)
        if ti:
            infos[tva] = ti

    # ---------- 1. calibrate t_tro on the idle thread ----------
    print('\n--- 1. calibrate t_tro offset (idle thread) ---')
    idle = None
    for tva, ti in infos.items():
        if ti['name'] == 'idle #0':
            idle = tva
            break
    t_tro_off = None
    if idle is None:
        print('  idle thread not in census')
    else:
        raw = ctx.read_va(idle, 0x900)
        for o in range(0, 0x900, 8):
            q = struct.unpack_from('<Q', raw, o)[0]
            if not is_kernel_va(q):
                continue
            try:
                owner = ctx.Qva(q + 0x00)
                ttask = ctx.Qva(q + 0x28)
            except Exception:
                continue
            if owner == idle and pac_strip(ttask) == ctx.task_va:
                print(f'  thread+{o:#x} -> thread_ro {q:#x} '
                      f'(owner==thread, tro_task stripped==kernel_task)')
                t_tro_off = o
                break
        if t_tro_off is None:
            print('  t_tro NOT calibrated')
            # debug: print candidate pointers whose +0x00 == thread VA
            for o in range(0, 0x900, 8):
                q = struct.unpack_from('<Q', raw, o)[0]
                if not is_kernel_va(q):
                    continue
                try:
                    if ctx.Qva(q + 0x00) == idle:
                        print(f'  debug: +{o:#x} -> {q:#x} owner==thread, '
                              f'tro_task raw={ctx.Qva(q + 0x28):#018x} '
                              f'stripped={pac_strip(ctx.Qva(q + 0x28)):#x}')
                except Exception:
                    pass

    # ---------- 2. calibrate p_comm offset via idle thread's proc ----------
    print('\n--- 2. calibrate p_comm offset (kernel_task proc) ---')
    p_comm_off = None
    if t_tro_off is not None:
        raw = ctx.read_va(idle, 0x900)
        tro = struct.unpack_from('<Q', raw, t_tro_off)[0]
        tproc = ctx.Qva(tro + 0x18)
        print(f'  idle thread_ro {tro:#x}: tro_proc={tproc:#x}')
        pblk = ctx.read_va(tproc, 0x400)
        if pblk:
            j = pblk.find(b'kernel_task\x00')
            if j >= 0:
                p_comm_off = j
                print(f'  p_comm at proc+{j:#x}')
                print(f'  proc head: '
                      f'{[hex(struct.unpack_from("<Q", pblk, k)[0]) for k in range(0, 0x60, 8)]}')
            else:
                print('  "kernel_task" NOT in proc first 0x400 bytes')
        else:
            print('  cannot read proc struct')
    else:
        print('  skipped (no t_tro)')

    # ---------- 3. find the spin thread struct in the thread zone ----------
    print('\n--- 3. find spin thread struct (id 0x226/0x228, stack match) ---')
    tvas = sorted(infos)
    zone_lo = tvas[0] & ~0xFFFFFFF
    zone_hi = (tvas[-1] | 0xFFFFFFF) + 1
    print(f'  thread zone derived: {zone_lo:#x}..{zone_hi:#x}')
    spin_tva = None
    for sva, spa, ln in ctx.segs:
        if not (zone_lo <= sva < zone_hi):
            continue
        if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
            continue
        raw = d.read_pa(spa, ln)
        for off in range(0, ln - 0x500, 8):
            tid = struct.unpack_from('<Q', raw, off + 0x498)[0]
            if tid in (0x226, 0x228):
                st = struct.unpack_from('<Q', raw, off + 0xE8)[0]
                tva = sva + off
                ti = thread_info(ctx, tva)
                print(f'  candidate {tva:#x} id={tid:#x} stack={st:#x} '
                      f'name={ti["name"] if ti else None!r}')
                if st == SPIN_STACK:
                    spin_tva = tva
                    print(f'  ** SPIN THREAD struct: {tva:#x}')
    if spin_tva is None:
        print('  spin thread struct NOT found by id+stack scan')
        return

    # ---------- 4. walk to p_comm ----------
    print('\n--- 4. walk spin thread -> tro_proc -> p_comm ---')
    if t_tro_off is None or p_comm_off is None:
        print(f'  missing calibration (t_tro={t_tro_off} p_comm={p_comm_off})')
        return
    traw = ctx.read_va(spin_tva, 0x900)
    tro = struct.unpack_from('<Q', traw, t_tro_off)[0]
    print(f'  thread_ro {tro:#x}: owner={ctx.Qva(tro):#x} '
          f'tro_proc={ctx.Qva(tro + 0x18):#x} '
          f'tro_proc_ro={ctx.Qva(tro + 0x20):#x} '
          f'tro_task={ctx.Qva(tro + 0x28):#x}')
    tproc = ctx.Qva(tro + 0x18)
    pblk = ctx.read_va(tproc, 0x400)
    comm = pblk[p_comm_off:p_comm_off + 17].split(b'\x00')[0]
    print(f'  ** SPINNING PROCESS: p_comm = {comm!r} (proc {tproc:#x})')
    print(f'     proc head: '
          f'{[hex(struct.unpack_from("<Q", pblk, k)[0]) for k in range(0, 0x60, 8)]}')
    # also print the proc's p_pid field area: p_pid is an int after p_mlock;
    # dump the 0x40..0x80 region as u32s
    print(f'     proc u32s +0x40..0x80: '
          f'{[hex(struct.unpack_from("<I", pblk, k)[0]) for k in range(0x40, 0x80, 4)]}')

    # ---------- 5. fsck check: all census threads -> procs ----------
    print('\n--- 5. fsck check across census threads ---')
    seen = set()
    for tva, ti in infos.items():
        try:
            traw = ctx.read_va(tva, 0x900)
            tro = struct.unpack_from('<Q', traw, t_tro_off)[0]
            if not is_kernel_va(tro):
                continue
            tproc = ctx.Qva(tro + 0x18)
            if tproc in seen or not is_kernel_va(tproc):
                continue
            seen.add(tproc)
            pblk = ctx.read_va(tproc, 0x400)
            if not pblk:
                continue
            comm = pblk[p_comm_off:p_comm_off + 17].split(b'\x00')[0]
            print(f'  proc {tproc:#x}: {comm!r}')
        except Exception as e:
            print(f'  thread {tva:#x}: error {e}')


if __name__ == '__main__':
    main()
