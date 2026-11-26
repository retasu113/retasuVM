// Shared case record for the ADALP differential + neighbour audit.
struct Case {
    let name: String; let word: UInt32
    let rd: Int; let rn: Int
    let vd: (UInt64, UInt64); let vn: (UInt64, UInt64)
    let e: (UInt64, UInt64)
}
