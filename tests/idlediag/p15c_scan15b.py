#!/usr/bin/env python3
"""Phase 15 continuation: scan APFS __TEXT_EXEC for accesses at struct
offsets 0x15b (byte), 0x15a (halfword), 0x158 (word/qword) — the
apfs_mount_livefs RO-override byte lives at devstruct+0x15b, which is
bit0 of the byte at the top of the u32 at +0x158 (LE).

Prints every hit with its containing function (nearest symbol).
"""
import struct, sys, pickle, bisect

KC = "/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho"
BASE = 0xFFFFFE0007004000
data = open(KC, "rb").read()

syms = {}
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
chunk = data[LO - BASE:HI - BASE]
n = len(chunk) // 4
words = struct.unpack_from(f"<{n}I", chunk, 0)

# (mask, value, kind, scale) for unsigned-offset loads/stores
PATTERNS = [
    (0xFFC00000, 0x39400000, 'ldrb', 1),
    (0xFFC00000, 0x39000000, 'strb', 1),
    (0xFFC00000, 0x39C00000, 'ldrsb64', 1),
    (0xFFC00000, 0x39800000, 'ldrsb32', 1),
    (0xFFC00000, 0x79400000, 'ldrh', 2),
    (0xFFC00000, 0x79000000, 'strh', 2),
    (0xFFC00000, 0xB9400000, 'ldrW', 4),
    (0xFFC00000, 0xB9000000, 'strW', 4),
    (0xFFC00000, 0xF9400000, 'ldrX', 8),
    (0xFFC00000, 0xF9000000, 'strX', 8),
]

TARGETS = {0x15B, 0x15A, 0x158}
hits = []
for i, w in enumerate(words):
    for mask, val, kind, scale in PATTERNS:
        if (w & mask) == val:
            off = ((w >> 10) & 0xFFF) * scale
            if off in TARGETS:
                hits.append((LO + i * 4, kind, off, (w >> 5) & 0x1F, w & 0x1F))
            break

for va, kind, off, rn, rt in hits:
    name, foff = sym_near(va)
    print(f"{va:#x}: {kind:8s} [x{rn} + {off:#x}] rt=x{rt}  in {name} +{foff:#x}")
print(f"{len(hits)} hits")

# also: ADD-immediate computing +0x15b into a register (base+off split)
print("--- add-imm 0x15b ---")
cnt = 0
for i, w in enumerate(words):
    if (w & 0xFF800000) == 0x91000000:
        imm12 = (w >> 10) & 0xFFF
        if (w >> 22) & 0x1:
            imm12 <<= 12
        if imm12 == 0x15B:
            va = LO + i * 4
            name, foff = sym_near(va)
            print(f"{va:#x}: add x{w & 0x1F}, x{(w >> 5) & 0x1F}, #0x15b  in {name} +{foff:#x}")
            cnt += 1
print(f"{cnt} add hits")
