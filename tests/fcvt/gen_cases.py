#!/usr/bin/env python3
# Generate the scalar fixed-point FCVT differential: oracle.s (qemu-aarch64)
# + cases.swift (our engine harness). One shared case list.
#
# Word construction follows QEMU a64.decode lines 1342-1355:
#   &fcvt rd rn esz sf shift
#   %fcvt_shift32 10:5 !function=rsub_32   (bits 14:10, bit15 literal 1)
#   %fcvt_shift64 10:6 !function=rsub_64   (bits 15:10)
#   @fcvt32  0 ....... .. ...... 1..... rn rd   sf=0, scale6 in 32..63
#   @fcvt64  1 ....... .. ...... ...... rn rd   sf=1, scale6 in 0..63
#   SCVTF_g  . 0011110 .. 000010 ...... rn rd
#   UCVTF_g  . 0011110 .. 000011 ...... rn rd
#   FCVTZS_g . 0011110 .. 011000 ...... rn rd
#   FCVTZU_g . 0011110 .. 011001 ...... rn rd
# fbits (fraction bits) = 64 - scale6.
#
# Semantics (QEMU target/arm/tcg/vfp_helper.c, VFP_CONV_FIX_A64):
#   FP->int : NaN -> 0 (wrapper raises invalid); else
#             float_to_int_scalbn(x, ROUND, fbits) with the fpstatus
#             rounding mode forced to FPROUNDING_ZERO by do_fcvt_scalar
#             (translate-a64.c) -> truncate(x * 2^fbits), saturating to
#             the destination width (softfloat float*_to_int*_scalbn).
#             sf=0 destination is zero-extended (do_fcvt_g ext32u).
#   int->FP : int_to_float_scalbn(x, -fbits), round-to-nearest-even,
#             single rounding. sf=0 source is the low 32 bits,
#             sign-extended (SCVTF) or zero-extended (UCVTF) (do_cvtf_g).
#
# The Python model below derives expected values with exact Fraction
# arithmetic (independent of the Swift port); merge_expected.py
# cross-checks model == qemu-aarch64 oracle for every case before the
# engine is judged.
import struct
from fractions import Fraction

INF = float("inf")

def word(sf, typ, opc6, scale6, rn, rd):
    return ((sf << 31) | (0x1E << 24) | (typ << 22) | (opc6 << 16)
            | (scale6 << 10) | (rn << 5) | rd)

def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]

def f64(bits):
    return struct.unpack("<d", struct.pack("<Q", bits))[0]

def model_fcvtz(w, src):
    sf = (w >> 31) & 1
    typ = (w >> 22) & 3
    opc = (w >> 16) & 0x3F
    fbits = 64 - ((w >> 10) & 0x3F)
    unsigned = (opc == 0b011001)
    bits = 64 if sf else 32
    v = f32(src) if typ == 0 else f64(src)
    if v != v:                      # NaN -> 0 (QEMU wrapper)
        return 0
    if v == INF:
        t = None                    # saturate high
    elif v == -INF:
        t = None
    else:
        t = int(Fraction(v) * (1 << fbits))   # int() truncates toward zero
    if unsigned:
        hi, lo = (1 << bits) - 1, 0
    else:
        hi, lo = (1 << (bits - 1)) - 1, -(1 << (bits - 1))
    if t is None:
        t = hi if v > 0 else lo
    t = min(max(t, lo), hi)
    return t & ((1 << bits) - 1)

def model_cvtf(w, src):
    sf = (w >> 31) & 1
    typ = (w >> 22) & 3
    opc = (w >> 16) & 0x3F
    fbits = 64 - ((w >> 10) & 0x3F)
    signed = (opc == 0b000010)
    b = 64 if sf else 32
    raw = src & ((1 << b) - 1)
    if signed and (raw >> (b - 1)):
        val = raw - (1 << b)
    else:
        val = raw
    exact = Fraction(val, 1 << fbits)
    if typ == 1:
        return struct.unpack("<Q", struct.pack("<d", float(exact)))[0]
    # double rounding 53 -> 24 bits is exact here (53 >= 2*24+2)
    return struct.unpack("<I", struct.pack("<f", float(exact)))[0]

# ---------------------------------------------------------------- cases
cases = []  # (name, word, kind, rn, rd, src)  kind 0=FCVTZ 1=CVTF
def add(name, w, kind, rn, rd, src):
    cases.append((name, w, kind, rn, rd, src))

