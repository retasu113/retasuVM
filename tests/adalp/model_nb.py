#!/usr/bin/env python3
# Independent Python model for the neighbour differential.
# Semantics from QEMU sources:
#   SUQADD/USQADD: vec_helper.c DO_SAT (gvec_suqadd = dest signed + src unsigned,
#     saturate signed; gvec_usqadd = dest unsigned + src signed, saturate [0, max])
#   XTN: truncate low bits. SQXTN: saturate signed. SQXTUN/UQXTN: saturate the
#     signed source into the unsigned range. Q selects the destination half
#     (Q=0: low half written, high zeroed; Q=1: high half written, low kept).
# Source operand for the XTN family is the full 128-bit Vn.
import sys

def lanes(v, eb):
    x = v[0] | (v[1] << 64)
    return [(x >> (8 * eb * i)) & ((1 << (8 * eb)) - 1) for i in range(16 // eb)]

def pack(lanelist, eb):
    x = 0
    for i, v in enumerate(lanelist):
        x |= (v & ((1 << (8 * eb)) - 1)) << (8 * eb * i)
    return (x & (1 << 64) - 1, (x >> 64) & (1 << 64) - 1)

def sx(v, bits):
    return v - (1 << bits) if v >> (bits - 1) else v

def sat_s(v, bits):
    return max(-(1 << (bits - 1)), min((1 << (bits - 1)) - 1, v)) & ((1 << bits) - 1)

def sat_u_from_s(v, bits):
    return max(0, min((1 << bits) - 1, v)) & ((1 << bits) - 1)

def model(name, word, vd, vn):
    q = (word >> 30) & 1
    u = (word >> 29) & 1
    size = (word >> 22) & 3
    hi = (word >> 16) & 0x1F
    opc = (word >> 11) & 0x1F
    if hi == 0 and opc == 7:  # SUQADD / USQADD
        eb = 1 << size
        total = 16 if q else 8
        dl = lanes(vd, eb)
        nl = lanes(vn, eb)
        out = [0] * (16 // eb)
        for i in range(total // eb):
            if u == 0:  # SUQADD: signed dest + unsigned src, signed sat
                out[i] = sat_s(sx(dl[i], eb * 8) + nl[i], eb * 8)
            else:       # USQADD: unsigned dest + signed src, unsigned sat
                out[i] = sat_u_from_s(dl[i] + sx(nl[i], eb * 8), eb * 8)
        return pack(out, eb)
    if hi == 1 and opc in (5, 9):  # XTN family
        sb = 1 << (size + 1)
        db = sb // 2
        count = 8 // db
        nl = lanes(vn, sb)
        res = []
        for i in range(count):
            if opc == 5 and u == 0:      # XTN
                res.append(nl[i] & ((1 << (db * 8)) - 1))
            elif opc == 9 and u == 0:    # SQXTN
                res.append(sat_s(sx(nl[i], sb * 8), db * 8))
            elif opc == 9 and u == 1:    # UQXTN: unsigned source (QEMU neon_narrow_sat_u*)
                res.append(min(nl[i], (1 << (db * 8)) - 1))
            else:                        # SQXTUN: signed source -> unsigned (neon_unarrow_sat*)
                res.append(sat_u_from_s(sx(nl[i], sb * 8), db * 8))
        if q:
            low = lanes(vd, db)[:count]
            return pack(low + res, db)
        return pack(res + [0] * count, db)
    raise ValueError(name)

if __name__ == "__main__":
    for l in open("nb_cases.txt"):
        p = l.split()
        name, word = p[0], int(p[1], 16)
        vd = (int(p[2], 16), int(p[3], 16))
        vn = (int(p[4], 16), int(p[5], 16))
        e = model(name, word, vd, vn)
        print(f"{name} {e[0]:016X} {e[1]:016X}")
