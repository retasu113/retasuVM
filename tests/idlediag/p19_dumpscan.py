#!/usr/bin/env python3
# Phase 19: scan the home_p19 frontier dump for 16 KiB windows whose
# SHA-256 equals the GOT hash (guest's bad block) or the EXPECTED hash
# (a correct copy). Dump = guest physical RAM from DRAM base
# 0x70000000 (phase-4 tooling convention), 4096 MB.
import hashlib, sys

DUMP = sys.argv[1]
GOT = "002c0ae7a8372504b094c9596d568512770dca087b1d4281bf636425f27360ff"
EXP = "7f25b180bdfa4c776d6885f8b444d508eca4eaaa80f4fdbab0342c4e60dc4e53"
BASE = 0x70000000
BLK = 16384

def scan(step):
    hits_got, hits_exp = [], []
    with open(DUMP, "rb") as f:
        data = f.read()
    n = len(data)
    print(f"dump size {n} ({n//1048576} MiB); scanning step={step}")
    off = 0
    while off + BLK <= n:
        h = hashlib.sha256(data[off:off+BLK]).hexdigest()
        if h == GOT:
            hits_got.append(off)
            print(f"  GOT  at fileoff 0x{off:x}  PA 0x{BASE+off:x}")
        elif h == EXP:
            hits_exp.append(off)
            print(f"  EXP  at fileoff 0x{off:x}  PA 0x{BASE+off:x}")
        off += step
    return hits_got, hits_exp

g, e = scan(16384)
if not g and not e:
    print("no hits at 16K alignment; trying 4K alignment")
    g, e = scan(4096)
print(f"done: GOT hits={len(g)} EXP hits={len(e)}")
