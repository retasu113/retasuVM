import Foundation

func hex64(_ v: UInt64) -> String {
    let hi = String(format: "%08X", UInt32(truncatingIfNeeded: v >> 32))
    let lo = String(format: "%08X", UInt32(truncatingIfNeeded: v))
    return hi + lo
}
// Neighbour-audit runner: executes every audit case on our engine and
// prints one line per case for merge_audit.py to classify:
//   name GOT lo hi   (engine executed, values follow)
//   name THROW       (engine raised undefined-instruction)
for cs in auditCases {
    let cpu = ARM64CPU()
    cpu.platform = .vmApple
    var prog: [UInt8] = []
    for w in [cs.word, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((w >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    cpu.fpRegisters[cs.rd * 2] = cs.vd.0; cpu.fpRegisters[cs.rd * 2 + 1] = cs.vd.1
    cpu.fpRegisters[cs.rn * 2] = cs.vn.0; cpu.fpRegisters[cs.rn * 2 + 1] = cs.vn.1
    do { try cpu.run(maxInstructions: 1) } catch { print("\(cs.name) THROW"); continue }
    // Undefined instructions do NOT throw in this engine: execute() falls
    // through to raiseSync (guest EC 0x00 exception, pc = VBAR + 0x200).
    // Detect that clean miss explicitly, else it masquerades as an
    // execution with got == vd.
    if cpu.pc == 0x200 && (cpu.lastExceptionESR >> 26) == 0 {
        print("\(cs.name) THROW"); continue
    }
    let got = (cpu.fpRegisters[cs.rd * 2], cpu.fpRegisters[cs.rd * 2 + 1])
    print("\(cs.name) GOT \(hex64(got.0)) \(hex64(got.1))")
}
