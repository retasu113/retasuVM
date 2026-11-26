#!/usr/bin/env python3
"""Phase-3 scan step 5: dump full 0x120 records around a known task-ptr hit,
in both dumps, to identify the record layout.
Usage: scan5.py <dump1> <dump2>
"""
import mmap
import struct
import sys

KT_TAGGED = 0xFFFFFE249E0FC0A8
HIT = 0xA048150  # dump_off of a task-ptr hit inside a stride-0x120 run


def dump_records(mm, label):
    print(f"===== {label} =====")
    base = HIT - 0x120
    for r in range(3):
        print(f"--- record @{base + r * 0x120:#x} (hit is in record 1) ---")
        for i in range(0, 0x120, 8):
            o = base + r * 0x120 + i
            v = struct.unpack_from("<Q", mm, o)[0]
            mark = ""
            if v == KT_TAGGED:
                mark = " <== KT"
            print(f"  +0x{i:03x}: 0x{v:016x}{mark}")


def main():
    f1 = open(sys.argv[1], "rb")
    mm1 = mmap.mmap(f1.fileno(), 0, access=mmap.ACCESS_READ)
    dump_records(mm1, "dump1")
    f2 = open(sys.argv[2], "rb")
    mm2 = mmap.mmap(f2.fileno(), 0, access=mmap.ACCESS_READ)
    # byte-compare the 3-record window between dumps
    a = bytes(mm1[HIT - 0x120:HIT + 0x240])
    b = bytes(mm2[HIT - 0x120:HIT + 0x240])
    diffs = [i for i in range(len(a)) if a[i] != b[i]]
    print(f"[diff] window bytes differing dump1 vs dump2: {len(diffs)}")
    # also compare record 1 alone
    a1 = bytes(mm1[HIT - 0x120:HIT])
    b1 = bytes(mm2[HIT - 0x120:HIT])
    print(f"[diff] record0 differing bytes: {sum(1 for x, y in zip(a1, b1) if x != y)}")


if __name__ == "__main__":
    main()
