import Foundation
func trial(_ label: String, _ setup: (ARM64CPU) -> Void) {
    let cpu = ARM64CPU()
    cpu.platform = .vmApple
    var prog: [UInt8] = []
    for w in [0x0E202820 as UInt32, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((w >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    setup(cpu)
    let before = cpu.fpRegisters
    do { try cpu.run(maxInstructions: 1) } catch { print("\(label) THREW") }
    var diffs: [String] = []
    for r in 0..<32 {
        if cpu.fpRegisters[r * 2] != before[r * 2] || cpu.fpRegisters[r * 2 + 1] != before[r * 2 + 1] {
            diffs.append(String(format: "v%d:%016X,%016X->%016X,%016X", r, before[r * 2], before[r * 2 + 1], cpu.fpRegisters[r * 2], cpu.fpRegisters[r * 2 + 1]))
        }
    }
    print("\(label): pc=\(String(cpu.pc, radix: 16)) diffs=\(diffs.isEmpty ? "none" : diffs.joined(separator: " "))")
}
// A: probe3 values, only v0/v1 set
trial("A case-values v0v1") { cpu in
    cpu.fpRegisters[0] = 0x7B21EF2ECB49A2B1; cpu.fpRegisters[1] = 0x84383462B4840CC4
    cpu.fpRegisters[2] = 0xC51149D0B6EA8A5C; cpu.fpRegisters[3] = 0x377C36C09C37D74B
}
// B: probe2 patterns, only v0/v1 set
trial("B probe2-patterns v0v1") { cpu in
    cpu.fpRegisters[0] = 0x1011121314151617; cpu.fpRegisters[1] = 0x9091929394959697
    cpu.fpRegisters[2] = 0x3031323334353637; cpu.fpRegisters[3] = 0x95969798999A9B9C
}
// C: probe2 patterns, v0-v3 + v20 set (exact probe2 setup)
trial("C probe2-patterns all") { cpu in
    for r in 0..<4 {
        cpu.fpRegisters[r * 2] = 0x1011121314151617 &+ UInt64(r) &* 0x2020202020202020
        cpu.fpRegisters[r * 2 + 1] = 0x9091929394959697 &+ UInt64(r) &* 0x0505050505050505
    }
    cpu.fpRegisters[40] = 0xA0A1A2A3A4A5A6A7; cpu.fpRegisters[41] = 0xB0B1B2B3B4B5B6B7
}
// D: case values, v0-v3 + v20 set
trial("D case-values all") { cpu in
    cpu.fpRegisters[0] = 0x7B21EF2ECB49A2B1; cpu.fpRegisters[1] = 0x84383462B4840CC4
    cpu.fpRegisters[2] = 0xC51149D0B6EA8A5C; cpu.fpRegisters[3] = 0x377C36C09C37D74B
    cpu.fpRegisters[4] = 0x1111111122222222; cpu.fpRegisters[5] = 0x3333333344444444
    cpu.fpRegisters[6] = 0x5555555566666666; cpu.fpRegisters[7] = 0x7777777788888888
    cpu.fpRegisters[40] = 0xA0A1A2A3A4A5A6A7; cpu.fpRegisters[41] = 0xB0B1B2B3B4B5B6B7
}
