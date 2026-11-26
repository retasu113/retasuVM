#!/usr/bin/env python3
"""Phase 20: add FMOV (vector, immediate) cmode=15 to src_p23/ARM64CPU.swift.

Root cause #29 (convicted by the phase-20 ILLTRACE trap + QEMU differential):
fsck executed FMOV v0.2d, #-1.0 (word 0x6f07f600) and our executeModifiedImmediate
had no case 15, so it returned false -> EC 0x00 -> guest SIGILL -> fsck death.

Fix (grounded in QEMU translate-a64.c trans_Vimm + translate.c asimd_imm_const,
ARM ARM AdvSIMDExpandImm; differential tests/pan/guest_fmov.S is byte-identical
to QEMU post-fix on T1-T7):
  op=0 -> 32-bit FP immediate replicated to all 32-bit lanes (.2S/.4S)
  op=1, q=1 -> 64-bit FP immediate replicated to all 64-bit lanes (.2D)
  op=1, q=0 -> unallocated (return false, as QEMU does)
  bits11:10==11 is FMOVI_v_h (half precision); FP16 is unimplemented, so it
  still returns false (no silent misdecode as 32-bit FP).
Note: the existing apply() helper interprets op as MVNI inversion, which is
wrong for cmode 15 (op selects 64-bit, not inversion), so lanes are written
directly with laneSet.
"""
import sys

path = sys.argv[1]
src = open(path).read()

assert "FMOV (vector, immediate)" not in src, "patch already applied"

anchor = """            } else {
                // バイト複製
                for i in 0..<total { out[i] = UInt8(imm8) }
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: q)"""
assert src.count(anchor) == 1, f"anchor count={src.count(anchor)}"

block = """            } else {
                // バイト複製
                for i in 0..<total { out[i] = UInt8(imm8) }
            }
        case 15:
            // FMOV (vector, immediate): cmode=15 は浮動小数点即値（fsck の SIGILL の原因となった命令）。
            //   op=0 → 32 ビット FP 即値を全 32 ビットレーンへ複製（.2S/.4S）
            //   op=1, q=1 → 64 ビット FP 即値を全 64 ビットレーンへ複製（.2D）
            //   op=1, q=0 → 未割り当て（QEMU trans_Vimm (translate-a64.c:7422) も false）
            // bits11:10==11 は FMOVI_v_h（半精度）で、FP16 未実装のため未対応のまま落とす
            //   （32 ビット FP として誤デコードしないこと）。
            // 即値展開は QEMU asimd_imm_const (translate.c:83) と同一（ARM ARM AdvSIMDExpandImm）。
            // 注意: 既存の apply() は op を MVNI の反転と解釈するため、cmode=15 では使えない
            // （op は 64 ビット選択であって反転ではない）。レーンは直接書く。
            guard (insn & 0xC00) == 0x400 else { return false }  // bits11:10 == 01
            if op {
                guard q else { return false }  // 未割り当て
                let imm64: UInt64 = (UInt64(imm8 & 0x3F) << 48)
                    | ((imm8 & 0x80) != 0 ? 0x8000_0000_0000_0000 : 0)
                    | ((imm8 & 0x40) != 0 ? 0x3FC0_0000_0000_0000 : 0x4000_0000_0000_0000)
                laneSet(&out, 0, 8, imm64)
                laneSet(&out, 1, 8, imm64)
            } else {
                let imm32: UInt32 = (UInt32(imm8 & 0x80) << 24)
                    | (UInt32(imm8 & 0x3F) << 19)
                    | ((imm8 & 0x40) != 0 ? 0x3E00_0000 : 0x4000_0000)  // 0x1F<<25 = 0x3E000000
                for i in 0..<(total / 4) { laneSet(&out, i, 4, UInt64(imm32)) }
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: q)"""

src = src.replace(anchor, block, 1)
open(path, "w").write(src)
print("p23_fmov_patch: applied OK")
