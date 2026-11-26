#!/usr/bin/env python3
"""Phase 23 (attempt 4): array forensics + p_comm calibration (wide proc read).

  1. Scan the whole dump for the array signature q1==0x008a9c8a00000000;
     list every entry (PA, q0, stack VA) and cross-check against census.
  2. Dump the region around the array (PA 0x77fdd000-0x77fdf000) to find
     the containing struct.
  3. Validate +0xE8 as kernel_stack: walk the idle thread's +0xE8 VA
     to a PA and inspect the top of that stack page.
  4. Calibrate p_comm: idle thread -> t_tro (+0x3D8) -> tro_proc (+0x18)
     -> proc struct; read 0x1000 bytes, find b'kernel_task\\0'.
  5. Enumerate p_comm for every census thread's proc (fsck check).

Usage: p23_threadfind4.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

DUMP = sys.argv[1]
DRAM = 0x70000000
SIG = 0x008a9c8a00000000


def main():
    ctx = Ctx(DUMP)
    d = ctx.d
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')
    data = open(DUMP, 'rb').read()

    # ---------- 1. whole-dump scan for the array signature ----------
    print('\n--- 1. array-signature scan (q1 == 0x008a9c8a00000000) ---')
    pat = struct.pack('<Q', SIG)
    offs = []
    i = data.find(pat)
    while i != -1:
        if i % 8 == 0:
            offs.append(i)
        i = data.find(pat, i + 1)
    print(f'  {len(offs)} aligned occurrences')
    stacks = {}
    threads = census_threads(ctx)
    infos = {}
    for tva in sorted(threads):
        ti = thread_info(ctx, tva)
        if ti:
            infos[tva] = ti
            stacks[ti['stack_va']] = (tva, ti['id'], ti['name'])
    for off in offs:
        # entry base is 8 bytes before q1 (q0 at -8, stack at +8, q3 at +0x10)
        base = off - 8
        q0 = struct.unpack_from('<Q', data, base)[0]
        stk = struct.unpack_from('<Q', data, off + 8)[0]
        q3 = struct.unpack_from('<Q', data, off + 0x10)[0]
        pa = DRAM + base
        inc = stacks.get(stk)
        print(f'  entry PA {pa:#x}: q0={q0:#018x} stack={stk:#x} q3={q3:#018x} '
              f'{"census: " + str(inc) if inc else "NOT-in-census"}')

    # ---------- 2. region around the array ----------
    print('\n--- 2. region PA 0x77fdd000..0x77fdf000 (non-zero qwords) ---')
    for pa in range(0x77fdd000, 0x77fdf000, 8):
        v = struct.unpack_from('<Q', data, pa - DRAM)[0]
        if v == 0:
            continue
        asc = ''
        b = struct.pack('<Q', v)
        if all(32 <= c < 127 or c == 0 for c in b):
            asc = repr(b)
        print(f'  {pa:#x} {v:#018x} {asc}')

    # ---------- 3. validate +0xE8 as kernel_stack (idle thread) ----------
    print('\n--- 3. validate +0xE8 (idle thread stack) ---')
    idle = None
    for tva, ti in infos.items():
        if ti['name'] == 'idle #0':
            idle = tva
            break
    if idle is None:
        print('  idle thread not found')
    else:
        ti = infos[idle]
        print(f'  idle thread {idle:#x}: +0xE8 stack={ti["stack_va"]:#x} '
              f'+0xF0={ctx.Qva(idle + 0xF0):#x}')
        pa = ctx.pa_of(ti['stack_va'])
        print(f'  stack VA walks to PA {pa}')
        if pa:
            top = d.read_pa(pa + 0x3F00, 0x100)
            nz = [(pa + 0x3F00 + k, struct.unpack_from('<Q', top, k)[0])
                  for k in range(0, 0x100, 8)
                  if struct.unpack_from('<Q', top, k)[0] != 0]
            print(f'  non-zero qwords in top 256 B of the stack page: {len(nz)}')
            for a, v in nz[:10]:
                print(f'    {a:#x} {v:#018x}')

    # ---------- 4. p_comm calibration (wide proc read) ----------
    print('\n--- 4. p_comm calibration (idle thread proc, 0x1000-byte read) ---')
    p_comm_off = None
    if idle is not None:
        traw = ctx.read_va(idle, 0x900)
        tro = struct.unpack_from('<Q', traw, 0x3D8)[0]
        tproc = ctx.Qva(tro + 0x18)
        print(f'  idle thread_ro {tro:#x}: tro_proc={tproc:#x} '
              f'tro_proc_ro={ctx.Qva(tro + 0x20):#x} '
              f'tro_task={ctx.Qva(tro + 0x28):#x}')
        pblk = ctx.read_va(tproc, 0x1000)
        if pblk:
            j = pblk.find(b'kernel_task\x00')
            if j >= 0:
                p_comm_off = j
                print(f'  ** p_comm at proc+{j:#x}')
                print(f'  proc u32s +0x00..0x80: '
                      f'{[hex(struct.unpack_from("<I", pblk, k)[0]) for k in range(0, 0x80, 4)]}')
            else:
                print('  "kernel_task" NOT in proc first 0x1000 bytes')
                # print printable strings in the proc struct for orientation
                import re
                for m in re.finditer(rb'[ -~]{4,}', pblk):
                    print(f'    +{m.start():#x}: {m.group()!r}')
        else:
            print('  cannot read proc struct')

    # ---------- 5. enumerate p_comm for census threads ----------
    print('\n--- 5. p_comm for every census thread (fsck check) ---')
    if p_comm_off is None:
        print('  skipped (no p_comm offset)')
        return
    seen = {}
    for tva, ti in infos.items():
        try:
            traw = ctx.read_va(tva, 0x900)
            tro = struct.unpack_from('<Q', traw, 0x3D8)[0]
            if not (0xFFFFFE0000000000 <= tro <= 0xFFFFFEFFFFFFFFFF):
                continue
            tproc = ctx.Qva(tro + 0x18)
            if not (0xFFFFFE0000000000 <= tproc <= 0xFFFFFEFFFFFFFFFF):
                continue
            if tproc in seen:
                continue
            pblk = ctx.read_va(tproc, 0x1000)
            if not pblk:
                continue
            comm = pblk[p_comm_off:p_comm_off + 17].split(b'\x00')[0]
            if comm and all(32 <= c < 127 for c in comm):
                seen[tproc] = comm
                print(f'  proc {tproc:#x}: {comm!r}')
        except Exception as e:
            print(f'  thread {tva:#x}: error {e}')
    print(f'  {len(seen)} distinct procs named')
    if b'fsck' in seen.values():
        print('  ** fsck IS present among census-thread procs')
    else:
        print('  fsck NOT among census-thread procs')


if __name__ == '__main__':
    main()
