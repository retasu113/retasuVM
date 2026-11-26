#!/usr/bin/env python3
"""Phase-3 scan step 3: reverse-pointer census for *kernel_task.

For each candidate form of the task pointer (raw / untagged), count and
locate every qword in the dump equal to it. Thread (or thread_ro) structs
each hold one such pointer at a fixed offset -> hit clustering reveals them.
Usage: scan3.py <dump> <verpat.bin>
"""
import mmap
import struct
import sys
from collections import Counter

DRAM_BASE = 0x70000000
SLIDE = 0x182B4000
VER_LINK_VA = 0xFFFFFE000704435D
KERNEL_TASK_SYM = 0xFFFFFE0007821438


def main():
    dump_path, pat_path = sys.argv[1], sys.argv[2]
    pat = open(pat_path, "rb").read()
    f = open(dump_path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    doff = mm.find(pat)
    off = (VER_LINK_VA + SLIDE) - (doff + DRAM_BASE)
    print(f"[anchor] OFF=0x{off:x}", flush=True)

    def va2off(v):
        return v - off - DRAM_BASE

    def pa2va(p):
        return p + off

    def rd64(v):
        return struct.unpack_from("<Q", mm, va2off(v))[0]

    kt_raw = rd64(KERNEL_TASK_SYM + SLIDE)
    print(f"[kt] *kernel_task raw = 0x{kt_raw:x}", flush=True)
    cands = [("raw", kt_raw),
             ("untag39_32", kt_raw & ~0xFF00000000),
             ("untag47_40", kt_raw & ~0xFF0000000000),
             ("untag_both", kt_raw & ~0xFFFF00000000)]
    best = None
    for label, cand in cands:
        needle = struct.pack("<Q", cand)
        hits = []
        st = 0
        while len(hits) < 20000:
            j = mm.find(needle, st)
            if j < 0:
                break
            hits.append(j)
            st = j + 1
        print(f"[kt] {label} VA=0x{cand:x}: {len(hits)} hits", flush=True)
        if 50 < len(hits) < 20000 and (best is None or len(hits) > len(best[2])):
            best = (label, cand, hits)
    if not best:
        print("[kt] no candidate in plausible range")
        return
    label, cand, hits = best
    print(f"[kt] best = {label} 0x{cand:x} with {len(hits)} hits")
    vas = [pa2va(h + DRAM_BASE) for h in hits]
    for m in (0x80, 0x100, 0x200, 0x400, 0x800, 0x1000):
        c = Counter(v & (m - 1) for v in vas)
        top = c.most_common(3)
        print(f"   mod 0x{m:x}: {[(hex(k), v) for k, v in top]}")
    deltas = Counter()
    for a, b in zip(hits, hits[1:]):
        d = b - a
        if 0 < d < 0x20000:
            deltas[d] += 1
    print(f"   top deltas: {[(hex(k), v) for k, v in deltas.most_common(8)]}")
    # context dump around first 6 hits: qwords from hit-0x50 to hit+0x70
    for h in hits[:6]:
        hva = pa2va(h + DRAM_BASE)
        print(f"--- hit at VA 0x{hva:x} (dump_off 0x{h:x}) ---")
        base = h - 0x50
        for i in range(0, 0xC0, 8):
            v = struct.unpack_from("<Q", mm, base + i)[0]
            mark = " <== task ptr" if base + i == h else ""
            print(f"    VA 0x{pa2va(base + i + DRAM_BASE):x} (+0x{i - 0x50:+x} rel): 0x{v:016x}{mark}")


if __name__ == "__main__":
    main()
