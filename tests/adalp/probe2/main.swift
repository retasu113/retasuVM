import Foundation
// Black-box fingerprint: run ONE word via cpu.run and dump the full
// vector register file before/after to identify what actually executed.
let words: [UInt32] = [0x0E202820, 0x0E20B820, 0x6EA06A80]
for w in words {
    let cpu = ARM64CPU()
    cpu.platform = .vmApple
    var prog: [UInt8] = []
    for x in [w, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((x >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    for r in 0..<4 {
        cpu.fpRegisters[r * 2] = 0x1011121314151617 &+ UInt64(r) &* 0x2020202020202020
        cpu.fpRegisters[r * 2 + 1] = 0x9091929394959697 &+ UInt64(r) &* 0x0505050505050505
    }
    cpu.fpRegisters[20 * 2] = 0xA0A1A2A3A4A5A6A7; cpu.fpRegisters[20 * 2 + 1] = 0xB0B1B2B3B4B5B6B7
    let before = cpu.fpRegisters
    var outcome = "returned"
    do { try cpu.run(maxInstructions: 1) } catch { outcome = "THREW \(error)" }
    print(String(format: "word 0x%08X -> %@", w, outcome))
    for r in 0..<32 {
        let lo = cpu.fpRegisters[r * 2], hi = cpu.fpRegisters[r * 2 + 1]
        if lo != before[r * 2] || hi != before[r * 2 + 1] {
            print(String(format: "  v%d: %016X,%016X -> %016X,%016X", r, before[r * 2], before[r * 2 + 1], lo, hi))
        }
    }
    print(String(format: "  pc=%llX el=%d", cpu.pc, cpu.currentEL))
}
