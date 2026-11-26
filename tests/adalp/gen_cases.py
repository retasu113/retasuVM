#!/usr/bin/env python3
# Generate the ADALP-group differential: oracle.s (qemu-aarch64) + cases.swift
# (our engine harness). One shared case list, deterministic RNG.
# Word construction follows QEMU a64.decode (two-register miscellaneous):
#   SADDLP_v  0.00 1110 ..1 00000 00101 0 rn rd   (U=0, opc=00101)
#   UADDLP_v  0.10 1110 ..1 00000 00101 0 rn rd   (U=1)
#   SADALP_v  0.00 1110 ..1 00000 01101 0 rn rd   (U=0, opc=01101)
#   UADALP_v  0.10 1110 ..1 00000 01101 0 rn rd   (U=1)
# i.e. base 0x0E200000 | Q<<30 | U<<29 | size<<22 | opc<<11 | rn<<5 | rd.
# Semantics (QEMU gengvec.c gen_saddlp_vec/gen_sadalp_vec/gen_uaddlp_vec and
# the neon_addlp helpers): dest element i (width 2*esz) =
#   ext(src[2i]) + ext(src[2i+1])          (ADDLP)
#   dest[i] + ext(src[2i]) + ext(src[2i+1]) (ADALP, load_dest)
# ext = sign-extend for S, zero-extend for U. Operand size = Q ? 16 : 8
# bytes; result bytes above the operand size are zero.
# A Python model of the same semantics is emitted to model_expected.txt so
# the oracle output can be cross-checked against an independent derivation
# before any Swift is written.
import random, struct

rng = random.Random(20261119)

def r128():
    return (rng.getrandbits(64), rng.getrandbits(64))  # (lo, hi) == fpRegisters pair

def word(q, u, size, opc, rn, rd):
    return (0x0E200000 | (q << 30) | (u << 29) | (size << 22)
            | (opc << 11) | (rn << 5) | rd)

OPS = [("saddlp", 0, 5), ("uaddlp", 1, 5), ("sadalp", 0, 13), ("uadalp", 1, 13)]

ZERO = (0, 0)
ONES = (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)
B80 = (0x8080808080808080, 0x8080808080808080)   # every byte 0x80
B7F = (0x7F7F7F7F7F7F7F7F, 0x7F7F7F7F7F7F7F7F)   # every byte 0x7F
ALT = (0xFF00FF00FF00FF00, 0x00FF00FF00FF00FF)   # alternating sign bits

cases = []  # (name, word, rd, rn, vd, vn)
def add(name, w, rd, rn, vd=None, vn=None):
    cases.append((name, w, rd, rn,
                  vd if vd is not None else r128(),
                  vn if vn is not None else r128()))

for opname, u, opc in OPS:
    for size in (0, 1, 2):
        for q in (0, 1):
            tag = f"{opname}_s{size}q{q}"
            for i in range(3):
                add(f"{tag}_r{i}", word(q, u, size, opc, 1, 0), 0, 1)
            add(f"{tag}_ones", word(q, u, size, opc, 1, 0), 0, 1, vn=ONES)
            add(f"{tag}_zero", word(q, u, size, opc, 1, 0), 0, 1, vn=ZERO)
            add(f"{tag}_b80", word(q, u, size, opc, 1, 0), 0, 1, vn=B80)
            add(f"{tag}_b7f", word(q, u, size, opc, 1, 0), 0, 1, vn=B7F)
            add(f"{tag}_alt", word(q, u, size, opc, 1, 0), 0, 1, vn=ALT)
            if opname.endswith("adalp"):
                # dest == source aliasing (accumulate in place). Both
                # harnesses load vd then vn into the same register, so
                # the effective accumulator input is vn: pin vd := vn.
                v = r128()
                add(f"{tag}_alias", word(q, u, size, opc, 5, 5), 5, 5, vd=v, vn=v)

# The exact guest faulting word: UADALP v0.2d, v20.4s (APFS _fletcher64 +0x5c)
add("uadalp_guest", 0x6EA06A80, 0, 20)

# ---- Python model (independent derivation from QEMU gengvec semantics) ----
def to_bytes(v):
    return struct.pack("<QQ", v[0], v[1])

def from_bytes(b):
    lo, hi = struct.unpack("<QQ", b)
    return (lo, hi)

