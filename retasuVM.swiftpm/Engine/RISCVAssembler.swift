import Foundation

/// アセンブル結果。
struct AssembledProgram {
    /// ロードイメージ（テキスト＋データ）
    let bytes: [UInt8]
    /// エントリポイントのアドレス
    let entry: UInt32
    /// シンボル表
    let symbols: [String: UInt32]
}

enum AssemblerError: Error, CustomStringConvertible {
    case syntax(line: Int, message: String)

    var description: String {
        switch self {
        case .syntax(let line, let message):
            return "アセンブラエラー（\(line) 行目）: \(message)"
        }
    }
}

/// RISC-V RV32I 用の小さなアセンブラ。
///
/// ゲストプログラム（アセンブリソース）をアプリ内で機械語に変換するために使う。
/// 対応: RV32I 基本命令一式、主な疑似命令（li / la / mv / call / j / ret など）、
/// ディレクティブ（.text / .data / .asciiz / .ascii / .byte / .half / .word /
/// .space / .align / .equ / .globl）。
struct RISCVAssembler {
    private static let registerNames: [String: Int] = {
        var map: [String: Int] = [:]
        for i in 0..<32 { map["x\(i)"] = i }
        let abi = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
                   "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
                   "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
                   "t3", "t4", "t5", "t6"]
        for (i, name) in abi.enumerated() { map[name] = i }
        map["fp"] = 8
        return map
    }()

    private enum Section {
        case text, data
    }

    private struct Line {
        let number: Int
        let labels: [String]
        let statement: String
    }

    // MARK: - メイン

    func assemble(_ source: String) throws -> AssembledProgram {
        let lines = try parseLines(source)

        // テキストセグメントのサイズを測り、データセグメントの開始位置を決める
        let textSize = try measureTextSize(lines: lines)
        let dataBase = (textSize + 15) & ~15

        // パス1: シンボル表を作る
        var symbols: [String: UInt32] = [:]
        var noEmit: (text: [UInt8], data: [UInt8])? = nil
        try walk(lines: lines, dataBase: dataBase, symbols: &symbols, emit: &noEmit)

        // パス2: バイト列を生成する
        var output: (text: [UInt8], data: [UInt8])? = (text: [UInt8](), data: [UInt8]())
        var emitted: [String: UInt32] = symbols
        try walk(lines: lines, dataBase: dataBase, symbols: &emitted, emit: &output)

        var bytes = output!.text
        if bytes.count < dataBase {
            bytes += [UInt8](repeating: 0, count: dataBase - bytes.count)
        }
        bytes += output!.data

        let entry = symbols["_start"] ?? 0
        return AssembledProgram(bytes: bytes, entry: entry, symbols: symbols)
    }

    // MARK: - 行のパース

    private func parseLines(_ source: String) throws -> [Line] {
        var result: [Line] = []
        let rawLines = source.components(separatedBy: "\n")
        for (index, raw) in rawLines.enumerated() {
            var text = stripComment(raw).trimmingCharacters(in: .whitespaces)
            var labels: [String] = []
            // 先頭のラベル（複数可）を剥がす
            while let match = matchLabel(text) {
                labels.append(match.name)
                text = match.rest.trimmingCharacters(in: .whitespaces)
            }
            if !labels.isEmpty || !text.isEmpty {
                result.append(Line(number: index + 1, labels: labels, statement: text))
            }
        }
        return result
    }

    /// 文字列リテラルの外側にあるコメント（# または //）を取り除く。
    private func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        var previous: Character = " "
        for ch in line {
            if escaped {
                result.append(ch)
                escaped = false
                previous = ch
                continue
            }
            if inString && ch == "\\" {
                result.append(ch)
                escaped = true
                previous = ch
                continue
            }
            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                previous = ch
                continue
            }
            if !inString {
                if ch == "#" { break }
                if ch == "/" && previous == "/" {
                    result.removeLast()
                    break
                }
            }
            result.append(ch)
            previous = ch
        }
        return result
    }

    private func matchLabel(_ text: String) -> (name: String, rest: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = String(text[..<colon])
        let valid = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }
        guard valid, !name.isEmpty,
              name.first.map({ $0.isLetter || $0 == "_" || $0 == "." }) ?? false else {
            return nil
        }
        // ラベルの直前までが 1 トークンであること（命令中の ':' と誤認しない）
        guard !name.contains(" ") && !name.contains("\t") else { return nil }
        let rest = String(text[text.index(after: colon)...])
        return (name, rest)
    }

    // MARK: - セグメント走査（パス1・パス2共通）

    /// テキストセグメントの総サイズ（バイト）を測る。
    private func measureTextSize(lines: [Line]) throws -> Int {
        var section: Section = .text
        var textLC = 0
        var symbols: [String: UInt32] = [:]
        for line in lines {
            let statement = line.statement
            if statement.hasPrefix(".") {
                let directive = statement.split(separator: " ", maxSplits: 1).first.map(String.init) ?? statement
                switch directive {
                case ".text": section = .text
                case ".data": section = .data
                case ".equ":
                    let parts = splitOperands(String(statement.dropFirst(4)))
                    if parts.count == 2, let value = parseNumber(parts[1]) {
                        symbols[parts[0]] = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
                    }
                default:
                    if section == .text {
                        textLC += try directiveSize(statement, line: line.number, sectionOffset: textLC)
                    }
                }
                continue
            }
            if statement.isEmpty { continue }
            if section == .text {
                let (mnemonic, operands) = splitStatement(statement)
                textLC += try instructionSize(mnemonic: mnemonic, operands: operands, line: line.number)
            }
        }
        return textLC
    }

    /// ラベル登録（emit が nil のとき）とバイト生成（emit があるとき）を兼ねる走査。
    private func walk(
        lines: [Line],
        dataBase: Int,
        symbols: inout [String: UInt32],
        emit: inout (text: [UInt8], data: [UInt8])?
    ) throws {
        var section: Section = .text
        var textLC = 0
        var dataLC = 0

        func currentAddress() -> UInt32 {
            section == .text ? UInt32(textLC) : UInt32(dataBase + dataLC)
        }
        func appendBytes(_ newBytes: [UInt8]) {
            if emit != nil {
                if section == .text { emit!.text += newBytes } else { emit!.data += newBytes }
            }
            if section == .text { textLC += newBytes.count } else { dataLC += newBytes.count }
        }

        for line in lines {
            for label in line.labels {
                if emit == nil {
                    symbols[label] = currentAddress()
                }
            }
            let statement = line.statement
            if statement.isEmpty { continue }

            if statement.hasPrefix(".") {
                let directive = statement.split(separator: " ", maxSplits: 1).first.map(String.init) ?? statement
                switch directive {
                case ".text":
                    section = .text
                case ".data":
                    section = .data
                case ".globl", ".global", ".option":
                    break
                case ".equ":
                    if emit == nil {
                        let parts = splitOperands(String(statement.dropFirst(4)))
                        if parts.count == 2, let value = parseNumber(parts[1]) {
                            symbols[parts[0]] = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
                        }
                    }
                case ".asciiz", ".asciz", ".string":
                    for string in try parseStringOperands(statement, line: line.number) {
                        appendBytes([UInt8](string.utf8) + [0])
                    }
                case ".ascii":
                    for string in try parseStringOperands(statement, line: line.number) {
                        appendBytes([UInt8](string.utf8))
                    }
                case ".byte":
                    for part in splitOperands(operandPart(statement)) {
                        guard let value = valueOrSymbol(part, symbols: symbols) else {
                            throw AssemblerError.syntax(line: line.number, message: ".byte の値が不正です: \(part)")
                        }
                        appendBytes([UInt8(truncatingIfNeeded: value)])
                    }
                case ".half", ".short":
                    for part in splitOperands(operandPart(statement)) {
                        guard let value = valueOrSymbol(part, symbols: symbols) else {
                            throw AssemblerError.syntax(line: line.number, message: ".half の値が不正です: \(part)")
                        }
                        let v = UInt16(truncatingIfNeeded: value)
                        appendBytes([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
                    }
                case ".word", ".long", ".int":
                    for part in splitOperands(operandPart(statement)) {
                        guard let value = valueOrSymbol(part, symbols: symbols) else {
                            throw AssemblerError.syntax(line: line.number, message: ".word の値が不正です: \(part)")
                        }
                        appendBytes((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
                    }
                case ".space", ".zero":
                    guard let count = parseNumber(operandPart(statement)) else {
                        throw AssemblerError.syntax(line: line.number, message: ".space の値が不正です")
                    }
                    appendBytes([UInt8](repeating: 0, count: Int(count)))
                case ".align":
                    guard let power = parseNumber(operandPart(statement)) else {
                        throw AssemblerError.syntax(line: line.number, message: ".align の値が不正です")
                    }
                    let alignment = 1 << Int(power)
                    let offset = section == .text ? textLC : dataLC
                    let padding = (alignment - offset % alignment) % alignment
                    appendBytes([UInt8](repeating: 0, count: padding))
                default:
                    throw AssemblerError.syntax(line: line.number, message: "未対応のディレクティブです: \(directive)")
                }
                continue
            }

            // 命令
            let (mnemonic, operands) = splitStatement(statement)
            if emit != nil {
                let words = try encode(
                    mnemonic: mnemonic,
                    operands: operands,
                    pc: currentAddress(),
                    symbols: symbols,
                    line: line.number
                )
                for word in words {
                    appendBytes((0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) })
                }
            } else {
                let size = try instructionSize(mnemonic: mnemonic, operands: operands, line: line.number)
                if section == .text { textLC += size } else { dataLC += size }
            }
        }
    }

    /// データディレクティブのサイズ（テキストセグメント内にある場合の測定用）。
    private func directiveSize(_ statement: String, line: Int, sectionOffset: Int) throws -> Int {
        let directive = statement.split(separator: " ", maxSplits: 1).first.map(String.init) ?? statement
        switch directive {
        case ".asciiz", ".asciz", ".string":
            return try parseStringOperands(statement, line: line).reduce(0) { $0 + $1.utf8.count + 1 }
        case ".ascii":
            return try parseStringOperands(statement, line: line).reduce(0) { $0 + $1.utf8.count }
        case ".byte":
            return splitOperands(operandPart(statement)).count
        case ".half", ".short":
            return splitOperands(operandPart(statement)).count * 2
        case ".word", ".long", ".int":
            return splitOperands(operandPart(statement)).count * 4
        case ".space", ".zero":
            return Int(parseNumber(operandPart(statement)) ?? 0)
        case ".align":
            let power = Int(parseNumber(operandPart(statement)) ?? 0)
            let alignment = 1 << power
            return (alignment - sectionOffset % alignment) % alignment
        default:
            return 0
        }
    }

    // MARK: - 命令サイズ（パス1用）

    private func instructionSize(mnemonic: String, operands: [String], line: Int) throws -> Int {
        switch mnemonic {
        case "li":
            guard operands.count == 2 else {
                throw AssemblerError.syntax(line: line, message: "li のオペランドが不正です")
            }
            if let value = parseNumber(operands[1]) {
                return liWords(value: value).count * 4
            }
            return 8 // シンボル参照は常に 2 命令
        case "la":
            return 8
        default:
            // ロード/ストアのラベル直接参照は 2 命令に展開する
            if ["lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw"].contains(mnemonic),
               let last = operands.last, parseOffsetOperand(last) == nil, parseNumber(last) == nil {
                return 8
            }
            return 4
        }
    }

    /// li の展開（値が確定している場合）。
    private func liWords(value: Int64) -> [UInt32] {
        let v = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        if v >= -2048 && v <= 2047 {
            return [1] // addi 1 命令（実際のエンコードは encode 側）
        }
        let hi = (v + 0x800) >> 12
        let lo = v - (hi << 12)
        return lo == 0 ? [1] : [1, 1]
    }

    // MARK: - エンコード（パス2）

    private func encode(
        mnemonic: String,
        operands: [String],
        pc: UInt32,
        symbols: [String: UInt32],
        line: Int
    ) throws -> [UInt32] {
        func err(_ message: String) -> AssemblerError {
            .syntax(line: line, message: message)
        }
        func reg(_ text: String) throws -> Int {
            guard let value = Self.registerNames[text.lowercased()] else {
                throw err("レジスタ名が不正です: \(text)")
            }
            return value
        }
        func imm(_ text: String, bits: Int) throws -> Int64 {
            if let value = parseNumber(text) { return value }
            if let symbol = symbols[text] { return Int64(symbol) }
            throw err("即値またはシンボルが不正です: \(text)")
        }
        func target(_ text: String) throws -> Int64 {
            if let value = parseNumber(text) { return value }
            if let symbol = symbols[text] { return Int64(symbol) }
            throw err("ジャンプ先が見つかりません: \(text)")
        }

        switch mnemonic {
        // 疑似命令
        case "nop":
            return [try encodeI(opcode: 0x13, funct3: 0, rd: 0, rs1: 0, imm: 0)]
        case "mv":
            try require(operands, 2, line)
            return [try encodeI(opcode: 0x13, funct3: 0, rd: reg(operands[0]), rs1: reg(operands[1]), imm: 0)]
        case "not":
            try require(operands, 2, line)
            return [try encodeI(opcode: 0x13, funct3: 4, rd: reg(operands[0]), rs1: reg(operands[1]), imm: -1)]
        case "neg":
            try require(operands, 2, line)
            return [try encodeR(funct7: 0x20, funct3: 0, rd: reg(operands[0]), rs1: 0, rs2: reg(operands[1]))]
        case "seqz":
            try require(operands, 2, line)
            return [try encodeI(opcode: 0x13, funct3: 3, rd: reg(operands[0]), rs1: reg(operands[1]), imm: 1)]
        case "snez":
            try require(operands, 2, line)
            return [try encodeR(funct7: 0x00, funct3: 3, rd: reg(operands[0]), rs1: 0, rs2: reg(operands[1]))]
        case "li":
            try require(operands, 2, line)
            let rd = try reg(operands[0])
            if let number = parseNumber(operands[1]) {
                return expandLoadConstant(rd: rd, value: number, forceTwoWords: false)
            } else if let symbol = symbols[operands[1]] {
                // シンボル参照はパス1のサイズ計算と一致させるため常に 2 命令に展開する
                return expandLoadConstant(rd: rd, value: Int64(symbol), forceTwoWords: true)
            } else {
                throw err("li の値が不正です: \(operands[1])")
            }
        case "la":
            try require(operands, 2, line)
            let rd = try reg(operands[0])
            guard let address = symbols[operands[1]] else {
                throw err("la のシンボルが見つかりません: \(operands[1])")
            }
            // パス1のサイズ計算と一致させるため常に 2 命令に展開する
            return expandLoadConstant(rd: rd, value: Int64(address), forceTwoWords: true)
        case "j":
            try require(operands, 1, line)
            return [try encodeJ(rd: 0, offset: try target(operands[0]) - Int64(pc), line: line)]
        case "jr":
            try require(operands, 1, line)
            return [try encodeI(opcode: 0x67, funct3: 0, rd: 0, rs1: reg(operands[0]), imm: 0)]
        case "ret":
            return [try encodeI(opcode: 0x67, funct3: 0, rd: 0, rs1: 1, imm: 0)]
        case "call":
            try require(operands, 1, line)
            return [try encodeJ(rd: 1, offset: try target(operands[0]) - Int64(pc), line: line)]
        case "beqz", "bnez":
            try require(operands, 2, line)
            let funct3: UInt32 = mnemonic == "beqz" ? 0 : 1
            return [try encodeB(funct3: funct3, rs1: reg(operands[0]), rs2: 0,
                            offset: try target(operands[1]) - Int64(pc), line: line)]
        case "bgt", "ble", "bgtu", "bleu":
            try require(operands, 3, line)
            let funct3: UInt32 = ["bgt": 4, "ble": 5, "bgtu": 6, "bleu": 7][mnemonic]!
            return [try encodeB(funct3: funct3, rs1: reg(operands[1]), rs2: reg(operands[0]),
                            offset: try target(operands[2]) - Int64(pc), line: line)]

        // U タイプ
        case "lui", "auipc":
            try require(operands, 2, line)
            let opcode: UInt32 = mnemonic == "lui" ? 0x37 : 0x17
            let value = try imm(operands[1], bits: 20)
            return [try encodeU(opcode: opcode, rd: reg(operands[0]), imm20: UInt32(truncatingIfNeeded: value))]

        // J タイプ
        case "jal":
            if operands.count == 1 {
                return [try encodeJ(rd: 1, offset: try target(operands[0]) - Int64(pc), line: line)]
            }
            try require(operands, 2, line)
            return [try encodeJ(rd: reg(operands[0]), offset: try target(operands[1]) - Int64(pc), line: line)]
        case "jalr":
            if operands.count == 2, let offset = parseOffsetOperand(operands[1]) {
                return [try encodeI(opcode: 0x67, funct3: 0, rd: reg(operands[0]),
                                rs1: reg(offset.register), imm: offset.value)]
            }
            try require(operands, 3, line)
            return [try encodeI(opcode: 0x67, funct3: 0, rd: reg(operands[0]),
                            rs1: reg(operands[1]), imm: imm(operands[2], bits: 12))]

        // 分岐
        case "beq", "bne", "blt", "bge", "bltu", "bgeu":
            try require(operands, 3, line)
            let funct3: UInt32 = ["beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7][mnemonic]!
            return [try encodeB(funct3: funct3, rs1: reg(operands[0]), rs2: reg(operands[1]),
                            offset: try target(operands[2]) - Int64(pc), line: line)]

        // ロード / ストア
        case "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw":
            try require(operands, 2, line)
            let loadFunct3: [String: UInt32] = ["lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5]
            let storeFunct3: [String: UInt32] = ["sb": 0, "sh": 1, "sw": 2]
            if let offset = parseOffsetOperand(operands[1]) {
                if let funct3 = loadFunct3[mnemonic] {
                    return [try encodeI(opcode: 0x03, funct3: funct3, rd: reg(operands[0]),
                                    rs1: reg(offset.register), imm: offset.value)]
                } else {
                    return [try encodeS(funct3: storeFunct3[mnemonic]!, rs1: reg(offset.register),
                                    rs2: reg(operands[0]), imm: offset.value)]
                }
            }
            // ラベル直接参照: lui + ロード/ストア に展開
            guard let address = symbols[operands[1]] else {
                throw err("アドレス指定が不正です: \(operands[1])")
            }
            let rd = try reg(operands[0])
            let hi = (Int64(address) + 0x800) >> 12
            let lo = Int64(address) - (hi << 12)
            var words = [encodeU(opcode: 0x37, rd: rd, imm20: UInt32(truncatingIfNeeded: hi))]
            if let funct3 = loadFunct3[mnemonic] {
                words.append(encodeI(opcode: 0x03, funct3: funct3, rd: rd, rs1: rd, imm: lo))
            } else {
                words.append(encodeS(funct3: storeFunct3[mnemonic]!, rs1: rd, rs2: rd, imm: lo))
            }
            // ストアのラベル直接参照は値レジスタを壊すため非対応（アドレス用に同レジスタを使う）
            if storeFunct3[mnemonic] != nil {
                throw err("ストアのラベル直接参照は未対応です。la でアドレスを取得してください")
            }
            return words

        // OP-IMM
        case "addi", "slti", "sltiu", "xori", "ori", "andi":
            try require(operands, 3, line)
            let funct3: UInt32 = ["addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7][mnemonic]!
            return [try encodeI(opcode: 0x13, funct3: funct3, rd: reg(operands[0]),
                            rs1: reg(operands[1]), imm: imm(operands[2], bits: 12))]
        case "slli", "srli", "srai":
            try require(operands, 3, line)
            let shamt = try imm(operands[2], bits: 5) & 0x1F
            let funct3: UInt32 = mnemonic == "slli" ? 1 : 5
            let funct7: Int64 = mnemonic == "srai" ? 0x20 : 0
            return [try encodeI(opcode: 0x13, funct3: funct3, rd: reg(operands[0]),
                            rs1: reg(operands[1]), imm: (funct7 << 5) | shamt)]

        // OP（レジスタ同士）
        case "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and":
            try require(operands, 3, line)
            let table: [String: (UInt32, UInt32)] = [
                "add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0x00), "slt": (2, 0x00),
                "sltu": (3, 0x00), "xor": (4, 0x00), "srl": (5, 0x00), "sra": (5, 0x20),
                "or": (6, 0x00), "and": (7, 0x00)
            ]
            let (funct3, funct7) = table[mnemonic]!
            return [try encodeR(funct7: funct7, funct3: funct3, rd: reg(operands[0]),
                            rs1: reg(operands[1]), rs2: reg(operands[2]))]

        case "ecall":
            return [0x00000073]
        case "ebreak":
            return [0x00100073]
        case "fence":
            return [0x0000000F]

        default:
            throw err("未対応の命令です: \(mnemonic)")
        }
    }

    /// li / la 共通の定数ロード展開。
    /// forceTwoWords が true の場合は、値が小さくても必ず lui + addi の 2 命令にする
    /// （パス1のサイズ計算と命令数を一致させるため）。
    private func expandLoadConstant(rd: Int, value: Int64, forceTwoWords: Bool) -> [UInt32] {
        let v = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        if !forceTwoWords && v >= -2048 && v <= 2047 {
            return [encodeI(opcode: 0x13, funct3: 0, rd: rd, rs1: 0, imm: v)]
        }
        let hi = (v + 0x800) >> 12
        let lo = v - (hi << 12)
        var words = [encodeU(opcode: 0x37, rd: rd, imm20: UInt32(truncatingIfNeeded: hi))]
        if lo != 0 || forceTwoWords {
            words.append(encodeI(opcode: 0x13, funct3: 0, rd: rd, rs1: rd, imm: lo))
        }
        return words
    }

    // MARK: - エンコード部品

    private func encodeR(funct7: UInt32, funct3: UInt32, rd: Int, rs1: Int, rs2: Int) -> UInt32 {
        (funct7 << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (funct3 << 12) | (UInt32(rd) << 7) | 0x33
    }

    private func encodeI(opcode: UInt32, funct3: UInt32, rd: Int, rs1: Int, imm: Int64) -> UInt32 {
        let field = UInt32(truncatingIfNeeded: imm) & 0xFFF
        return (field << 20) | (UInt32(rs1) << 15) | (funct3 << 12) | (UInt32(rd) << 7) | opcode
    }

    private func encodeS(funct3: UInt32, rs1: Int, rs2: Int, imm: Int64) -> UInt32 {
        let field = UInt32(truncatingIfNeeded: imm) & 0xFFF
        return ((field >> 5) << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15)
            | (funct3 << 12) | ((field & 0x1F) << 7) | 0x23
    }

    private func encodeB(funct3: UInt32, rs1: Int, rs2: Int, offset: Int64, line: Int) throws -> UInt32 {
        guard offset % 2 == 0, offset >= -4096, offset <= 4094 else {
            throw AssemblerError.syntax(line: line, message: "分岐オフセットが範囲外です: \(offset)")
        }
        let field = UInt32(truncatingIfNeeded: offset) & 0x1FFF
        return (((field >> 12) & 0x1) << 31)
            | (((field >> 5) & 0x3F) << 25)
            | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (funct3 << 12)
            | (((field >> 1) & 0xF) << 8)
            | (((field >> 11) & 0x1) << 7)
            | 0x63
    }

    private func encodeU(opcode: UInt32, rd: Int, imm20: UInt32) -> UInt32 {
        ((imm20 & 0xFFFFF) << 12) | (UInt32(rd) << 7) | opcode
    }

    private func encodeJ(rd: Int, offset: Int64, line: Int) throws -> UInt32 {
        guard offset % 2 == 0, offset >= -1_048_576, offset <= 1_048_574 else {
            throw AssemblerError.syntax(line: line, message: "ジャンプオフセットが範囲外です: \(offset)")
        }
        let field = UInt32(truncatingIfNeeded: offset) & 0x1FFFFF
        return (((field >> 20) & 0x1) << 31)
            | (((field >> 1) & 0x3FF) << 21)
            | (((field >> 11) & 0x1) << 20)
            | (((field >> 12) & 0xFF) << 12)
            | (UInt32(rd) << 7) | 0x6F
    }

    // MARK: - オペランド解析ユーティリティ

    private func splitStatement(_ statement: String) -> (String, [String]) {
        let parts = statement.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let mnemonic = (parts.first.map(String.init) ?? "").lowercased()
        guard parts.count == 2 else { return (mnemonic, []) }
        return (mnemonic, splitOperands(String(parts[1])))
    }

    private func splitOperands(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func operandPart(_ statement: String) -> String {
        let parts = statement.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    /// `offset(register)` 形式を解析する。該当しなければ nil。
    private func parseOffsetOperand(_ text: String) -> (value: Int64, register: String)? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let offsetText = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        let register = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        let value: Int64 = offsetText.isEmpty ? 0 : (parseNumber(offsetText) ?? .min)
        if value == .min { return nil }
        return (value, register)
    }

    private func parseNumber(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return Int64(trimmed.dropFirst(2), radix: 16).map { Int64($0) }
        }
        if trimmed.hasPrefix("-0x") || trimmed.hasPrefix("-0X") {
            return Int64(trimmed.dropFirst(3), radix: 16).map { -$0 }
        }
        return Int64(trimmed)
    }

    private func valueOrSymbol(_ text: String, symbols: [String: UInt32]) -> Int64? {
        if let number = parseNumber(text) { return number }
        if let symbol = symbols[text] { return Int64(symbol) }
        return nil
    }

    /// `"..."` 形式の文字列オペランド（複数可）を解析し、エスケープを展開する。
    private func parseStringOperands(_ statement: String, line: Int) throws -> [String] {
        var strings: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for ch in operandPart(statement) {
            if escaped {
                switch ch {
                case "n": current.append("\n")
                case "t": current.append("\t")
                case "r": current.append("\r")
                case "0": current.append("\0")
                case "\\": current.append("\\")
                case "\"": current.append("\"")
                default: current.append(ch)
                }
                escaped = false
                continue
            }
            if inString && ch == "\\" {
                escaped = true
                continue
            }
            if ch == "\"" {
                if inString {
                    strings.append(current)
                    current = ""
                }
                inString.toggle()
                continue
            }
            if inString {
                current.append(ch)
            }
        }
        if inString {
            throw AssemblerError.syntax(line: line, message: "文字列が閉じられていません")
        }
        return strings
    }

    private func require(_ operands: [String], _ count: Int, _ line: Int) throws {
        guard operands.count == count else {
            throw AssemblerError.syntax(line: line, message: "オペランドの数が不正です（\(operands.count) 個、\(count) 個必要）")
        }
    }
}
