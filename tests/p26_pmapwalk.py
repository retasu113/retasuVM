#!/usr/bin/env python3
"""Phase 24: identify the spinning process via the pmap lead.

Chain per census thread:
  thread -> t_tro (+0x3D8) -> thread_ro -> tro_proc (+0x18, PAC-stripped)
  -> proc -> p_comm (+0x5CC)
  proc -> p_proc_ro (+0x18) -> proc_ro -> pr_task (+0x08) -> task
  -> task->map (calibrated) -> vm_map -> vm_map->pmap (calibrated)
  -> pmap struct: scan first 0x400 B for the TTBR0 root qword 0x85bcc000
  (the spinning process's TTBR0; occurs exactly once in the dump).
A thread whose task's pmap contains 0x85bcc000 belongs to the spinner.
Calibration of task->map / vm_map->pmap is done on the kernel objects
(_kernel_map vs _kernel_pmap, kernel_task vs _kernel_map), raw+PAC.
Usage: p24_pmapwalk.py <dump>
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx, census_threads, link_of, SLIDE  # noqa: E402

DUMP = sys.argv[1]
SPIN_TTBR0 = 0x85B70000
KP_NEAR = 0xFFFFFE0022A042D0  # _kernel_pmap+0x270, same in p23 and p24
P_COMM_OFF = 0x5CC
T_TRO_OFF = 0x3D8
TRO_PROC_OFF = 0x18
PROC_RO_OFF = 0x18      # proc->p_proc_ro
PR_TASK_OFF = 0x08      # proc_ro->pr_task


def pac_strip(q):
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def is_kva(v):
    return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF


def main():
    ctx = Ctx(DUMP)
    print(f"TTBR root={ctx.root:#x} kernel_task={ctx.task_va:#x} "
          f"kernel_pmap={ctx.pmap_va:#x}")
    kmap_va = ctx.d.u64_phys(link_of("_kernel_map") + SLIDE)  # deref the var
    print(f"_kernel_map var -> struct {kmap_va:#x}")

    # ---- calibrate vm_map->pmap on _kernel_map ----
    vmmap_pmap_off = None
    kmap_raw = ctx.read_va(kmap_va, 0x400)
    for off in range(0, 0x400, 8):
        q = struct.unpack_from("<Q", kmap_raw, off)[0]
        if q == ctx.pmap_va or pac_strip(q) == ctx.pmap_va:
            vmmap_pmap_off = off
            print(f"vm_map->pmap offset = {off:#x} "
                  f"({'raw' if q == ctx.pmap_va else 'stripped'})")
            break
    if vmmap_pmap_off is None:
        print("FAIL: vm_map->pmap offset not found")
        return

    # ---- calibrate task->map on kernel_task ----
    task_map_off = None
    kt_raw = ctx.read_va(ctx.task_va, 0x800)
    for off in range(0, 0x800, 8):
        q = struct.unpack_from("<Q", kt_raw, off)[0]
        if q == kmap_va or pac_strip(q) == kmap_va:
            task_map_off = off
            print(f"task->map offset = {off:#x} "
                  f"({'raw' if q == kmap_va else 'stripped'})")
            break
    if task_map_off is None:
        print("FAIL: task->map offset not found")
        return

    # ---- spinning pmap struct VA (for cross-check) ----
    pmap_cands = ctx.va_cands(0x78E89090)
    print(f"spinning pmap struct VA candidates (PA 0x78e885f8): "
          f"{[hex(c) for c in pmap_cands[:6]]}")

    # ---- walk every census thread ----
    threads = list(census_threads(ctx))
    print(f"census: {len(threads)} threads")
    pmap_to_procs = {}
    for tva in threads:
        try:
            traw = ctx.read_va(tva, 0x900)
            if traw is None:
                continue
            tro = struct.unpack_from("<Q", traw, T_TRO_OFF)[0]
            if not is_kva(tro):
                continue
            tproc_raw = ctx.Qva(tro + TRO_PROC_OFF)
            if tproc_raw is None:
                continue
            proc = pac_strip(tproc_raw)
            if not is_kva(proc):
                continue
            pblk = ctx.read_va(proc, 0x1000)
            if pblk is None:
                continue
            c = pblk[P_COMM_OFF:P_COMM_OFF + 17].split(b"\x00")[0]
            comm = c.decode() if c and all(32 <= ch < 127 for ch in c) else "?"
            # proc -> proc_ro -> task -> map -> pmap
            pro_raw = struct.unpack_from("<Q", pblk, PROC_RO_OFF)[0]
            pro = pac_strip(pro_raw)
            pmap_va = None
            ttbr_hit = False
            kp_hit = False
            if is_kva(pro):
                task_raw = ctx.Qva(pro + PR_TASK_OFF)
                if task_raw is not None:
                    task = pac_strip(task_raw)
                    if is_kva(task):
                        map_raw = ctx.Qva(task + task_map_off)
                        if map_raw is not None:
                            vmmap = pac_strip(map_raw)
                            if is_kva(vmmap):
                                pmap_raw = ctx.Qva(vmmap + vmmap_pmap_off)
                                if pmap_raw is not None:
                                    pmap_va = pac_strip(pmap_raw)
                                    if is_kva(pmap_va):
                                        pb = ctx.read_va(pmap_va, 0x400)
                                        if pb:
                                            for o in range(0, 0x400, 8):
                                                q = struct.unpack_from(
                                                    "<Q", pb, o)[0]
                                                if q == SPIN_TTBR0:
                                                    ttbr_hit = True
                                                if q == KP_NEAR:
                                                    kp_hit = True
            key = (pmap_va, comm)
            pmap_to_procs.setdefault(pmap_va, set()).add(comm)
            if ttbr_hit or kp_hit:
                print(f"  *** MATCH thread={tva:#x} proc={comm!r} "
                      f"pmap={pmap_va:#x} ttbr0_hit={ttbr_hit} "
                      f"kp_near_hit={kp_hit}")
        except Exception as e:
            print(f"  thread {tva:#x}: error {e}")

    print("\n--- distinct pmaps seen (pmap VA -> procs) ---")
    for pmap_va, comms in sorted(pmap_to_procs.items(),
                                 key=lambda kv: str(kv[0])):
        print(f"  pmap={pmap_va} procs={sorted(comms)}")


if __name__ == "__main__":
    main()
