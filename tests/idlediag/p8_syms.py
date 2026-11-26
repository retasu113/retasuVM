#!/usr/bin/env python3
"""Phase 8: resolve phase-7 APFS return addresses against kc_syms_mine.json.

kc_syms_mine.json values are UNSLID link addresses. Guest VAs from the
phase-7 boot need the KASLR slide subtracted. Slide in every boot so far:
0x182B4000. We verify the slide by checking that known kernel symbols
(e.g. _lck_mtx_lock, _thread_block) land at addresses consistent with
the phase-6/7 bracket annotations.
"""
import bisect
import json
import sys

SLIDE = 0x182B4000

d = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "kc_syms_mine.json"))
syms = d["syms"]  # [[value, name], ...] sorted
vals = [v for v, _ in syms]
byname = {}
for v, n in syms:
    byname.setdefault(n, []).append(v)


def nearest(va):
    i = bisect.bisect_right(vals, va) - 1
    if i < 0:
        return None
    v, n = syms[i]
    return v, n, va - v


def show(label, slid_va):
    un = slid_va - SLIDE
    r = nearest(un)
    print(f"{label}: slid=0x{slid_va:016x} unslid=0x{un:016x}")
    if r:
        v, n, off = r
        print(f"    -> {n} +0x{off:x}  (sym at unslid 0x{v:016x})")
        # also print next symbol to bound the function size
        i = bisect.bisect_right(vals, un)
        if i < len(syms):
            v2, n2 = syms[i]
            print(f"    next: {n2} at unslid 0x{v2:016x} (func size <= 0x{v2 - v:x})")
    else:
        print("    -> no symbol")


# sanity: known symbols' unslid addresses
for nm in ("_lck_mtx_lock", "_thread_block", "_assert_wait", "__ZN9IOService14probeCandidatesEP9OSOrderedSetPNS_12start_argsE"):
    if nm in byname:
        print(f"known {nm} = 0x{byname[nm][0]:016x} (slid would be 0x{byname[nm][0] + SLIDE:016x})")

print()
# Phase-7 waiter return addresses into APFS-kext text (slid, phase-7 boot)
show("APFS ret site A ([f9] chain, outer)", 0xFFFFFE00222867AC)
show("APFS ret site B ([f9] chain, inner, calls _lck_mtx_lock)", 0xFFFFFE00222867E8)
print()
# Phase-7 kernel static referencing the lock object (slid)
show("kernel static holding E-8 ptr", 0xFFFFFE0022C4DB88)
print()
# Phase-5 boot shared event object content check addresses are per-boot heap; skip.
# Print all symbols in the APFS text neighbourhood of the ret sites (unslid)
lo = 0xFFFFFE00222867AC - SLIDE - 0x4000
hi = 0xFFFFFE00222867E8 - SLIDE + 0x4000
print(f"symbols in unslid [0x{lo:016x}, 0x{hi:016x}]:")
i = bisect.bisect_left(vals, lo)
while i < len(syms) and vals[i] <= hi:
    print(f"  0x{vals[i]:016x}  {syms[i][1]}")
    i += 1
