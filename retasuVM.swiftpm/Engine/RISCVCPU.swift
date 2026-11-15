import Foundation

/// CPU 実行中の異常。
enum CPUFault: Error, CustomStringConvertible {
    case invalidInstruction(UInt32, pc: UInt32)
    case memoryOutOfBounds(address: UInt32, size: Int)
    case unknownSyscall(UInt32)

    var description: String {
        switch self {
        case .invalidInstruction(let instr, let pc):
            return String(format: "未対応の命令 0x%08X（PC=0x%08X）", instr, pc)
        case .memoryOutOfBounds(let address, let size):
            return String(format: "メモリ範囲外アクセス（アドレス 0x%08X、%d バイト）", address, size)
        case .unknownSyscall(let number):
            return "未対応のシステムコール（番号 \(number)）"
        }
    }
}

/// RISC-V RV32I のソフトウェア CPU エミュレータ。
///
/// ハードウェア仮想化が使えない iOS / iPadOS 上で、ゲストコードを実際に
/// 実行するためのコア。命令フェッチ→デコード→実行を 1 命令ずつ行う。
///
/// ゲストとの入出力は ECALL システムコール経由:
/// - a7=1: a0 の 1 文字を出力
/// - a7=2: a0 を符号付き 10 進数として出力
/// - a7=3: a0 が指す NUL 終端文字列を出力
/// - a7=4: 1 文字入力（入力が無い場合は待機状態になり、同じ ECALL を再試行する）
/// - a7=5: コンソール消去
/// - a7=10: 終了（a0 が終了コード）
final class RISCVCPU {
    /// レジスタ x0〜x31（x0 は常に 0）
    private(set) var regs: [UInt32] = [UInt32](repeating: 0, count: 32)
    /// プログラムカウンタ
    private(set) var pc: UInt32 = 0
    /// ゲストメモリ
    private(set) var memory: [UInt8]
    /// 実行が終了したか
    private(set) var halted = false
    /// 終了コード（a7=10 の ECALL で設定）
    private(set) var exitCode: Int32 = 0
    /// 入力待ちで停止しているか
    private(set) var waitingForInput = false

    private var inputQueue: [UInt8] = []

    /// 1 文字出力時のコールバック
    var onChar: ((UInt8) -> Void)?
    /// コンソール消去時のコールバック
    var onClear: (() -> Void)?

    init(memorySize: Int = 1 << 20) {
        memory = [UInt8](repeating: 0, count: memorySize)
    }

    // MARK: - プログラム読み込み・入出力

    func loadProgram(_ bytes: [UInt8], at address: UInt32 = 0) {
        let start = Int(address)
        precondition(start + bytes.count <= memory.count, "プログラムがメモリに収まりません")
        memory.replaceSubrange(start..<(start + bytes.count), with: bytes)
        pc = address
    }

    func provideInput(_ bytes: [UInt8]) {
        inputQueue += bytes
        if !bytes.isEmpty {
            // 入力が届いたら入力待ちを解除する（run() が再開できるように）
            waitingForInput = false
        }
    }

    var pendingInputCount: Int { inputQueue.count }

    // MARK: - 実行

    /// 最大 `maxInstructions` 命令まで実行する。実行した命令数を返す。
    /// 終了・入力待ち・命令数上限のいずれかで戻る。
    @discardableResult
    func run(maxInstructions: Int) throws -> Int {
        var executed = 0
        while executed < maxInstructions && !halted && !waitingForInput {
            try step()
            executed += 1
        }
        return executed
    }

