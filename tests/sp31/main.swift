import Foundation
let cpu = ARM64CPU(memorySize: 16 * 1024 * 1024)
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
_ = try! cpu.loadELF64(data)
do { try cpu.run(maxInstructions: 500) } catch { print("run ended: \(error)") }
print("x0 = \(cpu.registers[0]) (42 = all SP31 semantics correct)")
