#!/usr/bin/env python3
"""Phase-3 scan step 6: crack heap pointer encodings empirically.
 - name-record chain at 0x8B68000: linearity of +0x00 -> C8F candidates
 - tro +0x40 (stack?) and +0x110 (thread?) targets under candidate decodings,
   scored by 'looks like a kernel stack' / back-pointer checks
Usage: scan6.py <dump> <verpat.bin>
"""
import mmap
import struct
import sys
from collections import Counter

DRAM_BASE = 0x70000000
SLIDE = 0x182B4000
VER_LINK_VA = 0xFFFFFE000704435D
TEXT_EXEC_LO = 0xFFFFFE0007D7C000 + SLIDE   # runtime VA range of kernel text
TEXT_EXEC_HI = 0xFFFFFE000A3B8000 + SLIDE
NAME_BASE = 0x8B68000
TRO_HIT = 0xA048150


def main():
    dump_path, pat_path = sys.argv[1], sys.argv[2]
    pat = open(pat_path, "rb").read()
    f = open(dump_path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    doff = mm.find(pat)
    OFF = (VER_LINK_VA + SLIDE) - (doff + DRAM_BASE)
    print(f"[anchor] OFF=0x{OFF:x}")

    def rd64o(o):
        return struct.unpack_from("<Q", mm, o)[0]

    def va_static_to_off(v):
        return v - OFF - DRAM_BASE

    # --- 1. name chain linearity
    print("[chain] name records +0x00 values:")
    prev = None
    for k in range(6):
        o = NAME_BASE + k * 0x80
        v = rd64o(o)
        print(f"   rec{k} dump_off=0x{o:x} +0x00=0x{v:016x} delta_vs_prev={'' if prev is None else hex(v - prev)}")
        prev = v
    v0 = rd64o(NAME_BASE)
    # hypotheses: field0 = VA of next record (dump_off+0x80) or of self
    for label, ref_off in (("next", NAME_BASE + 0x80), ("self", NAME_BASE)):
        C = v0 - (ref_off + DRAM_BASE)
        print(f"[chain] hypothesis {label}: C8F = 0x{C:x} (check rec1: pred=0x{ref_off + 0x80 + DRAM_BASE + C:x} actual=0x{rd64o(NAME_BASE + 0x80):x})")

    # --- 2. tro fields and stride stats over all records from hits1.txt
    hits = [int(x, 16) for x in open("hits1.txt").read().split()]
    # records whose hit is part of a 0x120 run: keep hits h where h+0x120 or h-0x120 also a hit
    hset = set(hits)
    recs = [h for h in hits if (h + 0x120) in hset or (h - 0x120) in hset]
    print(f"[tro] {len(recs)} hits in 0x120 runs (of {len(hits)} total)")
    for foff, nm in ((0x20, "+0x20"), (0x38, "+0x38"), (0x40, "+0x40"), (0x110, "+0x110")):
        vals = sorted(rd64o(r + foff) for r in recs)
        diffs = Counter()
        for a, b in zip(vals, vals[1:]):
            d = b - a
            if 0 < d < 0x100000:
                diffs[d] += 1
        print(f"[tro] {nm}: distinct={len(set(vals))} top diffs={[(hex(k), v) for k, v in diffs.most_common(5)]}")

    # --- 3. decode candidates for tro@TRO_HIT fields
    for foff, nm in ((0x40, "stack?"), (0x110, "thread?"), (0x20, "f20"), (0x38, "f38")):
        v = rd64o(TRO_HIT + foff)
        print(f"[fld] tro+0x{foff:03x} ({nm}) = 0x{v:016x}")
        tag = (v >> 32) & 0xFF
        cands = {
            "static": v - OFF - DRAM_BASE,
            "addtag": v - (tag << 32) - OFF - DRAM_BASE,
        }
        # chain-space decoding: assume same C as name chain 'next' hypothesis
        C8F = v0 - (NAME_BASE + 0x80 + DRAM_BASE)
        cands["chainspace"] = v - C8F - DRAM_BASE
        for label, toff in cands.items():
            ok = 0 <= toff < 0x100000000
            print(f"    {label}: target dump_off=0x{toff:x} {'OK' if ok else 'out of range'}")
            if ok:
                # stack-likeness: count qwords decoding into kernel text range
                cnt = 0
                total = 0
                for i in range(0, 0x1000, 8):
                    q = rd64o(toff + i)
                    total += 1
                    if TEXT_EXEC_LO <= q < TEXT_EXEC_HI:
                        cnt += 1
                print(f"        text-VA qwords in first 4K: {cnt}/{total}")
                print(f"        first qwords: {[hex(rd64o(toff + i)) for i in range(0, 0x40, 8)]}")

    # --- 4. back-pointer check for +0x110 under addtag decoding
    v = rd64o(TRO_HIT + 0x110)
    tag = (v >> 32) & 0xFF
    toff = v - (tag << 32) - OFF - DRAM_BASE
    if 0 <= toff < 0x100000000:
        tro_enc = (TRO_HIT + DRAM_BASE) + OFF + (tag << 32)
        found = []
        for i in range(0, 0x800, 8):
            if rd64o(toff + i) == tro_enc:
                found.append(i)
        print(f"[backptr] tro record encoded as 0x{tro_enc:x}; found in thread? target at offsets {found}")


if __name__ == "__main__":
    main()
