import Foundation

// Fuzz harness: run a fuzz guest, dump the mailbox record as hex.
// usage: h_fuzz <guest.bin>
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: h_fuzz <guest.bin>"); exit(2) }
let bin = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
cpu.loadProgram(bin, at: 0x4000_0000)
func rd32(_ off: Int) -> UInt32 {
    UInt32(cpu.memory[off]) | UInt32(cpu.memory[off + 1]) << 8 |
    UInt32(cpu.memory[off + 2]) << 16 | UInt32(cpu.memory[off + 3]) << 24
}
let MB = 0x200000
var done = false
var fault = ""
for _ in 0..<50 {
    do { try cpu.run(maxInstructions: 100_000) } catch {
        fault = "\(error)"
        break
    }
    if rd32(MB) == 0x4C5A_564E { done = true; break }
    if cpu.halted { break }
}
if done {
    var out = ""
    for i in 0..<0x280 {
        out += String(format: "%02x", cpu.memory[MB + i])
    }
    print("REC \(out)")
} else {
    print("NOREC fault=\(fault) pc=0x\(String(cpu.pc, radix: 16)) instr=\(cpu.instructionsExecuted)")
}
