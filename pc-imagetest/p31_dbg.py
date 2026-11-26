import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
d = ctx.d
for name, va in (("kernel_task", ctx.task_va),
                 ("wqtrace_proc", 0xFFFFFE2DFFC63A0),
                 ("wqtrace_thread", 0xFFFFFE2839D0B010),
                 ("wqtrace_thread2", 0xFFFFFE2839D09828)):
    pa = ctx.pa_of(va)
    l1 = (va >> 36) & 0x7FF
    e1 = d.u64_pa(ctx.root + l1 * 8)
    print(f"{name}: va={va:#x} pa_of={pa} L1idx={l1} L1entry={e1:#x} type={e1 & 3 if e1 else '-'}")
    if e1 and (e1 & 3) == 3:
        l2t = e1 & 0x0000FFFFFFFFC000
        l2 = (va >> 25) & 0x7FF
        e2 = d.u64_pa(l2t + l2 * 8)
        print(f"    L2idx={l2} L2entry={e2:#x} type={e2 & 3 if e2 else '-'}")
        if e2 and (e2 & 3) == 3:
            l3t = e2 & 0x0000FFFFFFFFC000
            l3 = (va >> 14) & 0x7FF
            e3 = d.u64_pa(l3t + l3 * 8)
            print(f"    L3idx={l3} L3entry={e3:#x} type={e3 & 3 if e3 else '-'} -> PA={e3 & 0x0000FFFFFFFFC000 if e3 else '-'}")
print("segs covering 0xFFFFFE2D00000000-0xFFFFFE2E00000000:")
for sva, spa, ln in ctx.segs:
    if 0xFFFFFE2D00000000 <= sva < 0xFFFFFE2E00000000:
        print(f"  seg va={sva:#x} pa={spa:#x} len={ln:#x}")
print("segs covering 0xFFFFFE2800000000-0xFFFFFE2900000000:")
for sva, spa, ln in ctx.segs:
    if 0xFFFFFE2800000000 <= sva < 0xFFFFFE2900000000:
        print(f"  seg va={sva:#x} pa={spa:#x} len={ln:#x}")
print(f"total segs: {len(ctx.segs)}")