SCVTF, UCVTF, FCVTZS, FCVTZU = 0b000010, 0b000011, 0b011000, 0b011001
OPN = {SCVTF: "scvtf", UCVTF: "ucvtf", FCVTZS: "fcvtzs", FCVTZU: "fcvtzu"}
TN = {0: "s", 1: "d"}

def scales_for(sf):
    return range(32, 64) if sf == 0 else range(0, 64)

# ---- FCVTZ scale sweep (3 values x every scale x sf x typ x opc) ----
SWEEP_S = [0x3FC00000, 0xC0300000, 0x47C35000]                    # 1.5, -2.75, 100000.0
SWEEP_D = [0x3FF8000000000000, 0xC006000000000000, 0x40F86A0000000000]
for opc in (FCVTZS, FCVTZU):
    for typ in (0, 1):
        vals = SWEEP_S if typ == 0 else SWEEP_D
        for sf in (0, 1):
            for sc in scales_for(sf):
                for vi, v in enumerate(vals):
                    add(f"{OPN[opc]}_{TN[typ]}_w{32 if sf==0 else 64}_sc{sc}_v{vi}",
                        word(sf, typ, opc, sc, 1, 2), 0, 1, 2, v)

# ---- FCVTZ edge values at boundary scales ----
EDGE_S = [
    0x00000000, 0x80000000, 0x3F000000, 0xBF000000, 0x3F800000, 0xBF800000,
    0x3FC00000, 0xBFC00000, 0x40200000, 0x3DCCCCCD, 0x4EFFFFFF, 0x4F000000,
    0xCF000000, 0xCF000001, 0x4F7FFFFF, 0x4F800000, 0x7F7FFFFF, 0xFF7FFFFF,
    0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001, 0x00000001, 0x007FFFFF,
    0x00800000, 0x5F800000, 0xDF800000, 0x3F7FFFFF, 0xBF7FFFFF, 0x4B000001,
]
EDGE_D = [
    0x0000000000000000, 0x8000000000000000, 0x3FE0000000000000, 0xBFE0000000000000,
    0x3FF0000000000000, 0xBFF0000000000000, 0x3FF8000000000000, 0xBFF8000000000000,
    0x4004000000000000, 0x3FB999999999999A, 0x41E0000000000000, 0xC1E0000000000000,
    0x41F0000000000000, 0xC1F0000000000000, 0x43DFFFFFFFFFFFFF, 0x43E0000000000000,
    0xC3E0000000000000, 0xC3E0000000000001, 0x43EFFFFFFFFFFFFF, 0x43F0000000000000,
    0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF, 0x7FF0000000000000, 0xFFF0000000000000,
    0x7FF8000000000000, 0x7FF0000000000001, 0x0000000000000001, 0x000FFFFFFFFFFFFF,
    0x0010000000000000, 0x3FEFFFFFFFFFFFFF,
]
EDGE_SC = {0: (32, 33, 62, 63), 1: (0, 1, 32, 63)}
for opc in (FCVTZS, FCVTZU):
    for typ in (0, 1):
        vals = EDGE_S if typ == 0 else EDGE_D
        for sf in (0, 1):
            for sc in EDGE_SC[sf]:
                for vi, v in enumerate(vals):
                    add(f"{OPN[opc]}_{TN[typ]}_w{32 if sf==0 else 64}_sc{sc}_e{vi}",
                        word(sf, typ, opc, sc, 3, 4), 0, 3, 4, v)

# ---- CVTF scale sweep ----
SWEEP_I32 = [1, 0xFFFFFFFFFFFFFFFF, 123456789, 0x7FFFFFFF]
SWEEP_I64 = [1, 0xFFFFFFFFFFFFFFFF, 1234567890123456789, 0x7FFFFFFFFFFFFFFF]
for opc in (SCVTF, UCVTF):
    for typ in (0, 1):
        for sf in (0, 1):
            vals = SWEEP_I32 if sf == 0 else SWEEP_I64
            for sc in scales_for(sf):
                for vi, v in enumerate(vals):
                    add(f"{OPN[opc]}_w{32 if sf==0 else 64}_{TN[typ]}_sc{sc}_v{vi}",
                        word(sf, typ, opc, sc, 1, 2), 1, 1, 2, v)

# ---- CVTF edge values ----
EDGE_I32 = [0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFFFFE,
            1000000, 0x40000000, 0x0000FFFF, 0x00F00000]
EDGE_I64 = [0, 1, 2, 3, (1 << 53) - 1, 1 << 53, (1 << 53) + 1, 1 << 62,
            0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
            0xFFFFFFFFFFFFFFFE, 1234567890123456789, 0x123456789ABCDEF0,
            0x00000000FFFFFFFF, 0x5555555555555555]
