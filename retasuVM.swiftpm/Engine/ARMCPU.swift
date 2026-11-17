import Foundation

enum ARMFault: Error, CustomStringConvertible, LocalizedError {
    case unimplementedInstruction(UInt32, address: UInt32)
    case memoryOutOfBounds(address: UInt32)
    case unknownSyscall(Int)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unimplementedInstruction(let word, let address):
            return String(format: "ARM: 未実装の命令 0x%08X（アドレス 0x%08X）", word, address)
        case .memoryOutOfBounds(let address):
            return String(format: "ARM: メモリ範囲外アクセス（アドレス 0x%X）", address)
        case .unknownSyscall(let number):
            return "ARM: 未知のシステムコール \(number)"
        }
    }
}

/// 自作の ARM CPU エミュレータ（ARMv7-A、A32 命令セットのサブセット）。
///
/// データ処理・乗算・ロード / ストア・ブロック転送・分岐・SVC を実装する。
/// MMU やコプロセッサ、Thumb 命令は対象外。
/// システムコールは SVC 命令で呼び出す（番号は即値、引数は r0 / r1）:
/// - svc 1: 文字出力（r0 = 文字）
/// - svc 2: 符号付き整数出力（r0 = 値）
/// - svc 3: 文字列出力（r0 = アドレス、NUL 終端）
/// - svc 4: 文字入力（結果は r0。入力が無い間は待機する）
/// - svc 5: コンソール消去
/// - svc 6: 乱数（結果は r0、xorshift32）
/// - svc 10: 終了（r0 = 終了コード）
final class ARMCPU {
    private(set) var registers: [UInt32] = [UInt32](repeating: 0, count: 16)
    /// CPSR（N=bit31, Z=bit30, C=bit29, V=bit28 のみ使用）
    private(set) var cpsr: UInt32 = 0
    private(set) var memory: [UInt8]
    private(set) var halted = false
    private(set) var exitCode: Int32 = 0
    private(set) var waitingForInput = false

    private var programCounter: UInt32 = 0
    private var inputQueue: [UInt8] = []
    private let inputLock = NSLock()
    private var randomState: UInt32 = 0x2545F491

    var onChar: ((UInt8) -> Void)?
    var onClearScreen: (() -> Void)?

    init(memorySize: Int = 4 << 20) {
        memory = [UInt8](repeating: 0, count: memorySize)
        registers[13] = UInt32(memorySize) // SP はメモリ末尾
    }

    // MARK: - 公開操作

    func loadProgram(_ bytes: [UInt8], at address: UInt32) {
        let start = Int(address)
        guard start >= 0, start + bytes.count <= memory.count else { return }
        memory.replaceSubrange(start..<(start + bytes.count), with: bytes)
        programCounter = address
    }

    func provideInput(_ bytes: [UInt8]) {
        inputLock.lock()
        inputQueue.append(contentsOf: bytes)
        if !bytes.isEmpty { waitingForInput = false }
        inputLock.unlock()
    }

    func setRandomSeed(_ seed: UInt32) {
        randomState = seed == 0 ? 0x2545F491 : seed
    }

    func run(maxInstructions: Int) throws {
        var count = 0
        while !halted && !waitingForInput && count < maxInstructions {
            try step()
            count += 1
        }
    }

    // MARK: - フラグ

    private var flagN: Bool { cpsr & 0x80000000 != 0 }
    private var flagZ: Bool { cpsr & 0x40000000 != 0 }
    private var flagC: Bool { cpsr & 0x20000000 != 0 }
    private var flagV: Bool { cpsr & 0x10000000 != 0 }

    private func setFlags(n: Bool? = nil, z: Bool? = nil, c: Bool? = nil, v: Bool? = nil) {
        if let n { cpsr = n ? (cpsr | 0x80000000) : (cpsr & ~0x80000000) }
        if let z { cpsr = z ? (cpsr | 0x40000000) : (cpsr & ~0x40000000) }
        if let c { cpsr = c ? (cpsr | 0x20000000) : (cpsr & ~0x20000000) }
        if let v { cpsr = v ? (cpsr | 0x10000000) : (cpsr & ~0x10000000) }
    }

