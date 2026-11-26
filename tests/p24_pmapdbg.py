#!/usr/bin/env python3
"""Phase 24 debug: dump _kernel_map / kernel_task qwords that are kernel VAs
to find the vm_map->pmap and task->map offsets (scan wide, raw + PAC)."""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx, link_of, SLIDE  # noqa: E402

DUMP = sys.argv[1]
ctx = Ctx(DUMP)
kmap_va = ctx.d.u64_phys(link_of("_kernel_map") + SLIDE)  # deref the var
print(f"_kernel_map var -> struct {kmap_va:#x} kernel_pmap={ctx.pmap_va:#x} "
      f"kernel_task={ctx.task_va:#x}")


def pac_strip(q):
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def dump_kvas(va, size, label):
    raw = ctx.read_va(va, size)
    print(f"--- {label} {va:#x} ({size:#x} B) ---")
    for off in range(0, size, 8):
        q = struct.unpack_from("<Q", raw, off)[0]
        s = pac_strip(q)
        if 0xFFFFFE0000000000 <= q <= 0xFFFFFEFFFFFFFFFF:
            print(f"  +{off:#x} raw kva {q:#x}")
        elif 0xFFFFFE0000000000 <= s <= 0xFFFFFEFFFFFFFFFF and q != s:
            print(f"  +{off:#x} PAC-signed kva {q:#x} -> stripped {s:#x}")


dump_kvas(kmap_va, 0x1000, "_kernel_map")
dump_kvas(ctx.task_va, 0x1000, "kernel_task")
