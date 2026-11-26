#!/usr/bin/env python3
# scan8: enumerate FP chains (physmap decode) across the heap; output JSONL.
# Usage: scan8.py <dump> <out.jsonl>
import sys, struct, json

DUMP, OUT = sys.argv[1], sys.argv[2]
DRAM = 0x70000000
SLIDE = 0x182B4000
TA = (0xFFFFFE000700C000 + SLIDE, 0xFFFFFE00076FC000 + SLIDE)
TB = (0xFFFFFE0007D7C000 + SLIDE, 0xFFFFFE000A3B8000 + SLIDE)
OFF = 0xFFFFFDFFAC000000
START = 0x3C00000
SIZE = 0x100000000

f = open(DUMP, 'rb')
cache = {}

def rd64(pa):
    o = pa - DRAM
    pg = o & ~0xFFFF
    buf = cache.get(pg)
    if buf is None:
        f.seek(pg); buf = f.read(0x10000)
        if len(cache) > 64:
            cache.clear()
        cache[pg] = buf
    return struct.unpack_from('<Q', buf, o - pg)[0]

def in_text(v):
    return (TA[0] <= v < TA[1]) or (TB[0] <= v < TB[1])

def walk(start_pa, maxlen=48):
    chain = []
    fp = start_pa
    seen = set()
    while len(chain) < maxlen and fp not in seen:
        seen.add(fp)
        if fp - DRAM < 0 or fp - DRAM + 16 > SIZE:
            break
        prev = rd64(fp); lr = rd64(fp + 8)
        if not in_text(lr):
            break
        chain.append(lr)
        npa = prev - OFF
        if npa <= fp or npa - fp > 0x8000:
            break
        fp = npa
    return chain

# scan in 64K blocks; candidate = 16-aligned offset with text LR at +8
results = {}
o = START
while o < SIZE:
    f.seek(o); data = f.read(0x10000)
    if len(data) < 0x10000:
        break
    qs = struct.unpack('<8192Q', data)
    for i in range(0, 8191, 2):
        if in_text(qs[i + 1]):
            pa = o + DRAM + i * 8
            # quick 2-step check
            prev = qs[i]
            npa = prev - OFF
            if npa <= pa or npa - pa > 0x8000:
                continue
            ch = walk(pa)
            if len(ch) >= 4:
                region = pa & ~0x3FFF
                key = region
                if key not in results or len(ch) > len(results[key][1]):
                    results[key] = (pa, ch)
    o += 0x10000

with open(OUT, 'w') as out:
    for region, (pa, ch) in sorted(results.items()):
        out.write(json.dumps({"stack_region_pa": hex(region), "top_pa": hex(pa),
                              "len": len(ch), "lrs": [hex(x) for x in ch]}) + "\n")
print(f"stacks with chains>=4: {len(results)}")