EDGE_SC_C = {0: (32, 63), 1: (0, 63)}
for opc in (SCVTF, UCVTF):
    for typ in (0, 1):
        for sf in (0, 1):
            vals = EDGE_I32 if sf == 0 else EDGE_I64
            for sc in EDGE_SC_C[sf]:
                for vi, v in enumerate(vals):
                    add(f"{OPN[opc]}_w{32 if sf==0 else 64}_{TN[typ]}_sc{sc}_e{vi}",
                        word(sf, typ, opc, sc, 3, 4), 1, 3, 4, v)

# ---- the exact guest word + variants ----
add("guest_fcvtzu_w10_s0_fb2", 0x1E19F80A, 0, 0, 10, 0x40200000)   # s0 = 2.5
add("guest_fcvtzu_w10_s0_fb2_b", 0x1E19F80A, 0, 0, 10, 0x47C35000) # s0 = 100000.0
add("guest_fcvtzu_w10_s0_fb2_c", 0x1E19F80A, 0, 0, 10, 0xBF000000) # s0 = -0.5
add("guest_fcvtzu_w10_s0_fb2_d", 0x1E19F80A, 0, 0, 10, 0x4F7FFFFF) # s0 = 4294967040

# ---- model expectations ----
with open("model_expected.txt", "w") as f:
    for (name, w, kind, rn, rd, src) in cases:
        e = model_fcvtz(w, src) if kind == 0 else model_cvtf(w, src)
        f.write(f"{name} 0x{e:016X}\n")

with open("cases_list.txt", "w") as f:
    for c in cases:
        f.write(c[0] + "\n")

# ---- placeholder cases.swift (expected filled by merge_expected.py) ----
with open("cases_placeholder.swift", "w") as f:
    f.write("// generated by gen_cases.py - placeholder, see merge_expected.py\n")
    f.write("let cases: [Case] = [\n")
    for (name, w, kind, rn, rd, src) in cases:
        f.write(f'    Case(name: "{name}", word: 0x{w:08X}, kind: {kind}, '
                f'rn: {rn}, rd: {rd}, src: 0x{src:016X}, e: 0),\n')
    f.write("]\n")

# ---- oracle.s ----
# Per case: 16B input slot (src qword), 16B output slot (result qword).
lines = []
lines.append(".text\n.globl _start\n_start:")
lines.append("    adrp x29, outputs\n    add x29, x29, :lo12:outputs")
lines.append("    adrp x28, inputs\n    add x28, x28, :lo12:inputs")
for i, (name, w, kind, rn, rd, src) in enumerate(cases):
    typ = (w >> 22) & 3
    if kind == 0:
        lines.append(f"    movn x{rd}, #0")                    # sentinel
        if typ == 0:
            lines.append(f"    ldr s{rn}, [x28]")
        else:
            lines.append(f"    ldr d{rn}, [x28]")
        lines.append(f"    .word 0x{w:08x}  // {name}")
        lines.append(f"    str x{rd}, [x29]")
    else:
        lines.append(f"    movi v{rd}.16b, #0")
        lines.append(f"    ldr x{rn}, [x28]")
        lines.append(f"    .word 0x{w:08x}  // {name}")
        lines.append(f"    str d{rd}, [x29]")
    lines.append("    add x28, x28, #16")
    lines.append("    add x29, x29, #16")

total = len(cases) * 16
hexlen = total * 2 + total // 16
lines.append(f"""
    adrp x11, outputs
    add x11, x11, :lo12:outputs
    adrp x12, hexbuf
    add x12, x12, :lo12:hexbuf
    mov x13, #0
    movz x18, #{total & 0xFFFF}
    movk x18, #{(total >> 16) & 0xFFFF}, lsl #16
print_loop:
    cmp x13, x18
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
    movz x2, #{hexlen & 0xFFFF}
    movk x2, #{(hexlen >> 16) & 0xFFFF}, lsl #16
    mov x8, #64
    svc #0
    mov x0, #0
    mov x8, #93
    svc #0
    .section .data
    .align 4
inputs:""")
for (name, w, kind, rn, rd, src) in cases:
    lines.append(f"    .quad 0x{src:016x}, 0  // {name}")
lines.append(f"""
    .bss
    .align 4
outputs:
    .zero {total}
hexbuf:
    .zero {hexlen + 16}
    .section .rodata
hexdigits:
    .ascii "0123456789abcdef"
""")
with open("oracle.s", "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"{len(cases)} cases generated")
