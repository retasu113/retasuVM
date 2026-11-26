import Foundation

// ARM64 ハーネス: ELF64 カーネルを読み込んで実行し、UART 出力を表示する。
// 使い方: h_arm64 <kernel.elf> [maxSteps]
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: h_arm64 <kernel.elf> [maxSteps]")
    exit(2)
}
let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
let maxSteps = args.count >= 3 ? (Int(args[2]) ?? 200) : 200
let cpu = ARM64CPU()
cpu.onChar = { byte in
    FileHandle.standardOutput.write(Data([byte]))
}
do {
    try cpu.loadELF64(data)
} catch {
    print("LOAD ERROR: \(error)")
    exit(1)
}
cpu.enqueueInput("")
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
        // タイマ割り込み待ちなど: 短い実時間を与えて再開する
        Thread.sleep(forTimeInterval: 0.05)
    }
}
print("\nHALTED(\(cpu.exitCode)) steps=\(steps) halted=\(cpu.halted)")
