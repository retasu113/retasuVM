import Foundation
// Probe: which handler in the decode chain claims the SHA3 words?
// (internal handlers are reachable because the harness compiles as one module)
let words: [(String, UInt32)] = [
    ("eor3_guest", 0xCE035219),
    ("eor3_std", 0xCE020C20),
    ("bcax_std", 0xCE220C20),
    ("xar_imm1", 0xCE820420),
    ("rax1_std", 0xCE628C20),
]
for (name, w) in words {
    let cpu = ARM64CPU()
    cpu.platform = .vmApple
    let rd = Int(w & 0x1F), rn = Int((w >> 5) & 0x1F), rm = Int((w >> 16) & 0x1F)
    for r in 0..<32 { cpu.fpRegisters[r * 2] = 0x0123456789ABCDEF; cpu.fpRegisters[r * 2 + 1] = 0xFEDCBA9876543210 }
    let crypto = cpu.executeCrypto(w, rd: rd, rn: rn, rm: rm)
    print("\(name) word=0x\(String(w, radix: 16)) executeCrypto=\(crypto)")
    let cpu2 = ARM64CPU()
    cpu2.platform = .vmApple
    for r in 0..<32 { cpu2.fpRegisters[r * 2] = 0x0123456789ABCDEF; cpu2.fpRegisters[r * 2 + 1] = 0xFEDCBA9876543210 }
    do {
        let simd = try cpu2.executeSIMDVector(w, rd: rd, rn: rn, rm: rm)
        print("   executeSIMDVector=\(simd) v0=0x\(String(cpu2.fpRegisters[0], radix: 16)),0x\(String(cpu2.fpRegisters[1], radix: 16))")
    } catch { print("   executeSIMDVector threw \(error)") }
    let cpu3 = ARM64CPU()
    cpu3.platform = .vmApple
    for r in 0..<32 { cpu3.fpRegisters[r * 2] = 0x0123456789ABCDEF; cpu3.fpRegisters[r * 2 + 1] = 0xFEDCBA9876543210 }
    do {
        let fsimd = try cpu3.executeFPOrSIMD(w, rd: rd, rn: rn, rm: rm, at: 0)
        print("   executeFPOrSIMD=\(fsimd)")
    } catch { print("   executeFPOrSIMD threw \(error)") }
}
