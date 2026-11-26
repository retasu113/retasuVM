import Foundation

// Mac プラットフォーム ハーネス: ELF64 カーネルを Mac ブート方式（ADT + X0）で実行する。
// 使い方: h_mac <kernel.elf> [maxSteps]
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: h_mac <kernel.elf> [maxSteps]")
    exit(2)
}
let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
let maxSteps = args.count >= 3 ? (Int(args[2]) ?? 400) : 400
let cpu = ARM64CPU(memorySize: 128 * 1024 * 1024)
cpu.attachNVMeDisk([UInt8](repeating: 0, count: 32 * 1024 * 1024))
cpu.onChar = { byte in
    FileHandle.standardOutput.write(Data([byte]))
}
do {
    try MacPlatform.bootELF(cpu: cpu, elf: data)
} catch {
    print("LOAD ERROR: \(error)")
    exit(1)
}
var steps = 0
while !cpu.halted && steps < maxSteps {
    do {
        try cpu.run(maxInstructions: 1_000_000)
    } catch {
        print("\nFAULT: \(error)")
        exit(1)
    }
    steps += 1
    if cpu.waitingForInput {
        print("\nWAITING INPUT (unexpected)")
        break
    }
    if cpu.idle {
        Thread.sleep(forTimeInterval: 0.05)
    }
}
print("\nHALTED(\(cpu.exitCode)) steps=\(steps) halted=\(cpu.halted)")
