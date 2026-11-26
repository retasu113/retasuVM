// Shared case record for the fixed-point FCVT differential.
// kind 0 = FCVTZS/FCVTZU (FP source in Vn -> GPR dest Xd)
// kind 1 = SCVTF/UCVTF  (GPR source Xn -> FP dest in Vd)
// src: kind 0 -> FP bit pattern placed in fpRegisters[rn*2]
//      kind 1 -> raw value placed in registers[rn]
// e:   kind 0 -> expected registers[rd] after the instruction
//      kind 1 -> expected fpRegisters[rd*2] after the instruction
struct Case {
    let name: String; let word: UInt32
    let kind: Int
    let rn: Int; let rd: Int
    let src: UInt64
    let e: UInt64
}
