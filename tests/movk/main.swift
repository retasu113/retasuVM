import Foundation
let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
var prog: [UInt8] = []
for w: UInt32 in [0x5290000B, 0x72A0004B] {  // movz w11,#0x8000 ; movk w11,#2,lsl#16
    for i in 0..<4 { prog.append(UInt8((w >> UInt32(i * 8)) & 0xFF)) }
}
cpu.loadProgram(prog, at: ARM64CPU.ramBase)
try cpu.run(maxInstructions: 2)
print("x11 = 0x\(String(cpu.registers[11], radix: 16)) (expect 0x28000)")
