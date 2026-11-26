import Foundation

// RISC-V / ARM 組み込みゲストのハーネス。
// 使い方: harness_guest <riscv|arm> <script>   script は \n 区切りの入力列
let kind = CommandLine.arguments[1]
let script = CommandLine.arguments.count > 2 ? CommandLine.arguments[2].replacingOccurrences(of: "\\n", with: "\n") : ""
var output = ""
var done: String?
let semaphore = DispatchSemaphore(value: 0)

if kind == "riscv" {
    let session = EmulatorSession()
    session.onOutput = { output += $0 }
    session.onHalt = { code in done = "HALTED(\(code))"; semaphore.signal() }
    session.onFault = { done = "FAULT: \($0)"; semaphore.signal() }
    try! session.boot(guestImage: .retasuOS)
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.3)
        session.sendInput(script)
    }
    _ = semaphore.wait(timeout: .now() + 15)
    session.terminate()
} else {
    let session = ARMSession()
    session.onOutput = { output += $0 }
    session.onHalt = { code in done = "HALTED(\(code))"; semaphore.signal() }
    session.onFault = { done = "FAULT: \($0)"; semaphore.signal() }
    try! session.boot(source: ARMDemoOS.source)
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.3)
        session.sendInput(script)
    }
    _ = semaphore.wait(timeout: .now() + 15)
    session.terminate()
}
print(output)
print("== \(done ?? "TIMEOUT")")
