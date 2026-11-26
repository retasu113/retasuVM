import Foundation

// MacBootTestOS ハーネス: アプリ内ゲストを ARM64Session.bootMac と同じ手順で実行する。
let cpu = ARM64CPU(memorySize: 256 * 1024 * 1024)
cpu.onChar = { byte in
    FileHandle.standardOutput.write(Data([byte]))
}
var assembler = ARM64Assembler()
let program: ARM64Assembler.Program
do {
    program = try assembler.assemble(MacBootTestOS.source)
} catch {
    print("ASSEMBLE ERROR: \(error)")
    exit(1)
}
cpu.loadProgram(program.bytes, at: program.entry)
MacPlatform.installDeviceTree(cpu: cpu)
cpu.setBootArgument(MacPlatform.adtAddress)
cpu.attachNVMeDisk([UInt8](repeating: 0, count: 32 * 1024 * 1024))
var steps = 0
while !cpu.halted && steps < 400 {
    do {
        try cpu.run(maxInstructions: 1_000_000)
    } catch {
        print("\nFAULT: \(error)")
        exit(1)
    }
    steps += 1
    if cpu.idle {
        Thread.sleep(forTimeInterval: 0.05)
    }
}
print("\nHALTED(\(cpu.exitCode)) steps=\(steps) halted=\(cpu.halted)")
