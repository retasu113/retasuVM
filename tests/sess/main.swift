import Foundation

// セッション経由でイメージを起動するハーネス（UEFI / BIOS ISO / ELF）。
// 使い方: harness_session <image> [input-after-ms:input-text]
let path = CommandLine.arguments[1]
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: path)))
let session = X86Session()
var output = ""
var done: String?
let semaphore = DispatchSemaphore(value: 0)
session.onOutput = { text in output += text }
session.onHalt = { code in done = "HALTED(\(code))"; semaphore.signal() }
session.onFault = { message in done = "FAULT: \(message)"; semaphore.signal() }
do {
    try session.boot(imageData: data)
} catch {
    print("BOOT FAULT: \(error)")
    exit(1)
}
if CommandLine.arguments.count > 2 {
    let spec = CommandLine.arguments[2]
    let parts = spec.split(separator: ":", maxSplits: 1)
    let delayMs = Int(parts[0]) ?? 500
    let text = parts.count > 1 ? String(parts[1]) : ""
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        session.sendInput(text)
    }
}
let result = semaphore.wait(timeout: .now() + 20)
if result == .timedOut {
    let cpu = session.cpu
    print("[DBG] timeout rip=\(String(cpu.instructionPointer, radix: 16)) rsp=\(String(cpu.register64(4), radix: 16)) rax=\(String(cpu.register64(0), radix: 16)) rcx=\(String(cpu.register64(1), radix: 16)) rdx=\(String(cpu.register64(2), radix: 16))")
    Thread.sleep(forTimeInterval: 0.5)
    print("[DBG] timeout2 rip=\(String(cpu.instructionPointer, radix: 16))")
}
session.terminate()
print(output)
print("== \(done ?? "TIMEOUT")")
