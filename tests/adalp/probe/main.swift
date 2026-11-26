import Foundation
// Misroute probe: for each ADDLP/ADALP variant word, call the SIMD
// sub-handlers in executeSIMDVector's dispatch order on fresh CPUs and
// report the first one that claims the word (returns true).
func word(_ q: Int, _ u: Int, _ size: Int, _ opc: Int, _ rn: Int, _ rd: Int) -> UInt32 {
    0x0E200000 | UInt32(q << 30) | UInt32(u << 29) | UInt32(size << 22)
        | UInt32(opc << 11) | UInt32(rn << 5) | UInt32(rd)
}

func freshCPU() -> ARM64CPU {
    let cpu = ARM64CPU()
    cpu.platform = .vmApple
    cpu.fpRegisters[0] = 0x1111111111111111; cpu.fpRegisters[1] = 0x2222222222222222
    cpu.fpRegisters[2] = 0x3333333333333333; cpu.fpRegisters[3] = 0x4444444444444444
    cpu.fpRegisters[4] = 0x5555555555555555; cpu.fpRegisters[5] = 0x6666666666666666
    return cpu
}

let ops: [(String, Int, Int)] = [("saddlp", 0, 5), ("uaddlp", 1, 5), ("sadalp", 0, 13), ("uadalp", 1, 13)]
for (name, u, opc) in ops {
    for size in 0...2 {
        for q in 0...1 {
            let w = word(q, u, size, opc, 1, 0)
            var claimant = "NONE"
            if freshCPU().executeCrypto(w, rd: 0, rn: 1, rm: 2) { claimant = "executeCrypto" }
            else if (try? freshCPU().executeStructLoadStore(w, rd: 0, rn: 1, rm: 2)) == true { claimant = "executeStructLoadStore" }
            else if (w & 0xBFE0_8000) == 0x0E00_0000 && (w & 0x0000_0C00) == 0 { claimant = "TBL-inline-gate" }
            else if w & 0x0100_0000 != 0 { claimant = "bit24-group" }
            else if freshCPU().executeSIMDCopy(w, rd: 0, rn: 1, rm: 2) { claimant = "executeSIMDCopy" }
            else if freshCPU().executeSIMDPermute(w, rd: 0, rn: 1, rm: 2) { claimant = "executeSIMDPermute" }
            else if freshCPU().executeSIMDThreeDifferent(w, rd: 0, rn: 1, rm: 2) { claimant = "executeSIMDThreeDifferent" }
            else if freshCPU().executeSIMDTwoRegMisc(w, rd: 0, rn: 1) { claimant = "executeSIMDTwoRegMisc" }
            else if (try? freshCPU().executeSIMDThreeSame(w, rd: 0, rn: 1, rm: 2, scalar: false)) == true { claimant = "executeSIMDThreeSame" }
            print(String(format: "%@ size=%d q=%d word=0x%08X -> %@", name, size, q, w, claimant))
        }
    }
}
// The exact guest word
let w: UInt32 = 0x6EA06A80
var claimant = "NONE"
if freshCPU().executeCrypto(w, rd: 0, rn: 20, rm: 2) { claimant = "executeCrypto" }
else if freshCPU().executeSIMDCopy(w, rd: 0, rn: 20, rm: 2) { claimant = "executeSIMDCopy" }
else if freshCPU().executeSIMDTwoRegMisc(w, rd: 0, rn: 20) { claimant = "executeSIMDTwoRegMisc" }
else if (try? freshCPU().executeSIMDThreeSame(w, rd: 0, rn: 20, rm: 2, scalar: false)) == true { claimant = "executeSIMDThreeSame" }
print(String(format: "guest word=0x%08X -> %@", w, claimant))