    /// 1 命令を実行する。
    func step() throws {
        let instr = try load32(pc)
        let opcode = instr & 0x7F
        let rd = Int((instr >> 7) & 0x1F)
        let funct3 = (instr >> 12) & 0x7
        let rs1 = Int((instr >> 15) & 0x1F)
        let rs2 = Int((instr >> 20) & 0x1F)
        let funct7 = (instr >> 25) & 0x7F

        var nextPC = pc &+ 4

        switch opcode {
        case 0x37: // LUI
            setReg(rd, instr & 0xFFFFF000)

        case 0x17: // AUIPC
            setReg(rd, pc &+ (instr & 0xFFFFF000))

        case 0x6F: // JAL
            setReg(rd, pc &+ 4)
            nextPC = pc &+ UInt32(bitPattern: immediateJ(instr))

        case 0x67: // JALR
            guard funct3 == 0 else { throw CPUFault.invalidInstruction(instr, pc: pc) }
            let target = (regs[rs1] &+ UInt32(bitPattern: immediateI(instr))) & ~1
            setReg(rd, pc &+ 4)
            nextPC = target

        case 0x63: // 分岐
            let offset = UInt32(bitPattern: immediateB(instr))
            let a = regs[rs1]
            let b = regs[rs2]
            let taken: Bool
            switch funct3 {
            case 0x0: taken = a == b // BEQ
            case 0x1: taken = a != b // BNE
            case 0x4: taken = Int32(bitPattern: a) < Int32(bitPattern: b) // BLT
            case 0x5: taken = Int32(bitPattern: a) >= Int32(bitPattern: b) // BGE
            case 0x6: taken = a < b // BLTU
            case 0x7: taken = a >= b // BGEU
            default: throw CPUFault.invalidInstruction(instr, pc: pc)
            }
            if taken { nextPC = pc &+ offset }

        case 0x03: // ロード
            let address = regs[rs1] &+ UInt32(bitPattern: immediateI(instr))
            switch funct3 {
            case 0x0: setReg(rd, UInt32(bitPattern: Int32(try load8(address)))) // LB
            case 0x1: setReg(rd, UInt32(bitPattern: Int32(try load16(address)))) // LH
            case 0x2: setReg(rd, try load32(address)) // LW
            case 0x4: setReg(rd, UInt32(try loadByte(address))) // LBU
            case 0x5: setReg(rd, UInt32(try load16u(address))) // LHU
            default: throw CPUFault.invalidInstruction(instr, pc: pc)
            }

        case 0x23: // ストア
            let address = regs[rs1] &+ UInt32(bitPattern: immediateS(instr))
            switch funct3 {
            case 0x0: try storeByte(address, UInt8(truncatingIfNeeded: regs[rs2])) // SB
            case 0x1: try store16(address, UInt16(truncatingIfNeeded: regs[rs2])) // SH
            case 0x2: try store32(address, regs[rs2]) // SW
            default: throw CPUFault.invalidInstruction(instr, pc: pc)
            }

        case 0x13: // OP-IMM
            let imm = immediateI(instr)
            let value = regs[rs1]
            switch funct3 {
            case 0x0: setReg(rd, value &+ UInt32(bitPattern: imm)) // ADDI
            case 0x1: // SLLI
                guard funct7 == 0 else { throw CPUFault.invalidInstruction(instr, pc: pc) }
                setReg(rd, value << (imm & 0x1F))
            case 0x2: setReg(rd, Int32(bitPattern: value) < imm ? 1 : 0) // SLTI
            case 0x3: setReg(rd, value < UInt32(bitPattern: imm) ? 1 : 0) // SLTIU
            case 0x4: setReg(rd, value ^ UInt32(bitPattern: imm)) // XORI
            case 0x5: // SRLI / SRAI
                if funct7 == 0x00 {
                    setReg(rd, value >> (imm & 0x1F))
                } else if funct7 == 0x20 {
                    setReg(rd, UInt32(bitPattern: Int32(bitPattern: value) >> (imm & 0x1F)))
                } else {
                    throw CPUFault.invalidInstruction(instr, pc: pc)
                }
            case 0x6: setReg(rd, value | UInt32(bitPattern: imm)) // ORI
            case 0x7: setReg(rd, value & UInt32(bitPattern: imm)) // ANDI
            default: throw CPUFault.invalidInstruction(instr, pc: pc)
            }

        case 0x33: // OP
            let a = regs[rs1]
            let b = regs[rs2]
            switch (funct3, funct7) {
            case (0x0, 0x00): setReg(rd, a &+ b) // ADD
            case (0x0, 0x20): setReg(rd, a &- b) // SUB
            case (0x1, 0x00): setReg(rd, a << (b & 0x1F)) // SLL
            case (0x2, 0x00): setReg(rd, Int32(bitPattern: a) < Int32(bitPattern: b) ? 1 : 0) // SLT
            case (0x3, 0x00): setReg(rd, a < b ? 1 : 0) // SLTU
            case (0x4, 0x00): setReg(rd, a ^ b) // XOR
            case (0x5, 0x00): setReg(rd, a >> (b & 0x1F)) // SRL
            case (0x5, 0x20): setReg(rd, UInt32(bitPattern: Int32(bitPattern: a) >> (b & 0x1F))) // SRA
            case (0x6, 0x00): setReg(rd, a | b) // OR
            case (0x7, 0x00): setReg(rd, a & b) // AND
            default: throw CPUFault.invalidInstruction(instr, pc: pc)
            }

        case 0x0F: // FENCE 系は NOP として扱う
            break

        case 0x73: // SYSTEM
            let imm = immediateI(instr)
            if imm == 0 {
                // ECALL: PC を進めるかどうかはシステムコール側で決まる
                if try handleSyscall() {
                    nextPC = pc &+ 4
                } else {
                    // 入力待ち: PC を進めず、次回同じ ECALL を再実行する
                    return
                }
            } else if imm == 1 {
                // EBREAK: デバッグ停止として終了扱い
                halted = true
                exitCode = -1
                nextPC = pc &+ 4
            } else {
                // CSR 命令などは未対応
                throw CPUFault.invalidInstruction(instr, pc: pc)
            }

        default:
            throw CPUFault.invalidInstruction(instr, pc: pc)
        }

        pc = nextPC
        regs[0] = 0
    }

