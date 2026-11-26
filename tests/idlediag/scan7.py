#!/usr/bin/env python3
# scan7 (pure python): find kernel stacks by content density of text-range
# return addresses, then walk FP chains under candidate decodings.
# Usage: scan7.py <dump> <hits.txt>
import sys, struct
from collections import Counter

DUMP = sys.argv[1]
HITS = sys.argv[2] if len(sys.argv) > 2 else None
DRAM = 0x70000000
SLIDE = 0x182B4000
TA = (0xFFFFFE000700C000 + SLIDE, 0xFFFFFE00076FC000 + SLIDE)
TB = (0xFFFFFE0007D7C000 + SLIDE, 0xFFFFFE000A3B8000 + SLIDE)
OFF = 0xFFFFFDFFAC000000
C8F_NEXT = 0xFFFFFE8F414E0000
C8F_SELF = 0xFFFFFE8F414E0080
HEAP_START = 0x3C00000
SIZE = 0x100000000

f = open(DUMP, 'rb')

def in_text(v):
    return (TA[0] <= v < TA[1]) or (TB[0] <= v < TB[1])

# pass 1: 64KiB block density
BLK = 0x10000
blocks = []
o = HEAP_START
while o < SIZE:
    f.seek(o); data = f.read(BLK)
    if len(data) < BLK:
        break
    qs = struct.unpack('<%dQ' % (BLK // 8), data)
    c = sum(1 for v in qs if (TA[0] <= v < TA[1]) or (TB[0] <= v < TB[1]))
    if c >= 10:
        blocks.append((o, c))
    o += BLK
print(f"[density] 64K blocks with >=10 text qwords: {len(blocks)}")
for (o, c) in blocks[:60]:
    print(f"   block dump_off=0x{o:x} textq={c}")

# cluster blocks
clusters = []
for (o, c) in blocks:
    if clusters and o == clusters[-1][1]:
        clusters[-1] = (clusters[-1][0], o + BLK, clusters[-1][2] + c)
    else:
        clusters.append((o, o + BLK, c))
print(f"[clusters] {len(clusters)}")
for (s, e, c) in clusters:
    print(f"   dump_off 0x{s:x}..0x{e:x} ({(e - s) // 1024} KiB) textq={c}")

# tro +0x40 decode check vs clusters
if HITS:
    hits = [int(x, 16) for x in open(HITS).read().split()]
    runs = []
    i = 0
    while i < len(hits):
        j = i
        while j + 1 < len(hits) and hits[j + 1] - hits[j] == 0x120:
            j += 1
        if j - i + 1 >= 8:
            runs.append((i, j))
        i = j + 1
    def rd64b(off):
        f.seek(off); return struct.unpack('<Q', f.read(8))[0]
    f40 = set()
    for (a, b) in runs:
        for k in range(a, b + 1):
            f40.add(rd64b(hits[k] + 0x40))
    print(f"[tro] distinct +0x40={len(f40)}")
    for name, C in (("C8F_next", C8F_NEXT), ("C8F_self", C8F_SELF), ("OFF", OFF)):
        hit = 0
        for v in f40:
            pa = v - C
            do = pa - DRAM
            for (s, e, c) in clusters:
                if s - 0x10000 <= do < e:
                    hit += 1; break
        print(f"[tro+0x40 vs clusters] decode {name}: {hit}/{len(f40)} in/near clusters")

# FP chain walk
def rd64b(off):
    f.seek(off); return struct.unpack('<Q', f.read(8))[0]

def walk(start_pa, C, maxlen=48):
    chain = []
    fp = start_pa
    seen = set()
    while len(chain) < maxlen and fp not in seen:
        seen.add(fp)
        o = fp - DRAM
        if o < 0 or o + 16 > SIZE:
            break
        prev = rd64b(o); lr = rd64b(o + 8)
        if not in_text(lr):
            break
        chain.append(lr)
        npa = prev - C
        if npa <= fp or npa - fp > 0x10000:
            break
        fp = npa
    return chain

top = sorted(clusters, key=lambda c: -c[2])[:16]
for (s, e, c) in top:
    f.seek(s); data = f.read(e - s)
    qs = struct.unpack('<%dQ' % (len(data) // 8), data)
    best = []
    for i in range(len(qs) - 1):
        if in_text(qs[i + 1]):
            for name, C in (("C8F", C8F_NEXT), ("OFF", OFF)):
                ch = walk(s + DRAM + i * 8, C)
                if len(ch) >= 3:
                    best.append((len(ch), name, s + i * 8, ch))
    best.sort(key=lambda t: -t[0])
    print(f"[walk] cluster 0x{s:x}..0x{e:x} chains>=3: {len(best)}")
    for (ln, name, so, ch) in best[:3]:
        print(f"    len={ln} via {name} start dump_off=0x{so:x}")
        for lr in ch[:24]:
            print(f"        lr=0x{lr:x}")
