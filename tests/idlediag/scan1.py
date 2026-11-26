#!/usr/bin/env python3
"""Phase-3 scan step 1: derive VA<->PA mapping for the dump, validate anchors,
find IOConfigThread name buffers and pointers to them.

Usage: scan1.py <dump> <verpat.bin>
Runs on the PC against the 4 GiB DRAM dump (read-only).
"""
import mmap
import struct
import sys

DRAM_BASE = 0x70000000
SLIDE = 0x182B4000
VER_LINK_VA = 0xFFFFFE000704435D       # version string, link VA (from kernelcache)
KERNEL_TASK_SYM = 0xFFFFFE0007821438   # _kernel_task (link VA)
LOG_BUF_SIZE_SYM = 0xFFFFFE000A8B3678  # __log_buffer_size (link VA)
MSGBUF_PA = 0x76A22484                 # phase-2: msgbuf ring PA


def main():
    dump_path, pat_path = sys.argv[1], sys.argv[2]
    pat = open(pat_path, "rb").read()
    f = open(dump_path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    # --- derive OFF = VA - PA from the version string anchor
    doff = mm.find(pat)
    assert doff >= 0, "version pattern not found"
    pa = doff + DRAM_BASE
    va = VER_LINK_VA + SLIDE
    off = va - pa
    print(f"[anchor] version string at dump_off=0x{doff:x} PA=0x{pa:x} VA=0x{va:x}")
    print(f"[anchor] OFF (VA-PA) = 0x{off:x}")

    def va2off(v):
        return v - off - DRAM_BASE

    def pa2va(p):
        return p + off

    def rd64(v):
        return struct.unpack_from("<Q", mm, va2off(v))[0]

    # --- validate: _kernel_task pointer + log buffer size
    kt = rd64(KERNEL_TASK_SYM + SLIDE)
    print(f"[check] *kernel_task = 0x{kt:x} (dump_off of sym = 0x{va2off(KERNEL_TASK_SYM + SLIDE):x})")
    lbs = rd64(LOG_BUF_SIZE_SYM + SLIDE)
    print(f"[check] __log_buffer_size = {lbs} (0x{lbs:x})")
    msg_va = pa2va(MSGBUF_PA)
    print(f"[check] msgbuf PA 0x{MSGBUF_PA:x} -> VA 0x{msg_va:x} link VA 0x{msg_va - SLIDE:x}")

    # --- cpu_data anchor from phase 1: x20 = 0xFFFFFE001F9C6000
    x20 = 0xFFFFFE001F9C6000
    print(f"[check] park x20 VA 0x{x20:x} -> dump_off 0x{va2off(x20):x}; first qwords there:")
    base = va2off(x20)
    for i in range(8):
        print(f"    +0x{i*8:02x}: 0x{struct.unpack_from('<Q', mm, base + i*8)[0]:016x}")

    # --- find IOConfigThread name buffers
    print("[scan] searching 'IOConfigThread' occurrences...")
    names = []
    start = 0
    while True:
        i = mm.find(b"IOConfigThread", start)
        if i < 0:
            break
        raw = bytes(mm[i:i + 80])
        s = raw.split(b"\0")[0].decode("ascii", "replace")
        names.append((i, s))
        start = i + 1
    print(f"[scan] {len(names)} occurrences")
    for doff2, s in names:
        print(f"    dump_off=0x{doff2:x} PA=0x{doff2 + DRAM_BASE:x} VA=0x{pa2va(doff2 + DRAM_BASE):x} {s!r}")

    # --- find pointers to each distinct name VA
    print("[scan] searching pointers to name buffers...")
    seen = {}
    for doff2, s in names:
        nva = pa2va(doff2 + DRAM_BASE)
        if nva in seen:
            continue
        seen[nva] = s
        needle = struct.pack("<Q", nva)
        hits = []
        st = 0
        while len(hits) < 24:
            j = mm.find(needle, st)
            if j < 0:
                break
            hits.append(j)
            st = j + 1
        print(f"  name VA 0x{nva:x} {s!r}: {len(hits)} pointer hits")
        for h in hits:
            print(f"      ptr at dump_off=0x{h:x} (container VA 0x{pa2va(h + DRAM_BASE):x})")


if __name__ == "__main__":
    main()
