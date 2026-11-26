import Foundation

// FP/SIMD（NEON）実装の検証ハーネス。
// blocks.swift の命令列を 1 ブロックずつ実行し、レジスタ状態を検証する。

var failures = 0
var passes = 0

func check(_ cond: Bool, _ label: String, _ detail: String = "") {
    if cond {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(label) \(detail)")
    }
}

func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

func vLo(_ cpu: ARM64CPU, _ i: Int) -> UInt64 { cpu.fpRegisters[i * 2] }
func vHi(_ cpu: ARM64CPU, _ i: Int) -> UInt64 { cpu.fpRegisters[i * 2 + 1] }
func setV(_ cpu: ARM64CPU, _ i: Int, _ lo: UInt64, _ hi: UInt64) {
    cpu.fpRegisters[i * 2] = lo
    cpu.fpRegisters[i * 2 + 1] = hi
}
func lanes32(_ cpu: ARM64CPU, _ i: Int) -> [UInt32] {
    let lo = vLo(cpu, i), hi = vHi(cpu, i)
    return [UInt32(truncatingIfNeeded: lo), UInt32(truncatingIfNeeded: lo >> 32),
            UInt32(truncatingIfNeeded: hi), UInt32(truncatingIfNeeded: hi >> 32)]
}
func setLanes32(_ cpu: ARM64CPU, _ i: Int, _ l: [UInt32]) {
    setV(cpu, i,
         UInt64(l[0]) | UInt64(l[1]) << 32,
         UInt64(l[2]) | UInt64(l[3]) << 32)
}
func lanes16(_ cpu: ARM64CPU, _ i: Int) -> [UInt16] {
    var r: [UInt16] = []
    for w in [vLo(cpu, i), vHi(cpu, i)] {
        for k in 0..<4 { r.append(UInt16(truncatingIfNeeded: w >> (16 * k))) }
    }
    return r
}
func setLanes16(_ cpu: ARM64CPU, _ i: Int, _ l: [UInt16]) {
    var lo: UInt64 = 0, hi: UInt64 = 0
    for k in 0..<4 {
        lo |= UInt64(l[k]) << (16 * k)
        hi |= UInt64(l[k + 4]) << (16 * k)
    }
    setV(cpu, i, lo, hi)
}
func vBytes(_ cpu: ARM64CPU, _ i: Int) -> [UInt8] {
    var r: [UInt8] = []
    for w in [vLo(cpu, i), vHi(cpu, i)] {
        for k in 0..<8 { r.append(UInt8(truncatingIfNeeded: w >> (8 * k))) }
    }
    return r
}
func setVBytes(_ cpu: ARM64CPU, _ i: Int, _ b: [UInt8]) {
    var lo: UInt64 = 0, hi: UInt64 = 0
    for k in 0..<8 {
        lo |= UInt64(b[k]) << (8 * k)
        hi |= UInt64(b[k + 8]) << (8 * k)
    }
    setV(cpu, i, lo, hi)
}
func f32(_ v: Double) -> UInt32 { Float(v).bitPattern }
func f64(_ v: Double) -> UInt64 { v.bitPattern }

func runBlock(_ name: String, _ setup: (ARM64CPU) -> Void = { _ in }) -> ARM64CPU {
    let cpu = ARM64CPU()
    cpu.platform = .gic
    var bytes: [UInt8] = []
    for w in blocks[name]! {
        bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)]
    }
    cpu.loadProgram(bytes, at: ARM64CPU.ramBase)
    setup(cpu)
    do {
        try cpu.run(maxInstructions: blocks[name]!.count)
    } catch {
        check(false, name, "run threw: \(error)")
    }
    if !cpu.exceptionCounts.isEmpty {
        check(false, name, "exceptions: \(cpu.exceptionCounts)")
    }
    return cpu
}

