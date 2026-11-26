#!/usr/bin/env python3
"""Phase 23: debug the 4 high-id thread candidates (226-229) that the
validator rejected; dump their thread_ro and thread-struct fields.

Usage: p23_threadfind7.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402

DUMP = sys.argv[1]
DRAM = 0x70000000
CANDS = [
    (164665384, 227, 0xfffffe173ffcd300, 0xfffffe4c122ec000),
    (164667424, 229, 0xfffffe173ffcdde0, 0xfffffe4c12304000),
    (164671504, 226, 0xfffffe173ffcef80, 0xfffffe4c122e0000),
    (164673544, 228, 0xfffffe173ffccd60, 0xfffffe4c122f8000),
]


def main():
    ctx = Ctx(DUMP)
    print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')
    for off, cid, tro, stk in CANDS:
        pa = DRAM + off
        print(f'\n=== candidate id={cid:#x} file_off={off} PA={pa:#x} '
              f'tro={tro:#x} stk={stk:#x} ===')
        tro_pa = ctx.pa_of(tro)
        print(f'  pa_of(tro) = {tro_pa if tro_pa is None else hex(tro_pa)}')
        if tro_pa is None:
            continue
        raw = ctx.d.read_pa(tro_pa, 0x40)
        owner = struct.unpack_from('<Q', raw, 0x00)[0]
        cred = struct.unpack_from('<Q', raw, 0x08)[0]
        realcred = struct.unpack_from('<Q', raw, 0x10)[0]
        tproc = struct.unpack_from('<Q', raw, 0x18)[0]
        tprocr = struct.unpack_from('<Q', raw, 0x20)[0]
        ttask = struct.unpack_from('<Q', raw, 0x28)[0]
        print(f'  thread_ro @PA {tro_pa:#x}: owner={owner:#x} cred={cred:#x} '
              f'realcred={realcred:#x}')
        print(f'    tro_proc={tproc:#x} tro_proc_ro={tprocr:#x} '
              f'tro_task={ttask:#x}')
        print(f'  pa_of(owner) = {ctx.pa_of(owner) if owner else None} '
              f'(want {pa:#x})')
        # thread struct fields at the candidate base
        t = ctx.d.read_pa(pa, 0x900)
        print(f'  thread struct @PA {pa:#x}:')
        print(f'    +0x018 wait_event={struct.unpack_from("<Q", t, 0x18)[0]:#x}')
        print(f'    +0x0E8 stack={struct.unpack_from("<Q", t, 0xE8)[0]:#x} '
              f'(cand stk={stk:#x})')
        print(f'    +0x3D8 tro={struct.unpack_from("<Q", t, 0x3D8)[0]:#x}')
        print(f'    +0x498 id={struct.unpack_from("<Q", t, 0x498)[0]:#x}')
        # state field: thread state is an int after machine; try +0x500ish
        # print a few u32s around the state area for orientation
        print(f'    +0x4F0..+0x520 u32s: '
              f'{[hex(struct.unpack_from("<I", t, k)[0]) for k in range(0x4F0, 0x520, 4)]}')
        # if owner matches, walk to proc
        if ctx.pa_of(owner) == pa:
            print('  ** VALIDATED (owner back-pointer matches)')
            from p23_threadfind2 import pac_strip
            tp = pac_strip(tproc)
            pblk = ctx.read_va(tp, 0x1000)
            if pblk:
                comm = pblk[0x5cc:0x5cc + 17].split(b'\x00')[0]
                print(f'  proc {tp:#x}: {comm!r}')


if __name__ == '__main__':
    main()
