import Foundation

func hex64(_ v: UInt64) -> String {
    let hi = String(format: "%08X", UInt32(truncatingIfNeeded: v >> 32))
    let lo = String(format: "%08X", UInt32(truncatingIfNeeded: v))
    return hi + lo
}
// Scalar fixed-point FCVT differential harness.
// Expected values come from qemu-aarch64 running oracle.s (gen_cases.py),
// cross-checked against an exact Python model by merge_expected.py.
// Cases are parsed from cases.txt at runtime (a compiled array literal
// of ~3900 cases OOMs swiftc).
// kind 0 = FCVTZS/FCVTZU (FP source in Vn -> GPR dest Xd)
// kind 1 = SCVTF/UCVTF  (GPR source Xn -> FP dest in Vd)
// One CPU is reused; per case we reset the touched registers, ESR and PC
// (loadProgram resets pc). A case is classified:
//   PASS     - executed, result == expected
//   MISS     - sync exception with EC 0x00 (pc == VBAR+0x200), the
//              "Undefined kernel instruction" signature
//   MISROUTE - executed but result != expected
//   THROW    - Swift error from run()

struct Case {
    let name: String; let word: UInt32
    let kind: Int
    let rn: Int; let rd: Int
    let src: UInt64
    let e: UInt64
}

let casesPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cases.txt"
let text = try! String(contentsOfFile: casesPath, encoding: .utf8)
var cases: [Case] = []
for line in text.split(separator: "\n") {
    let p = line.split(separator: " ")
    guard p.count == 7 else { continue }
    func hx(_ s: Substring) -> UInt64 { UInt64(String(s).dropFirst(2), radix: 16)! }
    cases.append(Case(name: String(p[0]), word: UInt32(hx(p[1])), kind: Int(p[2])!,
                      rn: Int(p[3])!, rd: Int(p[4])!, src: hx(p[5]), e: hx(p[6])))
}
print("loaded \(cases.count) cases")

let cpu = ARM64CPU()
cpu.platform = .vmApple

var passed = 0, missed = 0, misrouted = 0, threw = 0
var missNames: [String] = []
var misrouteNames: [String] = []
for cs in cases {
    cpu.registers[cs.rd] = 0xFFFF_FFFF_FFFF_FFFF          // sentinel (FCVTZ dest)
    cpu.registers[cs.rn] = cs.src                          // CVTF source
    cpu.fpRegisters[cs.rn * 2] = cs.src                    // FCVTZ source
    cpu.fpRegisters[cs.rn * 2 + 1] = 0
    cpu.fpRegisters[cs.rd * 2] = 0                         // CVTF dest zeroed
    cpu.fpRegisters[cs.rd * 2 + 1] = 0
    cpu.esrEL1 = 0
    var prog: [UInt8] = []
    for w in [cs.word, 0xD4200000 as UInt32] { for i in 0..<4 { prog.append(UInt8((w >> (8 * i)) & 0xFF)) } }
    cpu.loadProgram(prog, at: ARM64CPU.ramBase)
    do { try cpu.run(maxInstructions: 1) } catch { print("THROW \(cs.name)"); threw += 1; continue }
    if cpu.pc == 0x200 && ((cpu.esrEL1 >> 26) & 0x3F) == 0 {
        missed += 1
        if missNames.count < 12 { missNames.append(cs.name) }
        continue
    }
    let got = cs.kind == 0 ? cpu.registers[cs.rd] : cpu.fpRegisters[cs.rd * 2]
    let hiOK = cs.kind == 0 || cpu.fpRegisters[cs.rd * 2 + 1] == 0
    if got == cs.e && hiOK {
        passed += 1
    } else {
        misrouted += 1
        if misrouteNames.count < 24 {
            misrouteNames.append("\(cs.name) got=\(hex64(got)) want=\(hex64(cs.e))")
        }
    }
}
print("fcvt: \(passed) passed, \(missed) missed, \(misrouted) misrouted, \(threw) threw, \(cases.count) total")
for n in missNames { print("MISS \(n)") }
for n in misrouteNames { print("MISROUTE \(n)") }
