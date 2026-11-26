import Foundation

// Arm64DemoOS ハーネス: スクリプト入力を与えて出力を検証する。
// 使い方: h_arm64demo "help\nfact 5\necho hello\nquit\n"
let cpu = ARM64CPU()
var assembler = ARM64Assembler()
let program = try assembler.assemble(ARM64DemoOS.source)
cpu.loadProgram(program.bytes, at: program.entry)
var output = ""
cpu.onChar = { byte in output += String(UnicodeScalar(byte)) }
let script = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help\nquit\n"
var lines = script.components(separatedBy: "\\n").filter { !$0.isEmpty }
var steps = 0
while !cpu.halted && steps < 400 {
    try cpu.run(maxInstructions: 200_000)
    if cpu.halted { break }
    if cpu.waitingForInput {
        if lines.isEmpty { break }
        cpu.enqueueInput(lines.removeFirst() + "\n")
    } else if cpu.idle {
        Thread.sleep(forTimeInterval: 0.02)
    }
    steps += 1
}
print(output)
print("HALTED(\(cpu.exitCode))")
