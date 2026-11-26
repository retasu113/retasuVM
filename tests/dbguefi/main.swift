import Foundation

// UEFI 起動を直接 CPU で追跡するデバッグハーネス（RIP サンプリング付き）
let path = CommandLine.arguments[1]
let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
let cpu = X86CPU()
var outCount = 0
cpu.onChar = { byte in outCount += 1; print(String(format: "%c", byte), terminator: "") }
X86ACPI.install(cpu: cpu)
do {
    try X86UEFI.boot(cpu: cpu, imageData: data)
} catch {
    print("BOOT ERROR: \(error.localizedDescription)")
    exit(1)
}
var histogram: [UInt64: Int] = [:]
var steps = 0
while steps < 300_000 {
    histogram[cpu.instructionPointer, default: 0] += 1
    do {
        try cpu.run(maxInstructions: 100)
    } catch {
        print("\nFAULT at step \(steps): \(error)")
        exit(2)
    }
    steps += 100
    if cpu.halted { print("\nHALTED(\(cpu.exitCode)) after ~\(steps) steps, output \(outCount) chars"); break }
    if cpu.waitingForInterrupt { print("\nWAITING after ~\(steps) steps"); break }
    if cpu.waitingForInput { print("\nWAITING INPUT after ~\(steps) steps"); break }
}
if !cpu.halted {
    print("\nTop RIPs:")
    for (rip, count) in histogram.sorted(by: { $0.value > $1.value }).prefix(10) {
        print("  \(String(format: "%#x", rip)): \(count)")
    }
    print("regs: RAX=\(String(format: "%#x", cpu.register64(0))) RCX=\(String(format: "%#x", cpu.register64(1))) RDX=\(String(format: "%#x", cpu.register64(2))) RSP=\(String(format: "%#x", cpu.register64(4)))")
}