    private func evaluateCondition(_ condition: UInt32) -> Bool {
        switch condition {
        case 0: return flagZ
        case 1: return !flagZ
        case 2: return flagC
        case 3: return !flagC
        case 4: return flagN
        case 5: return !flagN
        case 6: return flagV
        case 7: return !flagV
        case 8: return flagC && !flagZ
        case 9: return !flagC || flagZ
        case 10: return flagN == flagV
        case 11: return flagN != flagV
        case 12: return !flagZ && (flagN == flagV)
        case 13: return flagZ || (flagN != flagV)
        default: return true
        }
    }

    // MARK: - メモリ

    private func readByte(at address: UInt32) throws -> UInt8 {
        guard address < memory.count else { throw ARMFault.memoryOutOfBounds(address: address) }
        return memory[Int(address)]
    }

    private func writeByte(at address: UInt32, _ value: UInt8) throws {
        guard address < memory.count else { throw ARMFault.memoryOutOfBounds(address: address) }
        memory[Int(address)] = value
    }

    private func readWord(at address: UInt32) throws -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(try readByte(at: address &+ UInt32(i))) << (8 * i)
        }
        return value
    }

    private func writeWord(at address: UInt32, _ value: UInt32) throws {
        for i in 0..<4 {
            try writeByte(at: address &+ UInt32(i), UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    /// レジスタ読み取り（r15 は命令アドレス + 8 を返す ARM の仕様どおり）
    private func readRegister(_ index: Int, instructionAddress: UInt32) -> UInt32 {
        index == 15 ? instructionAddress &+ 8 : registers[index]
    }

    private func writeRegister(_ index: Int, _ value: UInt32) {
        if index == 15 {
            programCounter = value & 0xFFFFFFFC
        } else {
            registers[index] = value
        }
    }

    // MARK: - 実行

    private func step() throws {
        let address = programCounter
        let word = try readWord(at: address)
        programCounter = address &+ 4
        guard evaluateCondition(word >> 28) else { return }

        let category = (word >> 26) & 0x3
        switch category {
        case 0:
            if (word & 0x0FFFFFF0) == 0x012FFF10 {
                // BX Rm
                let target = readRegister(Int(word & 0xF), instructionAddress: address)
                programCounter = target & 0xFFFFFFFC
            } else if ((word >> 22) & 0x3F) == 0 && ((word >> 4) & 0xF) == 0x9 {
                try executeMultiply(word: word, instructionAddress: address)
            } else if (word >> 25) & 0x7 == 0 || (word >> 25) & 0x7 == 1 {
                try executeDataProcessing(word: word, instructionAddress: address)
            } else {
                throw ARMFault.unimplementedInstruction(word, address: address)
            }
        case 1:
            try executeLoadStore(word: word, instructionAddress: address)
        case 2:
            if (word >> 25) & 0x1 == 1 {
                // B / BL
                let link = (word >> 24) & 0x1 == 1
                let offset = Int32(bitPattern: (word & 0x00FFFFFF) << 8) >> 6
                if link { registers[14] = address &+ 4 }
                programCounter = UInt32(bitPattern: Int32(bitPattern: address &+ 8) &+ offset)
            } else {
                try executeBlockTransfer(word: word, instructionAddress: address)
            }
        default:
            if (word >> 24) & 0xF == 0xF {
                try executeSyscall(Int(word & 0x00FFFFFF), instructionAddress: address)
            } else {
                throw ARMFault.unimplementedInstruction(word, address: address)
            }
        }
    }

    /// オペランド 2（シフタ）の値を計算し、キャリーアウトも返す。
    private func shifterOperand(_ word: UInt32, instructionAddress: UInt32) -> (value: UInt32, carry: Bool) {
        if (word >> 25) & 0x1 == 1 {
            // 即値: 8 ビットを偶数ビット右ローテート
            let immediate = word & 0xFF
            let rotate = Int((word >> 8) & 0xF) * 2
            if rotate == 0 { return (immediate, flagC) }
            let value = (immediate >> rotate) | (immediate << (32 - rotate))
            return (value, value & 0x80000000 != 0)
        }
        let rm = Int(word & 0xF)
        let base = readRegister(rm, instructionAddress: instructionAddress)
        let shiftType = (word >> 5) & 0x3
        let amount: Int
        if (word >> 4) & 0x1 == 0 {
            amount = Int((word >> 7) & 0x1F)
        } else {
            amount = Int(readRegister(Int((word >> 8) & 0xF), instructionAddress: instructionAddress) & 0xFF)
        }
        return applyShift(base, type: shiftType, amount: amount, isRegisterAmount: (word >> 4) & 0x1 == 1)
    }

    private func applyShift(_ value: UInt32, type: UInt32, amount: Int, isRegisterAmount: Bool) -> (value: UInt32, carry: Bool) {
        switch type {
        case 0: // LSL
            if amount == 0 { return (value, flagC) }
            if amount >= 32 { return (0, amount == 32 ? (value & 1 != 0) : false) }
            return (value << amount, (value >> (32 - amount)) & 1 != 0)
        case 1: // LSR
            let effective = isRegisterAmount ? amount : (amount == 0 ? 32 : amount)
            if effective == 0 { return (value, flagC) }
            if effective >= 32 { return (0, effective == 32 ? (value & 0x80000000 != 0) : false) }
            return (value >> effective, (value >> (effective - 1)) & 1 != 0)
        case 2: // ASR
            let effective = isRegisterAmount ? amount : (amount == 0 ? 32 : amount)
            let signed = Int32(bitPattern: value)
            if effective >= 32 { return (signed < 0 ? 0xFFFFFFFF : 0, signed < 0) }
            if effective == 0 { return (value, flagC) }
            let result = UInt32(bitPattern: signed >> effective)
            return (result, (value >> (effective - 1)) & 1 != 0)
        default: // ROR / RRX
            if !isRegisterAmount && amount == 0 {
                // RRX: キャリーを最上位へ
                return ((value >> 1) | (flagC ? 0x80000000 : 0), value & 1 != 0)
            }
            let rotate = amount & 31
            if rotate == 0 { return (value, value & 0x80000000 != 0) }
            let result = (value >> rotate) | (value << (32 - rotate))
            return (result, result & 0x80000000 != 0)
        }
    }

    private func executeDataProcessing(word: UInt32, instructionAddress: UInt32) throws {
        let opcode = (word >> 21) & 0xF
        let setFlagsBit = (word >> 20) & 0x1 == 1
        let rn = Int((word >> 16) & 0xF)
        let rd = Int((word >> 12) & 0xF)
        let operand1 = readRegister(rn, instructionAddress: instructionAddress)
        let (operand2, shifterCarry) = shifterOperand(word, instructionAddress: instructionAddress)

        var result: UInt32 = 0
        var writeResult = true
        var arithmeticCarry: Bool?
        var arithmeticOverflow: Bool?

        switch opcode {
        case 0: result = operand1 & operand2 // AND
        case 1: result = operand1 ^ operand2 // EOR
        case 2, 10: // SUB / CMP
            result = operand1 &- operand2
            arithmeticCarry = operand1 >= operand2
            arithmeticOverflow = ((operand1 ^ operand2) & (operand1 ^ result) & 0x80000000) != 0
        case 3: // RSB
            result = operand2 &- operand1
            arithmeticCarry = operand2 >= operand1
            arithmeticOverflow = ((operand2 ^ operand1) & (operand2 ^ result) & 0x80000000) != 0
        case 4, 11: // ADD / CMN
            let full = UInt64(operand1) + UInt64(operand2)
            result = UInt32(full & 0xFFFFFFFF)
            arithmeticCarry = full > 0xFFFFFFFF
            arithmeticOverflow = ((~(operand1 ^ operand2) & (operand1 ^ result)) & 0x80000000) != 0
        case 5: // ADC
            let full = UInt64(operand1) + UInt64(operand2) + (flagC ? 1 : 0)
            result = UInt32(full & 0xFFFFFFFF)
            arithmeticCarry = full > 0xFFFFFFFF
            arithmeticOverflow = ((~(operand1 ^ operand2) & (operand1 ^ result)) & 0x80000000) != 0
        case 6: // SBC
            let borrow: UInt64 = flagC ? 0 : 1
            result = operand1 &- operand2 &- UInt32(borrow)
            arithmeticCarry = UInt64(operand1) >= UInt64(operand2) + borrow
            arithmeticOverflow = ((operand1 ^ operand2) & (operand1 ^ result) & 0x80000000) != 0
        case 7: // RSC
            let borrow: UInt64 = flagC ? 0 : 1
            result = operand2 &- operand1 &- UInt32(borrow)
            arithmeticCarry = UInt64(operand2) >= UInt64(operand1) + borrow
            arithmeticOverflow = ((operand2 ^ operand1) & (operand2 ^ result) & 0x80000000) != 0
        case 8: result = operand1 & operand2 // TST
        case 9: result = operand1 ^ operand2 // TEQ
        case 12: result = operand1 | operand2 // ORR
        case 13: result = operand2 // MOV
        case 14: result = operand1 & ~operand2 // BIC
        case 15: result = ~operand2 // MVN
        default: break
        }

        let isTestOperation = opcode == 8 || opcode == 9 || opcode == 10 || opcode == 11
        if isTestOperation { writeResult = false }
        if setFlagsBit || isTestOperation {
            setFlags(
                n: result & 0x80000000 != 0,
                z: result == 0,
                c: arithmeticCarry ?? shifterCarry,
                v: arithmeticOverflow ?? flagV
            )
        }
        if writeResult {
            writeRegister(rd, result)
        }
    }

    private func executeMultiply(word: UInt32, instructionAddress: UInt32) throws {
        let accumulate = (word >> 21) & 0x1 == 1
        let setFlagsBit = (word >> 20) & 0x1 == 1
        let rd = Int((word >> 16) & 0xF)
        let rn = Int((word >> 12) & 0xF)
        let rs = Int((word >> 8) & 0xF)
        let rm = Int(word & 0xF)
        var result = readRegister(rm, instructionAddress: instructionAddress) &* readRegister(rs, instructionAddress: instructionAddress)
        if accumulate {
            result = result &+ readRegister(rn, instructionAddress: instructionAddress)
        }
        if setFlagsBit {
            setFlags(n: result & 0x80000000 != 0, z: result == 0)
        }
        writeRegister(rd, result)
    }

    private func executeLoadStore(word: UInt32, instructionAddress: UInt32) throws {
        let isRegisterOffset = (word >> 25) & 0x1 == 1
        let preIndex = (word >> 24) & 0x1 == 1
        let up = (word >> 23) & 0x1 == 1
        let isByte = (word >> 22) & 0x1 == 1
        let writeBack = (word >> 21) & 0x1 == 1
        let isLoad = (word >> 20) & 0x1 == 1
        let rn = Int((word >> 16) & 0xF)
        let rd = Int((word >> 12) & 0xF)
        let base = readRegister(rn, instructionAddress: instructionAddress)

        let offset: UInt32
        if isRegisterOffset {
            guard (word >> 4) & 0x1 == 0 else {
                throw ARMFault.unimplementedInstruction(word, address: instructionAddress)
            }
            let rm = Int(word & 0xF)
            let rmValue = readRegister(rm, instructionAddress: instructionAddress)
            let shiftType = (word >> 5) & 0x3
            let amount = Int((word >> 7) & 0x1F)
            offset = applyShift(rmValue, type: shiftType, amount: amount, isRegisterAmount: false).value
        } else {
            offset = word & 0xFFF
        }

        let offsetAddress = up ? (base &+ offset) : (base &- offset)
        let transferAddress = preIndex ? offsetAddress : base
        if !preIndex || writeBack {
            writeRegister(rn, offsetAddress)
        }

        if isLoad {
            let value = isByte ? UInt32(try readByte(at: transferAddress)) : try readWord(at: transferAddress)
            writeRegister(rd, value)
        } else {
            let value = readRegister(rd, instructionAddress: instructionAddress)
            if isByte {
                try writeByte(at: transferAddress, UInt8(value & 0xFF))
            } else {
                try writeWord(at: transferAddress, value)
            }
        }
    }

    private func executeBlockTransfer(word: UInt32, instructionAddress: UInt32) throws {
        let preIndex = (word >> 24) & 0x1 == 1
        let up = (word >> 23) & 0x1 == 1
        let writeBack = (word >> 21) & 0x1 == 1
        let isLoad = (word >> 20) & 0x1 == 1
        let rn = Int((word >> 16) & 0xF)
        let list = word & 0xFFFF
        let count = list.nonzeroBitCount
        guard count > 0 else { throw ARMFault.unimplementedInstruction(word, address: instructionAddress) }
        let base = readRegister(rn, instructionAddress: instructionAddress)

        var startAddress: UInt32
        var finalAddress: UInt32
        if up {
            startAddress = preIndex ? (base &+ 4) : base
            finalAddress = base &+ UInt32(count * 4)
        } else {
            startAddress = base &- UInt32(count * 4) &+ (preIndex ? 0 : 4)
            finalAddress = base &- UInt32(count * 4)
        }

        var address = startAddress
        if isLoad {
            for register in 0..<16 where list & (UInt32(1) << register) != 0 {
                let value = try readWord(at: address)
                writeRegister(register, value)
                address &+= 4
            }
        } else {
            for register in 0..<16 where list & (UInt32(1) << register) != 0 {
                let value = register == rn && writeBack && register != 0 && list & ((UInt32(1) << register) - 1) != 0
                    ? finalAddressAdjust(base: base, up: up, count: count)
                    : readRegister(register, instructionAddress: instructionAddress)
                try writeWord(at: address, value)
                address &+= 4
            }
        }
        if writeBack {
            writeRegister(rn, finalAddress)
        }
    }

    /// STM でベースレジスタ自体を転送するときの値（先行レジスタがある場合は書き戻し後の値）。
    private func finalAddressAdjust(base: UInt32, up: Bool, count: Int) -> UInt32 {
        up ? base &+ UInt32(count * 4) : base &- UInt32(count * 4)
    }

    // MARK: - システムコール

    private func executeSyscall(_ number: Int, instructionAddress: UInt32) throws {
        switch number {
        case 1: // putchar
            onChar?(UInt8(registers[0] & 0xFF))
        case 2: // print signed int
            let text = String(Int32(bitPattern: registers[0]))
            for byte in text.utf8 { onChar?(byte) }
        case 3: // print string
            var address = registers[0]
            var safety = 0
            while safety < 1_000_000 {
                let byte = try readByte(at: address)
                if byte == 0 { break }
                onChar?(byte)
                address &+= 1
                safety += 1
            }
        case 4: // getchar
            inputLock.lock()
            if let byte = inputQueue.first {
                inputQueue.removeFirst()
                inputLock.unlock()
                registers[0] = UInt32(byte)
            } else {
                inputLock.unlock()
                programCounter = instructionAddress
                waitingForInput = true
            }
        case 5:
            onClearScreen?()
        case 6: // random (xorshift32)
            randomState ^= randomState << 13
            randomState ^= randomState >> 17
            randomState ^= randomState << 5
            registers[0] = randomState
        case 10: // exit
            halted = true
            exitCode = Int32(bitPattern: registers[0])
        default:
            throw ARMFault.unknownSyscall(number)
        }
    }
}