// t1: MOVI 2D #0
do {
    let cpu = runBlock("t1") { setV($0, 0, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF) }
    check(vLo(cpu, 0) == 0 && vHi(cpu, 0) == 0, "t1 movi 2d #0")
}
// t2: MOVI 16B
do {
    let cpu = runBlock("t2")
    check(vLo(cpu, 1) == 0xABAB_ABAB_ABAB_ABAB && vHi(cpu, 1) == 0xABAB_ABAB_ABAB_ABAB, "t2 movi 16b")
}
// t3: MOVI 4S lsl8
do {
    let cpu = runBlock("t3")
    check(lanes32(cpu, 2) == [0x1200, 0x1200, 0x1200, 0x1200], "t3 movi lsl8", "\(lanes32(cpu, 2))")
}
// t4: MOVI 4S msl8
do {
    let cpu = runBlock("t4")
    check(lanes32(cpu, 3) == [0x12FF, 0x12FF, 0x12FF, 0x12FF], "t4 movi msl8", "\(lanes32(cpu, 3))")
}
// t5: MVNI
do {
    let cpu = runBlock("t5")
    check(lanes32(cpu, 4) == [0xFFFF_FFDF, 0xFFFF_FFDF, 0xFFFF_FFDF, 0xFFFF_FFDF], "t5 mvni", "\(lanes32(cpu, 4))")
}
// t6: ORR（レジスタ）
do {
    let cpu = runBlock("t6") {
        setV($0, 6, 0xF0F0_F0F0_F0F0_F0F0, 0xFF00_FF00_FF00_FF00)
        setV($0, 7, 0x0FF0_0FF0_0FF0_0FF0, 0xF0F0_F0F0_F0F0_F0F0)
    }
    check(vLo(cpu, 5) == 0xFFF0_FFF0_FFF0_FFF0 && vHi(cpu, 5) == 0xFFF0_FFF0_FFF0_FFF0, "t6 orr")
}
// t7: AND / BIC / EOR / ORN / MVN
do {
    let aLo: UInt64 = 0xFF00_FF00_FF00_FF00, aHi: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
    let bLo: UInt64 = 0x0FF0_0FF0_0FF0_0FF0, bHi: UInt64 = 0x3333_3333_3333_3333
    let cpu = runBlock("t7") {
        setV($0, 1, aLo, aHi)
        setV($0, 2, bLo, bHi)
    }
    check(vLo(cpu, 0) == aLo & bLo && vHi(cpu, 0) == aHi & bHi, "t7 and")
    check(vLo(cpu, 3) == aLo & ~bLo && vHi(cpu, 3) == aHi & ~bHi, "t7 bic")
    check(vLo(cpu, 4) == aLo ^ bLo && vHi(cpu, 4) == aHi ^ bHi, "t7 eor")
    check(vLo(cpu, 5) == aLo | ~bLo && vHi(cpu, 5) == aHi | ~bHi, "t7 orn")
    check(vLo(cpu, 6) == ~bLo && vHi(cpu, 6) == ~bHi, "t7 mvn")
}
// t8: ADD 4S
do {
    let cpu = runBlock("t8") {
        setLanes32($0, 1, [1, 0x7FFF_FFFF, 0xFFFF_FFFF, 100])
        setLanes32($0, 2, [2, 1, 1, 200])
    }
    check(lanes32(cpu, 0) == [3, 0x8000_0000, 0, 300], "t8 add", "\(lanes32(cpu, 0))")
}
// t9: SUB 2D / MUL 8H / MLA / MLS
do {
    let cpu = runBlock("t9") {
        setV($0, 1, 10, 5)
        setV($0, 2, 3, 9)
        setLanes16($0, 4, [2, 3, 4, 5, 6, 7, 8, 9])
        setLanes16($0, 5, [10, 10, 10, 10, 10, 10, 10, 10])
        setLanes32($0, 6, [1, 1, 1, 1])
        setLanes32($0, 7, [2, 2, 2, 2])
        setLanes32($0, 8, [3, 3, 3, 3])
        setLanes32($0, 9, [100, 100, 100, 100])
    }
    check(vLo(cpu, 0) == 7 && vHi(cpu, 0) == 0xFFFF_FFFF_FFFF_FFFC, "t9 sub 2d")
    check(lanes16(cpu, 3) == [20, 30, 40, 50, 60, 70, 80, 90], "t9 mul 8h", "\(lanes16(cpu, 3))")
    check(lanes32(cpu, 6) == [7, 7, 7, 7], "t9 mla")
    check(lanes32(cpu, 9) == [94, 94, 94, 94], "t9 mls")
}
// t10: CMEQ / CMHI
do {
    let cpu = runBlock("t10") {
        setLanes32($0, 2, [5, 0xFFFF_FFFF, 5, 0])
        setLanes32($0, 3, [5, 1, 6, 0])
    }
    check(lanes32(cpu, 0) == [0xFFFF_FFFF, 0, 0, 0xFFFF_FFFF], "t10 cmeq", "\(lanes32(cpu, 0))")
    check(lanes32(cpu, 1) == [0, 0xFFFF_FFFF, 0, 0], "t10 cmhi", "\(lanes32(cpu, 1))")
}
// t11: CMGT / CMGE / CMHS
do {
    let cpu = runBlock("t11") {
        setLanes32($0, 2, [7, 0, 9, 3])
        setLanes32($0, 3, [5, 1, 6, 3])
    }
    let m: UInt32 = 0xFFFF_FFFF
    check(lanes32(cpu, 0) == [m, 0, m, 0], "t11 cmgt", "\(lanes32(cpu, 0))")
    check(lanes32(cpu, 1) == [m, 0, m, m], "t11 cmge", "\(lanes32(cpu, 1))")
    check(lanes32(cpu, 4) == [m, 0, m, m], "t11 cmhs", "\(lanes32(cpu, 4))")
}
// t12: DUP 要素
do {
    let cpu = runBlock("t12") { setLanes32($0, 1, [10, 20, 30, 40]) }
    check(lanes32(cpu, 0) == [30, 30, 30, 30], "t12 dup", "\(lanes32(cpu, 0))")
}
// t13: INS / UMOV / SMOV
do {
    let cpu = runBlock("t13") {
        $0.registers[5] = 0xDEAD_BEEF
        setV($0, 2, 0x0000_0000_8001_0000, 0)
    }
    check(lanes32(cpu, 0)[1] == 0xDEAD_BEEF, "t13 ins gp", "\(lanes32(cpu, 0))")
    check(lanes32(cpu, 1)[2] == 0xDEAD_BEEF, "t13 ins elem", "\(lanes32(cpu, 1))")
    check(cpu.registers[6] == 0xDEAD_BEEF, "t13 umov", hex(cpu.registers[6]))
    check(cpu.registers[7] == 0xFFFF_FFFF_FFFF_8001, "t13 smov", hex(cpu.registers[7]))
}
// t14: EXT
do {
    let cpu = runBlock("t14") {
        setV($0, 1, 0x0807_0605_0403_0201, 0x100F_0E0D_0C0B_0A09)
        setV($0, 2, 0x1817_1615_1413_1211, 0x201F_1E1D_1C1B_1A19)
    }
    check(vBytes(cpu, 0) == [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20], "t14 ext", "\(vBytes(cpu, 0))")
}
// t15: ZIP / UZP / TRN
do {
    let cpu = runBlock("t15") {
        setLanes32($0, 1, [1, 2, 3, 4])
        setLanes32($0, 2, [5, 6, 7, 8])
    }
    check(lanes32(cpu, 0) == [1, 5, 2, 6], "t15 zip1", "\(lanes32(cpu, 0))")
    check(lanes32(cpu, 3) == [1, 3, 5, 7], "t15 uzp1", "\(lanes32(cpu, 3))")
    check(lanes32(cpu, 4) == [1, 5, 3, 7], "t15 trn1", "\(lanes32(cpu, 4))")
    check(lanes32(cpu, 5) == [3, 7, 4, 8], "t15 zip2", "\(lanes32(cpu, 5))")
    check(lanes32(cpu, 6) == [2, 4, 6, 8], "t15 uzp2", "\(lanes32(cpu, 6))")
    check(lanes32(cpu, 7) == [2, 6, 4, 8], "t15 trn2", "\(lanes32(cpu, 7))")
}
// t16: REV64 / REV32 / REV16
do {
    let cpu = runBlock("t16") {
        setV($0, 1, 0x0807_0605_0403_0201, 0x100F_0E0D_0C0B_0A09)
    }
    check(vBytes(cpu, 0) == [4, 3, 2, 1, 8, 7, 6, 5, 12, 11, 10, 9, 16, 15, 14, 13], "t16 rev64", "\(vBytes(cpu, 0))")
    check(vBytes(cpu, 2) == [2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15], "t16 rev32", "\(vBytes(cpu, 2))")
    check(vBytes(cpu, 3) == [2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15], "t16 rev16", "\(vBytes(cpu, 3))")
}
// t17: SHL / SSHR / USHR
do {
    let cpu = runBlock("t17") {
        setLanes32($0, 1, [1, 2, 0x1000_0000, 0xFFFF_FFFF])
        setV($0, 4, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF)
    }
    check(lanes32(cpu, 0) == [8, 16, 0x8000_0000, 0xFFFF_FFF8], "t17 shl", "\(lanes32(cpu, 0))")
    check(lanes32(cpu, 2) == [0, 0, 0x0080_0000, 0xFFFF_FFFF], "t17 sshr", "\(lanes32(cpu, 2))")
    check(vLo(cpu, 3) == 1 && vHi(cpu, 3) == 1, "t17 ushr")
}
// t18: SLI / SRI / SSRA / USRA
do {
    let cpu = runBlock("t18") {
        setLanes32($0, 1, [0x1234_5678, 0x0000_0001, 0x8000_0000, 0x7FFF_FFFF])
        setV($0, 4, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF)
        setLanes32($0, 5, [0xFF, 0xFF, 0xFF, 0xFF])
        setLanes32($0, 6, [0xAB00_0000, 0x1200_0000, 0, 0xFF00_0000])
        setLanes32($0, 7, [16, 16, 16, 16])
        setV($0, 8, 0x1000, 0x1000)
    }
    check(lanes32(cpu, 5) == [0x3456_78FF, 0x0000_01FF, 0x0000_00FF, 0xFFFF_FFFF], "t18 sli", "\(lanes32(cpu, 5))")
    check(lanes32(cpu, 6) == [0xAB12_3456, 0x1200_0000, 0x0080_0000, 0xFF7F_FFFF], "t18 sri", "\(lanes32(cpu, 6))")
    check(lanes32(cpu, 7) == [0x0123_4577, 16, 0xF800_0010, 0x0800_000F], "t18 ssra", "\(lanes32(cpu, 7))")
    check(vLo(cpu, 8) == 0x1008 && vHi(cpu, 8) == 0x100F, "t18 usra", "\(hex(vLo(cpu, 8))) \(hex(vHi(cpu, 8)))")
}
// t19: SHRN / SQSHRN / UQSHRN
do {
    let cpu = runBlock("t19") {
        setLanes32($0, 1, [0x1000, 0x2000, 0x3000, 0x4000])
        setLanes32($0, 3, [0x0001_0000, 0x7FFF_FFFF, 0xFFFF_FFF0, 100])
        setLanes32($0, 5, [0xFFFF_FFF8, 0x0001_0000, 0x7FFF_FFFF, 255])
    }
    check(Array(lanes16(cpu, 0)[0..<4]) == [0x200, 0x400, 0x600, 0x800] && vHi(cpu, 0) == 0, "t19 shrn", "\(lanes16(cpu, 0))")
    check(Array(lanes16(cpu, 2)[0..<4]) == [0x2000, 0x7FFF, 0xFFFE, 12], "t19 sqshrn", "\(lanes16(cpu, 2))")
    check(Array(lanes16(cpu, 4)[0..<4]) == [0, 0x4000, 0xFFFF, 63], "t19 uqshrn", "\(lanes16(cpu, 4))")
}
// t20: XTN / SQXTN / UQXTN
do {
    let cpu = runBlock("t20") {
        setLanes32($0, 1, [0x1234_5678, 0x9ABC_DEF0, 0, 0xFFFF_FFFF])
        setLanes32($0, 3, [0x0001_0000, 0xFFFF_0000, 100, 0xFFFF_FF9C])
        setLanes32($0, 5, [0xFFFF_FFFB, 70000, 100, 0])
    }
    check(Array(lanes16(cpu, 0)[0..<4]) == [0x5678, 0xDEF0, 0, 0xFFFF], "t20 xtn", "\(lanes16(cpu, 0))")
    check(Array(lanes16(cpu, 2)[0..<4]) == [0x7FFF, 0x8000, 100, 0xFF9C], "t20 sqxtn", "\(lanes16(cpu, 2))")
    check(Array(lanes16(cpu, 4)[0..<4]) == [0, 0xFFFF, 100, 0], "t20 uqxtn", "\(lanes16(cpu, 4))")
}