    // MARK: - システムコール

    /// 戻り値: PC を進めてよい場合は true、入力待ちで止まる場合は false。
    private func handleSyscall() throws -> Bool {
        let number = regs[17] // a7
        switch number {
        case 1: // putchar
            onChar?(UInt8(truncatingIfNeeded: regs[10]))
            return true
        case 2: // print int (signed)
            let text = String(Int32(bitPattern: regs[10]))
            for byte in text.utf8 { onChar?(byte) }
            return true
        case 3: // print string (NUL terminated)
            var address = regs[10]
            while true {
                let byte = try loadByte(address)
                if byte == 0 { break }
                onChar?(byte)
                address &+= 1
            }
            return true
        case 4: // getchar
            guard !inputQueue.isEmpty else {
                waitingForInput = true
                return false
            }
            waitingForInput = false
            setReg(10, UInt32(inputQueue.removeFirst()))
            return true
        case 5: // clear console
            onClear?()
            return true
        case 10: // exit
            halted = true
            exitCode = Int32(bitPattern: regs[10])
            return true
        default:
            throw CPUFault.unknownSyscall(number)
        }
    }

    // MARK: - レジスタ・メモリアクセス

    private func setReg(_ index: Int, _ value: UInt32) {
        if index != 0 {
            regs[index] = value
        }
    }

    private func checkBounds(_ address: UInt32, size: Int) throws {
        guard Int(address) + size <= memory.count else {
            throw CPUFault.memoryOutOfBounds(address: address, size: size)
        }
    }

    func loadByte(_ address: UInt32) throws -> UInt8 {
        try checkBounds(address, size: 1)
        return memory[Int(address)]
    }

    private func load8(_ address: UInt32) throws -> Int8 {
        Int8(bitPattern: try loadByte(address))
    }

    private func load16u(_ address: UInt32) throws -> UInt16 {
        try checkBounds(address, size: 2)
        let i = Int(address)
        return UInt16(memory[i]) | (UInt16(memory[i + 1]) << 8)
    }

    private func load16(_ address: UInt32) throws -> Int16 {
        Int16(bitPattern: try load16u(address))
    }

    func load32(_ address: UInt32) throws -> UInt32 {
        try checkBounds(address, size: 4)
        let i = Int(address)
        return UInt32(memory[i])
            | (UInt32(memory[i + 1]) << 8)
            | (UInt32(memory[i + 2]) << 16)
            | (UInt32(memory[i + 3]) << 24)
    }

    private func storeByte(_ address: UInt32, _ value: UInt8) throws {
        try checkBounds(address, size: 1)
        memory[Int(address)] = value
    }

    private func store16(_ address: UInt32, _ value: UInt16) throws {
        try checkBounds(address, size: 2)
        let i = Int(address)
        memory[i] = UInt8(truncatingIfNeeded: value)
        memory[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func store32(_ address: UInt32, _ value: UInt32) throws {
        try checkBounds(address, size: 4)
        let i = Int(address)
        memory[i] = UInt8(truncatingIfNeeded: value)
        memory[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
        memory[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
        memory[i + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    // MARK: - 即値の符号拡張

    private func signExtend(_ value: UInt32, bits: Int) -> Int32 {
        let shift = 32 - bits
        return Int32(bitPattern: value << shift) >> shift
    }

    private func immediateI(_ instr: UInt32) -> Int32 {
        signExtend(instr >> 20, bits: 12)
    }

    private func immediateS(_ instr: UInt32) -> Int32 {
        signExtend(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), bits: 12)
    }

    private func immediateB(_ instr: UInt32) -> Int32 {
        let value = ((instr >> 31) & 0x1) << 12
            | ((instr >> 7) & 0x1) << 11
            | ((instr >> 25) & 0x3F) << 5
            | ((instr >> 8) & 0xF) << 1
        return signExtend(value, bits: 13)
    }

    private func immediateJ(_ instr: UInt32) -> Int32 {
        let value = ((instr >> 31) & 0x1) << 20
            | ((instr >> 12) & 0xFF) << 12
            | ((instr >> 20) & 0x1) << 11
            | ((instr >> 21) & 0x3FF) << 1
        return signExtend(value, bits: 21)
    }
}
