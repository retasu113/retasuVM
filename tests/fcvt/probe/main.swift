import Foundation

// Probe runner: reads probe_words.txt (name, word, expect) and classifies
// our engine's behaviour per word. For INVALID words (QEMU rejects them)
// and QEMU_ONLY words (H source; engine does not support H by design) the
// required behaviour is a clean MISS (sync exception, EC 0x00). Anything
// else - an execution, correct or not - is a failure of this probe.
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "probe_words.txt"
let text = try! String(contentsOfFile: path, encoding: .utf8)
let cpu = ARM64CPU()
cpu.platform = .vmApple
var ok = 0, bad = 0
for line in text.split(separator: "\n") {
    let parts = line.split(separator: " ")
    guard parts.count == 3 else { continue }
    let name = String(parts[0])
    let w = UInt32(String(parts[1]).dropFirst(2), radix: 16)!
    cpu.registers[2] = 0xFFFF_FFFF_FFFF_FFFF
    cpu.registers[1] = 0x1234_5678_9ABC_DEF0
    cpu.fpRegisters[1 * 2] = 0x3FC0_0000   // s1 = 1.5
    cpu.fpRegisters[1 * 2 + 1] = 0
    cpu.fpRegisters[2 * 2] = 0
    cpu.fpRegisters[2 * 2 + 1] = 0
    cpu.esrEL1 = 0
    var prog: [UInt8] = []
    for x in [w, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((x >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    do { try cpu.run(maxInstructions: 1) } catch { print("THROW \(name)"); bad += 1; continue }
    let missedIt = cpu.pc == 0x200 && ((cpu.esrEL1 >> 26) & 0x3F) == 0
    if missedIt { ok += 1 } else {
        bad += 1
        print("PROBE-FAIL \(name) word=0x\(String(w, radix: 16)) executed (pc=0x\(String(cpu.pc, radix: 16)))")
    }
}
print("probe: \(ok) clean-miss, \(bad) bad")
