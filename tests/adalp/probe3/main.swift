import Foundation
// Exact replica of main-harness case saddlp_s0q0_r0, with full dump.
let cpu = ARM64CPU()
cpu.platform = .vmApple
var prog: [UInt8] = []
for w in [0x0E202820 as UInt32, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((w >> (8 * i)) & 0xFF)) } }
cpu.loadProgram(prog, at: ARM64CPU.ramBase)
cpu.fpRegisters[0] = 0x7B21EF2ECB49A2B1; cpu.fpRegisters[1] = 0x84383462B4840CC4
cpu.fpRegisters[2] = 0xC51149D0B6EA8A5C; cpu.fpRegisters[3] = 0x377C36C09C37D74B
do { try cpu.run(maxInstructions: 1) } catch { print("THREW \(error)") }
print(String(format: "v0=%016X,%016X v1=%016X,%016X pc=%llX", cpu.fpRegisters[0], cpu.fpRegisters[1], cpu.fpRegisters[2], cpu.fpRegisters[3], cpu.pc))
