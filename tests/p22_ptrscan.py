#!/usr/bin/env python3
"""Phase 22: (1) find every occurrence of the qword 0x16d0cf4a0 (the iov_base
pointer) in the dump, print the following qword (candidate iov_len);
(2) find the qword 0x85b68000 (TTBR0 root) to locate the pmap/task;
(3) find the qword 0x800000000 (the huge length) occurrences."""
import struct

D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
print(f"dump {len(data)} B")

def find_all(pat):
    hits = []
    pos = 0
    while True:
        i = data.find(pat, pos)
        if i < 0:
            break
        hits.append(i)
        pos = i + 1
        if len(hits) > 200:
            break
    return hits

# (1) pointer 0x16d0cf4a0
pat = struct.pack("<Q", 0x16d0cf4a0)
hits = find_all(pat)
print(f"\nqword 0x16d0cf4a0: {len(hits)} hits")
for h in hits[:40]:
    nxt = struct.unpack_from("<Q", data, h + 8)[0] if h + 16 <= len(data) else None
    prv = struct.unpack_from("<Q", data, h - 8)[0] if h >= 8 else None
    print(f"  file {h:#x} PA {h + 0x70000000:#x} prev={prv if prv is None else hex(prv)} next={nxt if nxt is None else hex(nxt)}")

# (2) TTBR0 root 0x85b68000
pat = struct.pack("<Q", 0x85b68000)
hits = find_all(pat)
print(f"\nqword 0x85b68000 (TTBR0 root): {len(hits)} hits")
for h in hits[:40]:
    nxt = struct.unpack_from("<Q", data, h + 8)[0] if h + 16 <= len(data) else None
    prv = struct.unpack_from("<Q", data, h - 8)[0] if h >= 8 else None
    print(f"  file {h:#x} PA {h + 0x70000000:#x} prev={prv if prv is None else hex(prv)} next={nxt if nxt is None else hex(nxt)}")

# (3) huge length 0x800000000
pat = struct.pack("<Q", 0x800000000)
hits = find_all(pat)
print(f"\nqword 0x800000000: {len(hits)} hits")
for h in hits[:40]:
    nxt = struct.unpack_from("<Q", data, h + 8)[0] if h + 16 <= len(data) else None
    prv = struct.unpack_from("<Q", data, h - 8)[0] if h >= 8 else None
    print(f"  file {h:#x} PA {h + 0x70000000:#x} prev={prv if prv is None else hex(prv)} next={nxt if nxt is None else hex(nxt)}")
