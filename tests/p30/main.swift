import Foundation

// Phase 30 differential harness (retasuVM engine side).
// usage: h_p30 <guest.bin>
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: h_p30 <guest.bin>"); exit(2) }
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
func hx(_ v: UInt64) -> String {
    let s = String(v, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 16 - s.count)) + s
}

var done = false
var fault: String? = nil
for _ in 0..<200 {
    do { try cpu.run(maxInstructions: 100_000) } catch {
        fault = "\(error)"
        break
    }
    if rd32(0x8000) == 0x5033_3021 { done = true; break }
    if cpu.halted { break }
}
print("DONE=\(done) fault=\(fault ?? "none") instr=\(cpu.instructionsExecuted) pc=0x\(String(cpu.pc, radix: 16))")
for i in 0..<8 {
    print("T\(i + 1)=\(hx(rd64(0x9000 + i * 8)))")
}
print("faultCount=\(rd64(0x8058))")
let logLen = Int(rd64(0x8008))
if logLen > 0 && logLen < 4096 {
    let bytes = Array(cpu.memory[0x8100..<(0x8100 + logLen)])
    print("--- guest log ---")
    print(String(bytes: bytes, encoding: .ascii) ?? "<non-ascii>")
    print("--- end log ---")
}
