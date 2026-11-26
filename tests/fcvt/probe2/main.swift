import Foundation

func hex64(_ v: UInt64) -> String {
    let hi = String(format: "%08X", UInt32(truncatingIfNeeded: v >> 32))
    let lo = String(format: "%08X", UInt32(truncatingIfNeeded: v))
    return hi + lo
}
// Direct probe: what does the engine do with FCVTZS w2, s1 at
// scale6 = 32/33/34/35 (bits 11:10 = 0/1/2/3)? s1 = 1.5.
let cpu = ARM64CPU()
cpu.platform = .vmApple
for sc in [32, 33, 34, 35] {
    let w: UInt32 = 0x1E18_0000 | (UInt32(sc) << 10) | (1 << 5) | 2
    cpu.registers[2] = 0xFFFF_FFFF_FFFF_FFFF
    cpu.fpRegisters[1 * 2] = 0x3FC0_0000
    cpu.fpRegisters[1 * 2 + 1] = 0
    cpu.fpRegisters[2 * 2] = 0xDEAD_BEEF_CAFE_F00D
    cpu.fpRegisters[2 * 2 + 1] = 0x1111_2222_3333_4444
    cpu.esrEL1 = 0
    var prog: [UInt8] = []
    for x in [w, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((x >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    do { try cpu.run(maxInstructions: 1) } catch { print("sc\(sc) THROW"); continue }
    print("sc\(sc) word=0x\(String(w, radix: 16)) pc=0x\(String(cpu.pc, radix: 16)) esrEC=\((cpu.esrEL1 >> 26) & 0x3F) x2=\(hex64(cpu.registers[2])) v2=\(hex64(cpu.fpRegisters[4])),\(hex64(cpu.fpRegisters[5]))")
}
