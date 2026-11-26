import Foundation

// Phase 19 differential harness (retasuVM engine side).
// usage: h_lzvn <guest.bin>
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: h_lzvn <guest.bin>"); exit(2) }
let bin = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))

let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
cpu.loadProgram(bin, at: 0x4000_0000)

func rd32(_ off: Int) -> UInt32 {
    UInt32(cpu.memory[off]) | UInt32(cpu.memory[off + 1]) << 8 |
    UInt32(cpu.memory[off + 2]) << 16 | UInt32(cpu.memory[off + 3]) << 24
}
func rd64(_ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(cpu.memory[off + i]) << (8 * i) }
    return v
}

// mailbox at VA 0x40200000 -> memory offset 0x200000
let MB = 0x200000
var done = false
var fault: String? = nil
for _ in 0..<400 {
    do { try cpu.run(maxInstructions: 100_000) } catch {
        fault = "\(error)"
        // the guest sets DONE, then hits the semihosting hlt which
        // vectors in this harness — check the mailbox anyway
        if rd32(MB) == 0x4C5A_564E { done = true }
        break
    }
    if rd32(MB) == 0x4C5A_564E { done = true; break }
    if cpu.halted { break }
}
print("DONE=\(done) fault=\(fault ?? "none") instr=\(cpu.instructionsExecuted) pc=0x\(String(cpu.pc, radix: 16))")
if done {
    let fnv = rd64(MB + 8)
    let mism = rd32(MB + 16)
    let nout = rd32(MB + 20)
    print("nout=\(nout) mism=\(mism) fnv=0x\(String(fnv, radix: 16))")
    if mism > 0 {
        for i in 0..<min(Int(mism), 8) {
            let off = rd32(MB + 0x20 + i * 12)
            let got = rd32(MB + 0x20 + i * 12 + 4)
            let want = rd32(MB + 0x20 + i * 12 + 8)
            print("  mism[\(i)] off=\(off) got=0x\(String(got, radix: 16)) want=0x\(String(want, radix: 16))")
        }
    }
}
print("exceptionCounts=\(cpu.exceptionCounts) lastESR=0x\(String(cpu.lastExceptionESR, radix: 16))")
