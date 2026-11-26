import Foundation
import Glibc

var gCpu: ARM64CPU? = nil
var probePC: UInt64 = .max
var probeDone = false
var probe2PC: UInt64 = .max
var probe2Done = false
var gRing: [UInt64] = []

// h_shaseq: load test256.elf into ARM64CPU, run run_tests, compare results vs QEMU.
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test256.elf"
let elf = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: path)))
func rd16(_ o: Int) -> Int { Int(elf[o]) | Int(elf[o+1]) << 8 }
func rd32(_ o: Int) -> UInt32 { UInt32(elf[o]) | UInt32(elf[o+1]) << 8 | UInt32(elf[o+2]) << 16 | UInt32(elf[o+3]) << 24 }
func rd64(_ o: Int) -> UInt64 { UInt64(rd32(o)) | UInt64(rd32(o+4)) << 32 }

let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
let phoff = Int(rd64(32)); let phentsize = rd16(54); let phnum = rd16(56)
var minVA: UInt64 = .max
for i in 0..<phnum {
    let p = phoff + i * phentsize
    if rd32(p) == 1 { minVA = min(minVA, rd64(p + 16)) }
}
for i in 0..<phnum {
    let p = phoff + i * phentsize
    guard rd32(p) == 1 else { continue }
    let off = Int(rd64(p + 8)); let va = rd64(p + 16); let fsz = Int(rd64(p + 32))
    let dst = Int(va - ARM64CPU.ramBase)
    for j in 0..<fsz { cpu.memory[dst + j] = elf[off + j] }
}
// symbols via section headers
let shoff = Int(rd64(40)); let shentsize = rd16(58); let shnum = rd16(60)
var symtabOff = 0, symtabSize = 0, strtabOff = 0, symEnt = 0
for i in 0..<shnum {
    let s = shoff + i * shentsize
    if rd32(s + 4) == 2 { // SHT_SYMTAB
        symtabOff = Int(rd64(s + 24)); symtabSize = Int(rd64(s + 32)); symEnt = Int(rd64(s + 56))
        let link = Int(rd32(s + 40))
        let ls = shoff + link * shentsize
        strtabOff = Int(rd64(ls + 24))
    }
}
func symbol(_ name: String) -> UInt64? {
    guard symEnt > 0 else { return nil }
    var i = symtabOff
    while i < symtabOff + symtabSize {
        let nameOff = Int(rd32(i))
        var s = ""
        var j = strtabOff + nameOff
        while elf[j] != 0 { s.append(Character(UnicodeScalar(elf[j]))); j += 1 }
        if s == name { return rd64(i + 8) }
        i += symEnt
    }
    return nil
}
guard let runTests = symbol("run_tests"), let resultsVA = symbol("results") else {
    print("symbols not found"); exit(1)
}
// sentinel BRK at 0x40300000
let sentinel: UInt64 = 0x4030_0000
let brk: UInt32 = 0xD420_0000
for j in 0..<4 { cpu.memory[Int(sentinel - ARM64CPU.ramBase) + j] = UInt8((brk >> (8 * j)) & 0xFF) }
gCpu = cpu
signal(SIGILL) { _ in
    if let c = gCpu {
        FileHandle.standardError.write(Data(String(format: "[sigtrap] pc=0x%llX instr=%lld ring=%@\n", c.pc, c.instructionsExecuted, gRing.suffix(20).map { String(format: "%llX", $0) }.joined(separator: " ")).utf8))
    }
    _exit(99)
}
cpu.onFetch = { pc, _ in
    gRing.append(pc); if gRing.count > 4096 { gRing.removeFirst(2048) }
    if pc == probePC && !probeDone {
        probeDone = true
        var lines: [String] = []
        for r in [16, 17, 18, 19, 20, 21] {
            let lo = cpu.fpRegisters[2 * r], hi = cpu.fpRegisters[2 * r + 1]
            let words = [UInt32(truncatingIfNeeded: lo), UInt32(truncatingIfNeeded: lo >> 32), UInt32(truncatingIfNeeded: hi), UInt32(truncatingIfNeeded: hi >> 32)]
            lines.append("v\(r)=" + words.map { String(format: "%08x", $0) }.joined(separator: " "))
        }
        FileHandle.standardError.write(Data(("[probe@loop] msg+state:\n" + lines.joined(separator: "\n") + "\n").utf8))
    }
    if pc == probe2PC && !probe2Done {
        probe2Done = true
        var lines: [String] = []
        for r in [16, 24, 25] {
            let lo = cpu.fpRegisters[2 * r], hi = cpu.fpRegisters[2 * r + 1]
            let words = [UInt32(truncatingIfNeeded: lo), UInt32(truncatingIfNeeded: lo >> 32), UInt32(truncatingIfNeeded: hi), UInt32(truncatingIfNeeded: hi >> 32)]
            lines.append("v\(r)=" + words.map { String(format: "%08x", $0) }.joined(separator: " "))
        }
        FileHandle.standardError.write(Data(("[probe@r4] sched+state after 4 rounds:\n" + lines.joined(separator: "\n") + "\n").utf8))
    }
}
if let tstart = symbol("sha2_ce_transform") { probePC = tstart + 0x40; probe2PC = tstart + 0x64 }
cpu.onException = { vec, esr, elr in
    FileHandle.standardError.write(Data(String(format: "[exc] vec=0x%llX esr=0x%llX elr=0x%llX far=0x%llX instr=%lld\n", vec, esr, elr, cpu.farEL1, cpu.instructionsExecuted).utf8))
}
cpu.spEL1 = 0x4020_0000
cpu.registers[30] = sentinel + 0x100
for j in 0..<4 { cpu.memory[Int(sentinel - ARM64CPU.ramBase) + 0x100 + j] = UInt8((brk >> (8 * j)) & 0xFF) }
let diff = (Int64(runTests) - Int64(sentinel)) / 4
let branch = UInt32(0x1400_0000) | UInt32(diff & 0x03FF_FFFF)
var stub: [UInt8] = []
for j in 0..<4 { stub.append(UInt8((branch >> (8 * j)) & 0xFF)) }
cpu.loadProgram(stub, at: sentinel)
do { try cpu.run(maxInstructions: 5_000_000) } catch {
    print("run error:", error)
    print("ring tail:", gRing.suffix(24).map { String(format: "%llX", $0) }.joined(separator: " "))
    print("x0=\(cpu.registers[0]) x1=\(cpu.registers[1]) x2=\(cpu.registers[2]) sp=\(String(cpu.currentSP, radix: 16))")
}
let expected: [[UInt32]] = [
    [0xb8d32aaa, 0x8c8480b9, 0xfa3fb8d5, 0xeb6fe929, 0x0c9b5eb1, 0x2cc8e844, 0xc896e7e3, 0x241f0d8f],
    [0x9204477f, 0x83bc0431, 0xb9e2c5df, 0x85e5f470, 0x7206d362, 0x0414a4bc, 0xc4a95786, 0xd2a801f6],
    [0xec64267f, 0x526fb102, 0xfdda7b4d, 0x4ca654c0, 0x7de04e0a, 0x6c47fe8f, 0xfa4550f1, 0xd33c932a],
    [0x0b453131, 0x4b3d0955, 0x1cfaef12, 0x1d96240f, 0xf37e2188, 0x8b88c159, 0x0176a39e, 0x9b05822f],
    [0x5a7a6a91, 0x1bcd9a97, 0x51e302bf, 0x18e2682a, 0x8b14eb45, 0x023a82b8, 0x8bd0f906, 0x85f478e3],
]
var pass = 0, fail = 0
for t in 0..<5 {
    var got: [UInt32] = []
    for w in 0..<8 {
        let o = Int(resultsVA - ARM64CPU.ramBase) + (t * 8 + w) * 4
        got.append(UInt32(cpu.memory[o]) | UInt32(cpu.memory[o+1]) << 8 | UInt32(cpu.memory[o+2]) << 16 | UInt32(cpu.memory[o+3]) << 24)
    }
    if got == expected[t] { pass += 1; print("case \(t+1): MATCH") }
    else {
        fail += 1
        print("case \(t+1): MISMATCH")
        print("  got     ", got.map { String(format: "%08x", $0) }.joined(separator: " "))
        print("  expected", expected[t].map { String(format: "%08x", $0) }.joined(separator: " "))
    }
}
print("h_shaseq: \(pass) passed, \(fail) failed (instr=\(cpu.instructionsExecuted) pc=0x\(String(cpu.pc, radix: 16)))")
