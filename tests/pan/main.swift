import Foundation

// Phase 18 differential harness (retasuVM engine side).
// usage: h_pan <guest.bin> <el1|vhe>
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: h_pan <guest.bin> <el1|vhe>"); exit(2) }
let bin = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let mode = args[2]

let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
cpu.loadProgram(bin, at: 0x4000_0000)
if mode == "vhe" {
    cpu.platform = .vmApple
    cpu.pstate = 0x3C9   // EL2h, DAIF masked, SPSel=1
}

func rd32(_ off: Int) -> UInt32 {
    UInt32(cpu.memory[off]) | UInt32(cpu.memory[off + 1]) << 8 |
    UInt32(cpu.memory[off + 2]) << 16 | UInt32(cpu.memory[off + 3]) << 24
}
func rd64(_ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(cpu.memory[off + i]) << (8 * i) }
    return v
}

var done = false
var fault: String? = nil
for _ in 0..<200 {
    do { try cpu.run(maxInstructions: 100_000) } catch {
        fault = "\(error)"
        break
    }
    if rd32(0x8000) == 0x5041_4E21 { done = true; break }
    if cpu.halted { break }
}
print("DONE=\(done) fault=\(fault ?? "none") instr=\(cpu.instructionsExecuted) pc=0x\(String(cpu.pc, radix: 16)) pstate=0x\(String(cpu.pstate, radix: 16))")
let logLen = Int(rd64(0x8008))
if logLen > 0 && logLen < 4096 {
    let bytes = Array(cpu.memory[0x8100..<(0x8100 + logLen)])
    print("--- guest log ---")
    print(String(bytes: bytes, encoding: .ascii) ?? "<non-ascii>")
    print("--- end log ---")
} else {
    print("logLen=\(logLen)")
    for (name, off) in [("T1", 0x9000), ("T5", 0x9010), ("T3", 0x9020), ("T2", 0x9030), ("T4", 0x9040), ("T7", 0x9050)] {
        print("\(name) raw: pan=\(cpu.memory[off]) uao=\(cpu.memory[off + 1]) spsrpan=\(cpu.memory[off + 2]) spsruao=\(cpu.memory[off + 3])")
    }
}
print("exceptionCounts=\(cpu.exceptionCounts) lastESR=0x\(String(cpu.lastExceptionESR, radix: 16)) lastVector=0x\(String(cpu.lastExceptionVector, radix: 16))")
