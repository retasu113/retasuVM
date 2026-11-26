#!/usr/bin/env python3
"""Phase-3 scan step 4:
 - save all *kernel_task pointer hits to hits1.txt; summarize stride runs
 - hexdump the candidate kernel task struct (untagged VA) for queue discovery
Usage: scan4.py <dump> <verpat.bin>
"""
import mmap
import struct
import sys

DRAM_BASE = 0x70000000
SLIDE = 0x182B4000
VER_LINK_VA = 0xFFFFFE000704435D
KERNEL_TASK_SYM = 0xFFFFFE0007821438
KT_TAGGED = 0xFFFFFE249E0FC0A8
KT_UNTAGGED = 0xFFFFFE009E0FC0A8


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

    # --- all hits for the tagged task pointer
    needle = struct.pack("<Q", KT_TAGGED)
    hits = []
    st = 0
    while True:
        j = mm.find(needle, st)
        if j < 0:
            break
        hits.append(j)
        st = j + 1
    with open("hits1.txt", "w") as fh:
        for h in hits:
            fh.write(f"{h:x}\n")
    print(f"[hits] {len(hits)} saved to hits1.txt")
    # stride-run summary (delta == 0x120)
    runs = []
    start = prev = hits[0]
    for h in hits[1:]:
        if h - prev == 0x120:
            prev = h
        else:
            runs.append((start, prev))
            start = prev = h
    runs.append((start, prev))
    runs.sort(key=lambda r: r[1] - r[0], reverse=True)
    print("[runs] top stride-0x120 runs (start_off, end_off, count):")
    for s, e in runs[:8]:
        print(f"    0x{s:x} .. 0x{e:x}  count={int((e - s) / 0x120) + 1}  VA_start=0x{pa2va(s + DRAM_BASE):x}")

    # --- candidate task struct dump
    toff = va2off(KT_UNTAGGED)
    print(f"[task] untagged VA 0x{KT_UNTAGGED:x} -> dump_off 0x{toff:x}")
    for i in range(0, 0x200, 8):
        v = struct.unpack_from("<Q", mm, toff + i)[0]
        print(f"    task+0x{i:03x}: 0x{v:016x}")


if __name__ == "__main__":
    main()
