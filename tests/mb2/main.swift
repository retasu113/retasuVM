import Foundation

// Multiboot カーネルを直接 CPU で実行するハーネス。
// 使い方: harness_mb <kernel.elf>
let path = CommandLine.arguments[1]
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: path)))
let cpu = X86CPU()
var output = ""
cpu.onChar = { byte in output += String(UnicodeScalar(byte)) }
X86ACPI.install(cpu: cpu)
do {
    try Multiboot.boot(cpu: cpu, imageData: data)
} catch {
    print("BOOT FAULT: \(error)")
    exit(1)
}
if cpu.attachedDisk == nil {
    cpu.attachDisk(X86DiskImage(data: (0..<(16 << 20)).map { UInt8($0 & 0xFF) }))
}
var status = "TIMEOUT"
var idlePolls = 0
for _ in 0..<4000 {
    do {
        try cpu.run(maxInstructions: 50_000)
    } catch {
        status = "FAULT: \((error as? X86Fault)?.description ?? error.localizedDescription)"
        break
    }
    if cpu.halted { status = "HALTED(\(cpu.exitCode))"; break }
    if cpu.waitingForInterrupt {
        idlePolls += 1
        if idlePolls == 30 { cpu.provideInput([UInt8]("a".utf8)) } // キー入力を一度注入
        do { _ = try cpu.pollInterrupts() } catch {
            status = "POLL FAULT: \(error)"
            break
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
}
print(output)
print("== \(status)")
