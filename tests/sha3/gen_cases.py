#!/usr/bin/env python3
# Generate the SHA3-group differential: oracle.s (qemu-aarch64) + cases.swift
# (our engine harness). One shared case list, deterministic RNG.
# Word construction follows QEMU a64.decode exactly:
#   EOR3  1100 1110 000 rm:5 0     ra:5 rn:5 rd:5
#   BCAX  1100 1110 001 rm:5 0     ra:5 rn:5 rd:5
#   XAR   1100 1110 100 rm:5 imm:6      rn:5 rd:5
#   RAX1  1100 1110 011 rm:5 100011     rn:5 rd:5
import random, struct

rng = random.Random(20261119)

def r128():
    return (rng.getrandbits(64), rng.getrandbits(64))  # (lo, hi) == fpRegisters pair

def eor3(rd, rn, rm, ra): return 0xCE000000 | (rm << 16) | (ra << 10) | (rn << 5) | rd
def bcax(rd, rn, rm, ra): return 0xCE200000 | (rm << 16) | (ra << 10) | (rn << 5) | rd
def xar(rd, rn, rm, imm): return 0xCE800000 | (rm << 16) | (imm << 10) | (rn << 5) | rd
def rax1(rd, rn, rm):     return 0xCE608C00 | (rm << 16) | (rn << 5) | rd

ZERO = (0, 0)
ONES = (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)

cases = []  # (name, word, rd, rn, rm, ra, vd, vn, vm, va)  ra=-1 when unused
def add(name, word, rd, rn, rm, ra, vd=None, vn=None, vm=None, va=None):
    cases.append((name, word, rd, rn, rm, ra,
                  vd if vd is not None else r128(),
                  vn if vn is not None else r128(),
                  vm if vm is not None else r128(),
                  va if va is not None else r128()))

# EOR3: 6 random + zero + ones, regs v0/v1/v2/v3
for i in range(6):
    add(f"eor3_{i}", eor3(0, 1, 2, 3), 0, 1, 2, 3)
add("eor3_zero", eor3(0, 1, 2, 3), 0, 1, 2, 3, vn=ZERO, vm=ZERO, va=ZERO)
add("eor3_ones", eor3(0, 1, 2, 3), 0, 1, 2, 3, vn=ONES, vm=ONES, va=ONES)
# The exact guest faulting word: EOR3 v25.16b, v16.16b, v3.16b, v20.16b
add("eor3_guest", 0xCE035219, 25, 16, 3, 20)

# BCAX: 6 random (fully asymmetric -> operand-order sensitive) + zero + ones
for i in range(6):
    add(f"bcax_{i}", bcax(0, 1, 2, 3), 0, 1, 2, 3)
add("bcax_zero", bcax(0, 1, 2, 3), 0, 1, 2, 3, vn=ZERO, vm=ZERO, va=ZERO)
add("bcax_ones", bcax(0, 1, 2, 3), 0, 1, 2, 3, vn=ONES, vm=ONES, va=ONES)

# XAR: rotate amounts 0/1/2/31/32/63 + two random amounts
for imm in (0, 1, 2, 31, 32, 63):
    add(f"xar_{imm}", xar(0, 1, 2, imm), 0, 1, 2, -1)
for i in range(2):
    imm = rng.randrange(64)
    add(f"xar_r{i}_{imm}", xar(0, 1, 2, imm), 0, 1, 2, -1)

# RAX1: 6 random + zero + ones
for i in range(6):
    add(f"rax1_{i}", rax1(0, 1, 2), 0, 1, 2, -1)
add("rax1_zero", rax1(0, 1, 2), 0, 1, 2, -1, vn=ZERO, vm=ZERO)
add("rax1_ones", rax1(0, 1, 2), 0, 1, 2, -1, vn=ONES, vm=ONES)

# ---- oracle.s ----
# Layout: inputs: per case 64 bytes [vd, vn, vm, va] (lo,hi each).
# outputs: slot 0..2 = ID regs (ISAR0, ISAR1, PFR0 as u64 in 16B slots),
#          then one 16B slot per case (result in V<rd>).
inp = []
for c in cases:
    for v in (c[6], c[7], c[8], c[9]):
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
    name, word, rd, rn, rm, ra = c[0], c[1], c[2], c[3], c[4], c[5]
    base = i * 64
    lines.append(f"    ldr q{rd}, [x9, #{base}]")
    lines.append(f"    ldr q{rn}, [x9, #{base + 16}]")
    lines.append(f"    ldr q{rm}, [x9, #{base + 32}]")
    if ra >= 0:
        lines.append(f"    ldr q{ra}, [x9, #{base + 48}]")
    lines.append(f"    .word 0x{word:08x}  // {name}")
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

.section .rodata
hexdigits: .ascii "0123456789abcdef"
inputs:""")
for v in inp:
    lines.append(f"    .quad 0x{v:016x}")
lines.append("""
.bss
outputs: .skip %d
hexbuf: .skip %d
""" % (total, hexlen + 16))

with open("oracle.s", "w") as f:
    f.write("\n".join(lines) + "\n")

# ---- cases.swift (expected filled in later by merge_expected.py) ----
with open("cases_list.txt", "w") as f:
    for c in cases:
        f.write(c[0] + "\n")

with open("cases.swift", "w") as f:
    f.write("// generated by gen_cases.py — expected values merged from oracle_out.txt\n")
    f.write("let cases: [Case] = [\n")
    for c in cases:
        name, word, rd, rn, rm, ra, vd, vn, vm, va = c
        f.write('    Case(name: "%s", word: 0x%08X, rd: %d, rn: %d, rm: %d, ra: %d, '
                'vd: (0x%016X, 0x%016X), vn: (0x%016X, 0x%016X), '
                'vm: (0x%016X, 0x%016X), va: (0x%016X, 0x%016X), '
                'e: (0, 0)),\n'
                % (name, word, rd, rn, rm, ra, vd[0], vd[1], vn[0], vn[1],
                   vm[0], vm[1], va[0], va[1]))
    f.write("]\n")

print(f"{len(cases)} cases generated")