// t21: FMOV 即値
do {
    let cpu = runBlock("t21")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 0)) == 0x3F80_0000, "t21 fmov s #1.0", hex(vLo(cpu, 0)))
    check(vLo(cpu, 1) == 0xC000_0000_0000_0000, "t21 fmov d #-2.0", hex(vLo(cpu, 1)))
    check(UInt32(truncatingIfNeeded: vLo(cpu, 2)) == 0x3F00_0000, "t21 fmov s #0.5")
    check(vLo(cpu, 3) == 0x4008_0000_0000_0000, "t21 fmov d #3.0")
}
// t22: スカラ FP 演算（単精度）
do {
    let cpu = runBlock("t22") {
        $0.registers[0] = UInt64(f32(1.5))
        $0.registers[1] = UInt64(f32(2.25))
    }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 2)) == f32(3.75), "t22 fadd s", hex(vLo(cpu, 2)))
    check(UInt32(truncatingIfNeeded: vLo(cpu, 3)) == f32(3.375), "t22 fmul s")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 4)) == f32(-0.75), "t22 fsub s")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 5)) == f32(1.5 / 2.25), "t22 fdiv s", hex(vLo(cpu, 5)))
}
// t23: スカラ FP 演算（倍精度）
do {
    let cpu = runBlock("t23") {
        $0.registers[0] = f64(1.5)
        $0.registers[1] = f64(2.0)
    }
    check(vLo(cpu, 2) == f64(3.5), "t23 fadd d")
    check(vLo(cpu, 3) == f64(3.0), "t23 fmul d")
}
// t24–t26: FCMP フラグ
do {
    let cpu = runBlock("t24") {
        $0.registers[0] = UInt64(f32(1.0))
        $0.registers[1] = UInt64(f32(2.0))
    }
    let nzcv = (cpu.pstate >> 28) & 0xF
    check(nzcv == 0b1000, "t24 fcmp lt", String(nzcv, radix: 2))
}
do {
    let cpu = runBlock("t25") {
        $0.registers[0] = UInt64(f32(1.0))
        $0.registers[1] = UInt64(f32(2.0))
    }
    let nzcv = (cpu.pstate >> 28) & 0xF
    check(nzcv == 0b0010, "t25 fcmp gt", String(nzcv, radix: 2))
}
do {
    let cpu = runBlock("t26") {
        $0.registers[0] = UInt64(f32(1.0))
    }
    let nzcv = (cpu.pstate >> 28) & 0xF
    check(nzcv == 0b0110, "t26 fcmp eq", String(nzcv, radix: 2))
}
// t27: 変換
do {
    let cpu = runBlock("t27") {
        $0.registers[0] = 0xFFFF_FFFF_FFFF_FFFD   // -3
        $0.registers[1] = 10
        $0.registers[5] = UInt64(f32(2.5))
    }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 0)) == f32(-3.0), "t27 scvtf", hex(vLo(cpu, 0)))
    check(vLo(cpu, 1) == f64(10.0), "t27 ucvtf")
    check(cpu.registers[2] == 0xFFFF_FFFD, "t27 fcvtzs", hex(cpu.registers[2]))
    check(vLo(cpu, 3) == f64(-3.0), "t27 fcvt d,s")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 4)) == f32(-3.0), "t27 fcvt s,d")
    check(cpu.registers[6] == 2, "t27 fcvtns", "\(cpu.registers[6])")
    check(cpu.registers[7] == 3, "t27 fcvtas", "\(cpu.registers[7])")
    check(cpu.registers[8] == 2, "t27 fcvtms", "\(cpu.registers[8])")
    check(cpu.registers[9] == 3, "t27 fcvtps", "\(cpu.registers[9])")
    check(cpu.registers[10] == 2, "t27 fcvtzu", "\(cpu.registers[10])")
}
// t28: FRINT
do {
    let cpu = runBlock("t28") {
        $0.registers[1] = UInt64(f32(2.5))
        $0.registers[4] = UInt64(f32(-2.5))
    }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 0)) == f32(2.0), "t28 frintn")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 2)) == f32(2.0), "t28 frintz")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 3)) == f32(3.0), "t28 frintp")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 5)) == f32(-3.0), "t28 frintm")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 6)) == f32(-3.0), "t28 frinta")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 7)) == f32(-2.0), "t28 frinti")
}
// t29: FMADD 系
do {
    let cpu = runBlock("t29") {
        $0.registers[1] = UInt64(f32(2.0))
        $0.registers[2] = UInt64(f32(3.0))
        $0.registers[3] = UInt64(f32(4.0))
    }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 0)) == f32(10.0), "t29 fmadd", hex(vLo(cpu, 0)))
    check(UInt32(truncatingIfNeeded: vLo(cpu, 4)) == f32(-2.0), "t29 fmsub")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 5)) == f32(-10.0), "t29 fnmadd")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 6)) == f32(2.0), "t29 fnmsub")
}
// t30: FCSEL
do {
    let cpu = runBlock("t30") {
        $0.registers[0] = 5
        $0.registers[1] = UInt64(f32(1.0))
        $0.registers[2] = UInt64(f32(2.0))
        $0.registers[3] = 5
        $0.registers[4] = 9
    }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 0)) == f32(1.0), "t30 fcsel eq")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 3)) == f32(2.0), "t30 fcsel ne")
}
// t31: FP ロード / ストア
do {
    let base = ARM64CPU.ramBase + 0x2000
    let cpu = runBlock("t31") {
        $0.registers[0] = base
        $0.registers[10] = 48
        setV($0, 1, 0x1122_3344_5566_7788, 0x99AA_BBCC_DDEE_FF00)
        setV($0, 3, f64(1.5), 0)
        setV($0, 4, f64(-2.5), 0)
        setV($0, 7, 0xCAFE_BABE, 0)
        setV($0, 9, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF)
    }
    check(vLo(cpu, 2) == 0x1122_3344_5566_7788 && vHi(cpu, 2) == 0x99AA_BBCC_DDEE_FF00, "t31 ldr q")
    check(vLo(cpu, 5) == f64(1.5), "t31 ldp d (1)")
    check(vLo(cpu, 6) == f64(-2.5), "t31 ldp d (2)")
    check(UInt32(truncatingIfNeeded: vLo(cpu, 8)) == 0xCAFE_BABE, "t31 ldr s", hex(vLo(cpu, 8)))
    check(vLo(cpu, 9) == 0 && vHi(cpu, 9) == 0, "t31 ldr q reg-offset")
    let memBytes = Array(cpu.memory[0x2000..<0x2010])
    check(memBytes == vBytes(cpu, 1), "t31 str q memory", "\(memBytes)")
}
// t32: ベクタ FP
do {
    let cpu = runBlock("t32") {
        setLanes32($0, 1, [f32(1.5), f32(-2.0), f32(3.25), f32(0.5)])
        setLanes32($0, 2, [f32(2.25), f32(2.0), f32(0.75), f32(0.5)])
        setV($0, 4, f64(1.5), f64(-2.0))
        setV($0, 5, f64(4.0), f64(0.5))
        setLanes32($0, 8, [f32(-1.5), f32(2.0), f32(-0.25), f32(-3.0)])
        setV($0, 10, f64(1.5), f64(-2.0))
        setLanes32($0, 12, [f32(1.0), f32(1.0), f32(1.0), f32(1.0)])
    }
    check(lanes32(cpu, 0) == [f32(3.75), f32(0.0), f32(4.0), f32(1.0)], "t32 fadd v", "\(lanes32(cpu, 0))")
    check(vLo(cpu, 3) == f64(6.0) && vHi(cpu, 3) == f64(-1.0), "t32 fmul v")
    check(lanes32(cpu, 6) == [0, 0, 0, 0xFFFF_FFFF], "t32 fcmeq v", "\(lanes32(cpu, 6))")
    check(lanes32(cpu, 7) == [f32(1.5), f32(2.0), f32(0.25), f32(3.0)], "t32 fabs v")
    check(vLo(cpu, 9) == f64(-1.5) && vHi(cpu, 9) == f64(2.0), "t32 fneg v")
    check(lanes32(cpu, 11) == [0, 0, 0xFFFF_FFFF, 0], "t32 fcmgt v", "\(lanes32(cpu, 11))")
    check(lanes32(cpu, 12) == [f32(4.375), f32(-3.0), f32(3.4375), f32(1.25)], "t32 fmla v", "\(lanes32(cpu, 12))")
    check(lanes32(cpu, 13) == [f32(2.25), f32(2.0), f32(3.25), f32(0.5)], "t32 fmax v")
    check(lanes32(cpu, 14) == [f32(1.5), f32(-2.0), f32(0.75), f32(0.5)], "t32 fmin v")
}
// t33: ベクタ整数 misc
do {
    let cpu = runBlock("t33") {
        setVBytes($0, 1, [0xFF, 0x0F, 0x00, 0x01, 0x80, 0x7F, 0x55, 0xAA, 0, 0, 0, 0, 0, 0, 0, 0])
        setLanes32($0, 3, [0x0001_0000, 0x0000_0001, 0x8000_0000, 0])
        setLanes32($0, 5, [0xFFFF_0000, 0x0000_FFFF, 0x8000_0000, 0xFFFF_FFFF])
        setLanes32($0, 7, [0xFFFF_FFFB, 5, 0x8000_0000, 0])
    }
    check(Array(vBytes(cpu, 0)[0..<8]) == [8, 4, 0, 1, 1, 7, 4, 4], "t33 cnt", "\(vBytes(cpu, 0))")
    check(lanes32(cpu, 2) == [15, 31, 0, 32], "t33 clz", "\(lanes32(cpu, 2))")
    check(lanes32(cpu, 4) == [15, 15, 0, 31], "t33 cls", "\(lanes32(cpu, 4))")
    check(lanes32(cpu, 6) == [5, 5, 0x8000_0000, 0], "t33 abs", "\(lanes32(cpu, 6))")
    check(lanes32(cpu, 8) == [5, 0xFFFF_FFFB, 0x8000_0000, 0], "t33 neg", "\(lanes32(cpu, 8))")
}
// t34: ADDP / SQADD / UQSUB / SQSUB
do {
    let cpu = runBlock("t34") {
        setLanes32($0, 1, [1, 2, 3, 4])
        setLanes32($0, 2, [5, 6, 7, 8])
        setLanes16($0, 4, [30000, UInt16(bitPattern: -30000), 100, UInt16(bitPattern: -100), 0, 32767, UInt16(bitPattern: -32768), 5])
        setLanes16($0, 5, [10000, UInt16(bitPattern: -10000), 200, UInt16(bitPattern: -200), 0, 1, UInt16(bitPattern: -1), UInt16(bitPattern: -10)])
        setVBytes($0, 7, [5, 0, 255, 10, 100, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        setVBytes($0, 8, [9, 0, 1, 10, 200, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }
    check(lanes32(cpu, 0) == [3, 7, 11, 15], "t34 addp", "\(lanes32(cpu, 0))")
    check(lanes16(cpu, 3) == [32767, UInt16(bitPattern: -32768), 300, UInt16(bitPattern: -300), 0, 32767, UInt16(bitPattern: -32768), UInt16(bitPattern: -5)], "t34 sqadd", "\(lanes16(cpu, 3))")
    check(Array(vBytes(cpu, 6)[0..<6]) == [0, 0, 254, 0, 0, 0], "t34 uqsub", "\(vBytes(cpu, 6))")
    check(lanes16(cpu, 9) == [20000, UInt16(bitPattern: -20000), UInt16(bitPattern: -100), 100, 0, 32766, UInt16(bitPattern: -32767), 15], "t34 sqsub", "\(lanes16(cpu, 9))")
}
// t35: スカラ整数（D レジスタ）
do {
    let cpu = runBlock("t35") {
        setV($0, 1, 100, 0)
        setV($0, 2, 23, 0)
        setV($0, 4, 100, 23)
    }
    check(vLo(cpu, 0) == 123, "t35 add d", hex(vLo(cpu, 0)))
    check(vLo(cpu, 3) == 123, "t35 addp d", hex(vLo(cpu, 3)))
    check(vLo(cpu, 5) == 77, "t35 sub d")
}
// t36: MOVI 追加形式
do {
    let cpu = runBlock("t36")
    check(vLo(cpu, 0) == 0x3400_3400_3400_3400 && vHi(cpu, 0) == 0x3400_3400_3400_3400, "t36 movi 8h lsl8")
    check(vLo(cpu, 1) == 0xFF && vHi(cpu, 1) == 0xFF, "t36 movi 2d #0xff", "\(hex(vLo(cpu, 1))) \(hex(vHi(cpu, 1)))")
    check(vLo(cpu, 2) == 0x7F7F_7F7F_7F7F_7F7F && vHi(cpu, 2) == 0, "t36 movi 8b")
}
// t37: INS（バイト）/ UMOV（D 要素）
do {
    let cpu = runBlock("t37") {
        setV($0, 0, 0x0102_0304_0506_0708, 0x1112_1314_1516_1718)
        $0.registers[5] = 0xAA
    }
    check(vLo(cpu, 0) == 0x0102_0304_AA06_0708, "t37 ins b", hex(vLo(cpu, 0)))
    check(cpu.registers[6] == 0x1112_1314_1516_1718, "t37 umov d")
}
// リテラルロード（Swift で手組み）
do {
    let cpu = ARM64CPU()
    cpu.platform = .gic
    // ldr s9, [pc, #0x100] = 0x1C000809 / ldr q10, [pc, #0x100] = 0x9C00080A
    var bytes: [UInt8] = []
    for w: UInt32 in [0x1C00_0809, 0x9C00_080A] {
        bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)]
    }
    cpu.loadProgram(bytes, at: ARM64CPU.ramBase)
    let val = f32(1.5)
    for k in 0..<4 { cpu.memory[0x100 + k] = UInt8((val >> (8 * k)) & 0xFF) }
    for k in 0..<16 { cpu.memory[0x104 + k] = UInt8(0xA0 + k) }
    do { try cpu.run(maxInstructions: 2) } catch { check(false, "literal", "\(error)") }
    check(UInt32(truncatingIfNeeded: vLo(cpu, 9)) == f32(1.5), "literal ldr s", hex(vLo(cpu, 9)))
    // q10 は pc=ramBase+4 から +0x100 = ramBase+0x104 を読む
    check(vBytes(cpu, 10) == (0..<16).map { UInt8(0xA0 + $0) }, "literal ldr q", "\(vBytes(cpu, 10))")
}

print("SIMD TESTS: \(passes) passed, \(failures) failed")
