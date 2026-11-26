#!/usr/bin/env python3
"""Phase-3 scan step 2 (dump1):
 - re-derive OFF from the version-string anchor
 - census of 'IOConfigThread' occurrences outside msgbuf/rodata
 - reverse-pointer census for *kernel_task (raw + untagged): find thread structs
Usage: scan2.py <dump> <verpat.bin>
"""
import mmap
import struct
import sys

DRAM_BASE = 0x70000000
SLIDE = 0x182B4000
VER_LINK_VA = 0xFFFFFE000704435D
KERNEL_TASK_SYM = 0xFFFFFE0007821438
MSGBUF_OFF = 0x6A22484
MSGBUF_END = MSGBUF_OFF + 0x20000


def main():
    dump_path, pat_path = sys.argv[1], sys.argv[2]
    pat = open(pat_path, "rb").read()
    f = open(dump_path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    doff = mm.find(pat)
    off = (VER_LINK_VA + SLIDE) - (doff + DRAM_BASE)
    print(f"[anchor] OFF=0x{off:x}")

    def va2off(v):
        return v - off - DRAM_BASE

    def pa2va(p):
        return p + off

    def rd64(v):
        return struct.unpack_from("<Q", mm, va2off(v))[0]

    # --- IOConfigThread occurrences outside msgbuf + kernel rodata (<0x4000000)
    print("[names] occurrences outside msgbuf/rodata:")
    n_msg = n_ro = 0
    heap_names = []
    start = 0
    while True:
        i = mm.find(b"IOConfigThread", start)
        if i < 0:
            break
        if MSGBUF_OFF <= i < MSGBUF_END:
            n_msg += 1
        elif i < 0x4000000:
            n_ro += 1
        else:
            raw = bytes(mm[i:i + 96])
            s = raw.split(b"\0")[0].decode("ascii", "replace")
            heap_names.append((i, s))
            print(f"    dump_off=0x{i:x} VA=0x{pa2va(i + DRAM_BASE):x} {s!r}")
        start = i + 1
    print(f"[names] msgbuf={n_msg} rodata={n_ro} other={len(heap_names)}")

    # pointers to heap name buffers
    for i, s in heap_names:
        nva = pa2va(i + DRAM_BASE)
        needle = struct.pack("<Q", nva)
        hits = []
        st = 0
        while len(hits) < 16:
            j = mm.find(needle, st)
            if j < 0:
                break
            hits.append(j)
            st = j + 1
        print(f"  ptrs to name VA 0x{nva:x} {s!r}: {len(hits)}")
        for h in hits:
            print(f"      at dump_off=0x{h:x} containerVA=0x{pa2va(h + DRAM_BASE):x}")

    # --- kernel_task reverse pointers
    kt_raw = rd64(KERNEL_TASK_SYM + SLIDE)
    print(f"[kt] *kernel_task raw = 0x{kt_raw:x}")
    cands = {"raw": kt_raw,
             "untag32_39": kt_raw & ~0xFF00000000,
             "untag_topbyte": kt_raw & 0x00FFFFFFFFFFFFFF}
    for label, cand in cands.items():
        needle = struct.pack("<Q", cand)
        hits = []
        st = 0
        while True:
            j = mm.find(needle, st)
            if j < 0:
                break
            hits.append(j)
            st = j + 1
        print(f"[kt] candidate {label} VA=0x{cand:x}: {len(hits)} pointer hits in dump")
        if 10 < len(hits) < 5000:
            # stride analysis on sorted hits
            deltas = {}
            for a, b in zip(hits, hits[1:]):
                d = b - a
                if d < 0x10000:
                    deltas[d] = deltas.get(d, 0) + 1
            top = sorted(deltas.items(), key=lambda kv: -kv[1])[:6]
            print(f"      common strides: {[(hex(k), v) for k, v in top]}")
            for h in hits[:12]:
                print(f"      hit dump_off=0x{h:x} containerVA=0x{pa2va(h + DRAM_BASE):x}")


if __name__ == "__main__":
    main()
