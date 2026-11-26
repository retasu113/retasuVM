import Foundation

// 単一命令のマイクロテスト: CSEL x8, x8, x9, cc (0x9A893108)
let cpu = ARM64CPU()
cpu.platform = .gic
var bytes: [UInt8] = []
for w: UInt32 in [0x9A893108, 0xD503201F, 0xD4000001] {  // csel; nop; svc #0 (halt via console exit? use brk instead)
    bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)]
}
cpu.loadProgram(bytes, at: ARM64CPU.ramBase)
// CMP x8, x9 相当のフラグを直接は設定できないので、命令列で用意する代わりに
// NZCV を公開 API 経由では触れないため、ここでは CSEL が例外なく実行されることだけを見る。
cpu.registers[8] = 5
cpu.registers[9] = 9
do {
    _ = try cpu.run(maxInstructions: 1)
    print("after CSEL: x8=\(cpu.registers[8]) pc=0x\(String(cpu.pc, radix: 16)) elrEL1=0x\(String(cpu.elrEL1, radix: 16)) esrEL1=0x\(String(cpu.esrEL1, radix: 16))")
    print("exceptions:", cpu.exceptionCounts)
} catch {
    print("threw:", error)
}
