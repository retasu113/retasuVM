#!/usr/bin/env python3
# Phase 30: apply root-cause #31 fix to a lineage ARM64CPU.swift (copy of src_p29).
# Logical-immediate (AND/ORR/EOR) destination Rd=31 must write SP, not XZR.
# Reference: QEMU gen_rri_log (tcg_rd = set_cc ? cpu_reg : cpu_reg_sp).
# ANDS (opc/f1 == 3) keeps XZR semantics. Two sites: executeDataImmediate
# (plain path) and executeDecoded .logicImm (decode-cache path).
# Each anchor must occur exactly once; abort otherwise.
import sys

path = sys.argv[1]
src = open(path).read()

# Site A: decode-cache path (.logicImm)
old_a = """            }
            writeReg(d.rd, result, width64: sf)
        case .movWide:"""
new_a = """            }
            // Rd=31 is SP for AND/ORR/EOR (XZR for ANDS). QEMU gen_rri_log (root cause #31)
            let writeValue = sf ? result : (result & 0xFFFF_FFFF)
            writeReg(d.rd, writeValue, sp: d.f1 != 3, width64: sf)
        case .movWide:"""
assert src.count(old_a) == 1, f"site A anchor count = {src.count(old_a)}"
src = src.replace(old_a, new_a)

# Site B: plain path (executeDataImmediate) — anchor on the whole logical block
old_b = """            let a = readReg(rn)
            let result: UInt64
            switch opc {
            case 0: result = a & imm
            case 1: result = a | imm
            case 2: result = a ^ imm
            default:
                result = a & imm
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            writeReg(rd, result, width64: sf)
            return true"""
new_b = """            let a = readReg(rn)
            let result: UInt64
            switch opc {
            case 0: result = a & imm
            case 1: result = a | imm
            case 2: result = a ^ imm
            default:
                result = a & imm
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            // Rd=31 is SP for AND/ORR/EOR (XZR for ANDS). QEMU gen_rri_log (root cause #31)
            let writeValue = sf ? result : (result & 0xFFFF_FFFF)
            writeReg(rd, writeValue, sp: opc != 3, width64: sf)
            return true"""
assert src.count(old_b) == 1, f"site B anchor count = {src.count(old_b)}"
src = src.replace(old_b, new_b)

open(path, "w").write(src)
print("p30 fix applied: 2 sites patched in", path)
