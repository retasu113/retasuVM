import Foundation

let path = CommandLine.arguments[1]
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: path)))
let cpu = X86CPU()
var output = ""
cpu.onChar = { byte in output += String(UnicodeScalar(byte)) }
X86ACPI.install(cpu: cpu)
try! Multiboot.boot(cpu: cpu, imageData: data)
if cpu.attachedDisk == nil {
    cpu.attachDisk(X86DiskImage(data: [UInt8](repeating: 0, count: 16 << 20)))
}
for i in 0..<4000 {
    do {
        try cpu.run(maxInstructions: 50_000)
    } catch {
        print(output)
        print("FAULT at iter \(i): \((error as? X86Fault)?.description ?? error.localizedDescription)")
        print("RIP=\(String(cpu.instructionPointer, radix: 16)) CPL=\(cpu.currentPrivilegeLevel) halted=\(cpu.halted)")
        exit(0)
    }
    if cpu.halted { print(output); print("HALTED"); break }
    if cpu.waitingForInterrupt {
        _ = try? cpu.pollInterrupts()
        Thread.sleep(forTimeInterval: 0.002)
    }
}