def model(w, vd, vn):
    q = (w >> 30) & 1
    u = (w >> 29) & 1
    size = (w >> 22) & 3
    opc = (w >> 11) & 0x1F
    esz = 1 << size
    opbytes = 16 if q else 8
    nb = to_bytes(vn)
    db = to_bytes(vd)
    out = bytearray(16)
    pairs = opbytes // (2 * esz)
    for i in range(pairs):
        def elem(idx):
            raw = int.from_bytes(nb[idx * esz:(idx + 1) * esz], "little")
            if u:
                return raw
            bits = esz * 8
            return raw - (1 << bits) if raw >> (bits - 1) else raw
        s = elem(2 * i) + elem(2 * i + 1)
        if opc == 13:  # ADALP accumulates
            cur = int.from_bytes(db[i * 2 * esz:(i + 1) * 2 * esz], "little")
            s += cur
        mask = (1 << (2 * esz * 8)) - 1
        out[i * 2 * esz:(i + 1) * 2 * esz] = (s & mask).to_bytes(2 * esz, "little")
    return from_bytes(bytes(out))

with open("model_expected.txt", "w") as f:
    for (name, w, rd, rn, vd, vn) in cases:
        e = model(w, vd, vn)
        f.write(f"{name} 0x{e[0]:016X} 0x{e[1]:016X}\n")

# ---- oracle.s ----
# Layout: inputs: per case 32 bytes [vd, vn] (lo,hi each).
# outputs: slot 0..2 = ID regs (16B slots), then one 16B slot per case.
inp = []
for c in cases:
    for v in (c[4], c[5]):
        inp += [v[0], v[1]]

lines = []
lines.append(".text\n.globl _start\n_start:")
lines.append("    mrs x0, id_aa64isar0_el1")
lines.append("    adrp x10, outputs\n    add x10, x10, :lo12:outputs")
lines.append("    str x0, [x10, #0]")
lines.append("    mrs x0, id_aa64isar1_el1")
lines.append("    str x0, [x10, #16]")
lines.append("    mrs x0, id_aa64pfr0_el1")
lines.append("    str x0, [x10, #32]")
lines.append("    adrp x9, inputs\n    add x9, x9, :lo12:inputs")
for i, c in enumerate(cases):
    name, w, rd, rn = c[0], c[1], c[2], c[3]
    base = i * 32
    lines.append(f"    ldr q{rd}, [x9, #{base}]")
    lines.append(f"    ldr q{rn}, [x9, #{base + 16}]")
    lines.append(f"    .word 0x{w:08x}  // {name}")
    lines.append(f"    str q{rd}, [x10, #{48 + i * 16}]")

total = 48 + len(cases) * 16
hexlen = total * 2 + total // 16  # newline every 16 bytes
lines.append(f"""
    adrp x11, outputs
    add x11, x11, :lo12:outputs
    adrp x12, hexbuf
    add x12, x12, :lo12:hexbuf
    mov x13, #0
print_loop:
    cmp x13, #{total}
    b.ge print_done
    ldrb w14, [x11, x13]
    lsr w15, w14, #4
    and w14, w14, #0xf
    adrp x16, hexdigits
    add x16, x16, :lo12:hexdigits
    ldrb w15, [x16, x15]
    ldrb w14, [x16, x14]
    mov x17, x13
    lsl x17, x17, #1
    add x17, x17, x13, lsr #4
    strb w15, [x12, x17]
    add x17, x17, #1
    strb w14, [x12, x17]
    add x13, x13, #1
    mov x17, x13
    and x17, x17, #0xf
    cbnz x17, print_loop
    mov x17, x13
    lsl x17, x17, #1
    add x17, x17, x13, lsr #4
    mov w14, #10
    strb w14, [x12, x17]
    b print_loop
print_done:
    mov x0, #1
    mov x1, x12
    mov x2, #{hexlen}
    mov x8, #64
    svc #0
    mov x0, #0
    mov x8, #93
    svc #0
    .section .data
    .align 4
inputs:""")
for v in inp:
    lines.append(f"    .quad 0x{v:016x}")
lines.append(f"""outputs:
    .zero {total}
hexbuf:
    .zero {hexlen + 16}
hexdigits:
    .ascii "0123456789abcdef"
""")
open("oracle.s", "w").write("\n".join(lines) + "\n")

# ---- cases.swift (expected filled later by merge_expected.py) ----
with open("cases.swift", "w") as f:
    f.write("// generated by gen_cases.py — expected values merged from oracle_out.txt\n")
    f.write("let cases: [Case] = [\n")
    for (name, w, rd, rn, vd, vn) in cases:
        f.write(f'    Case(name: "{name}", word: 0x{w:08X}, rd: {rd}, rn: {rn}, '
                f'vd: (0x{vd[0]:016X}, 0x{vd[1]:016X}), vn: (0x{vn[0]:016X}, 0x{vn[1]:016X}), '
                f'e: (0, 0)),\n')
    f.write("]\n")

with open("cases_list.txt", "w") as f:
    for c in cases:
        f.write(c[0] + "\n")

print(f"{len(cases)} cases generated")
