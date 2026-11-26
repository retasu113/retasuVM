#!/usr/bin/env python3
"""Phase 15: scan APFS __TEXT_EXEC for ADRP+ADD/LDR pairs computing target VAs.
Usage: p15_adrpxref2.py <targetVA hex> [more...]"""
import struct, sys, pickle, bisect

KC = "/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho"
BASE = 0xFFFFFE0007004000
data = open(KC, "rb").read()

def load_commands(off):
    ncmds, = struct.unpack_from("<I", data, off + 16)
    p = off + 32
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, p)
        out.append((cmd, p))
        p += size
    return out

entries = []
for cmd, p in load_commands(0):
    if cmd == 0x80000035:
        vmaddr, fileoff, eoff = struct.unpack_from("<QQQ", data, p + 8)
        end = data.index(b"\x00", p + eoff)
        entries.append((data[p + eoff:end].decode(), vmaddr, fileoff))

syms = {}
for name, vmaddr, fileoff in entries:
    for cmd, p in load_commands(fileoff):
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, p + 8)
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                if n_strx == 0 or n_value == 0:
                    continue
                end = data.index(b"\x00", stroff + n_strx)
                s = data[stroff + n_strx:end].decode("utf-8", "replace")
                if name == 'com.apple.filesystems.apfs':
                    syms.setdefault(n_value, s)
try:
    kcsyms, _ = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
    for va, s in kcsyms:
        syms.setdefault(va, s)
except Exception:
    pass
sorted_syms = sorted(syms.items())
vals = [v for v, _ in sorted_syms]

def sym_near(va):
    i = bisect.bisect_right(vals, va) - 1
    return (sorted_syms[i][1], va - sorted_syms[i][0]) if i >= 0 else ("?", 0)

LO, HI = 0xfffffe0009f9d8a0, 0xfffffe000b122338
targets = set(int(x, 16) for x in sys.argv[1:])
chunk = data[LO - BASE:HI - BASE]
n = len(chunk) // 4
words = struct.unpack_from(f"<{n}I", chunk, 0)
adrp_val = {}
hits = []
for i, w in enumerate(words):
    va = LO + i * 4
    if (w & 0x9F000000) == 0x90000000:
        rd = w & 0x1F
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 0x3)
        if imm & 0x100000:
            imm -= 0x200000
        adrp_val[rd] = ((va & ~0xFFF) + (imm << 12), i)
        continue
    if (w & 0xFF800000) == 0x91000000:
        rd = w & 0x1F
        rn = (w >> 5) & 0x1F
        imm12 = (w >> 10) & 0xFFF
        if (w >> 22) & 0x1:
            imm12 <<= 12
        if rn in adrp_val and i - adrp_val[rn][1] <= 10:
            tgt = adrp_val[rn][0] + imm12
            if tgt in targets:
                hits.append((va, tgt, 'add'))
        continue
    if (w & 0xFFC00000) in (0xF9400000, 0xB9400000):
        rn = (w >> 5) & 0x1F
        imm12 = ((w >> 10) & 0xFFF) * (8 if (w & 0xFFC00000) == 0xF9400000 else 4)
        if rn in adrp_val and i - adrp_val[rn][1] <= 10:
            tgt = adrp_val[rn][0] + imm12
            if tgt in targets:
                hits.append((va, tgt, 'ldr'))
        continue

for va, tgt, kind in hits:
    name, off = sym_near(va)
    print(f"  ref {va:#x} ({kind}) -> {tgt:#x} in {name} +{off:#x}")
print(len(hits), "refs")
