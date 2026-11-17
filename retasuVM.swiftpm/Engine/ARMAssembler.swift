import Foundation

enum ARMAssemblerError: Error, CustomStringConvertible, LocalizedError {
    case syntax(line: Int, message: String)
    case unknownMnemonic(line: Int, mnemonic: String)
    case unknownSymbol(line: Int, name: String)
    case unencodableImmediate(line: Int, value: UInt32)
    case outOfRange(line: Int, message: String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .syntax(let line, let message):
            return "ARM アセンブラ: \(line) 行目: \(message)"
        case .unknownMnemonic(let line, let mnemonic):
            return "ARM アセンブラ: \(line) 行目: 未知の命令 '\(mnemonic)'"
        case .unknownSymbol(let line, let name):
            return "ARM アセンブラ: \(line) 行目: 未定義のシンボル '\(name)'"
        case .unencodableImmediate(let line, let value):
            return String(format: "ARM アセンブラ: %d 行目: 即値 0x%X は回転即値で表現できません（ldr = を使ってください）", line, value)
        case .outOfRange(let line, let message):
            return "ARM アセンブラ: \(line) 行目: \(message)"
        }
    }
}

/// 自作の ARM (A32) アセンブラ。
///
/// `ARMCPU` が実行する命令サブセットに対応する。2 パス方式でラベルを解決し、
/// `ldr rd, =式` のリテラルプールはイメージ末尾に配置する。
/// コメントは `;` と `//`。ディレクティブは .text / .data / .asciiz / .ascii /
/// .byte / .half / .word / .space / .align / .equ / .globl に対応する。
struct ARMAssembler {
    struct Program {
        var bytes: [UInt8]
        var entry: UInt32
    }

    private var labels: [String: UInt32] = [:]
    private var constants: [String: Int64] = [:]
    private var literalPool: [String] = []
    private var literalPoolIndex: [String: Int] = [:]

    private static let conditionCodes: [String: UInt32] = [
        "eq": 0, "ne": 1, "cs": 2, "hs": 2, "cc": 3, "lo": 3,
        "mi": 4, "pl": 5, "vs": 6, "vc": 7, "hi": 8, "ls": 9,
        "ge": 10, "lt": 11, "gt": 12, "le": 13, "al": 14,
    ]

    mutating func assemble(_ source: String) throws -> Program {
        labels = [:]
        constants = [:]
        literalPool = []
        literalPoolIndex = [:]
        let lines = source.components(separatedBy: .newlines)

        // パス 1: ラベルとサイズ（命令はすべて 4 バイト）
        var address: UInt32 = 0
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            while let (label, rest) = splitLabel(line) {
                if labels[label] != nil {
                    throw ARMAssemblerError.syntax(line: lineNumber, message: "ラベル '\(label)' が重複しています")
                }
                labels[label] = address
                line = rest
                if line.isEmpty { break }
            }
            if line.isEmpty { continue }
            if line.hasPrefix(".") {
                address += try directiveSize(line, lineNumber: lineNumber, currentAddress: address)
            } else {
                registerLiterals(in: line)
                address += 4
            }
        }
        let poolAddress = address
        let totalSize = address + UInt32(literalPool.count) * 4

        // パス 2: コード生成
        var bytes = [UInt8](repeating: 0, count: Int(totalSize))
        address = 0
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            while let (_, rest) = splitLabel(line) {
                line = rest
                if line.isEmpty { break }
            }
            if line.isEmpty { continue }
            if line.hasPrefix(".") {
                address = try emitDirective(line, lineNumber: lineNumber, address: address, bytes: &bytes)
            } else {
                let word = try encodeInstruction(line, lineNumber: lineNumber, address: address, poolAddress: poolAddress)
                writeWord(word, at: Int(address), into: &bytes)
                address += 4
            }
        }
        for (poolIndex, expression) in literalPool.enumerated() {
            let value = try evaluate(expression, lineNumber: 0)
            writeWord(UInt32(truncatingIfNeeded: value), at: Int(poolAddress) + poolIndex * 4, into: &bytes)
        }
        return Program(bytes: bytes, entry: 0)
    }

    // MARK: - リテラルプール

    private mutating func registerLiterals(in line: String) {
        // ldr rd, =式 の式をプールへ登録する
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased().hasPrefix("ldr") else { return }
        let operands = splitOperands(parts[1])
        guard operands.count == 2, operands[1].hasPrefix("=") else { return }
        let expression = String(operands[1].dropFirst()).trimmingCharacters(in: .whitespaces)
        if literalPoolIndex[expression] == nil {
            literalPoolIndex[expression] = literalPool.count
            literalPool.append(expression)
        }
    }

    // MARK: - 値の評価

    private func evaluate(_ token: String, lineNumber: Int) throws -> Int64 {
        let text = token.trimmingCharacters(in: .whitespaces)
        if let value = parseNumber(text) { return value }
        if let address = labels[text] { return Int64(address) }
        if let value = constants[text] { return value }
        throw ARMAssemblerError.unknownSymbol(line: lineNumber, name: text)
    }

    private func parseNumber(_ text: String) -> Int64? {
        var body = text
        var negative = false
        if body.hasPrefix("-") { negative = true; body = String(body.dropFirst()) }
        else if body.hasPrefix("+") { body = String(body.dropFirst()) }
        let value: Int64?
        if body.lowercased().hasPrefix("0x") {
            value = Int64(body.dropFirst(2), radix: 16)
        } else if body.lowercased().hasPrefix("0b") {
            value = Int64(body.dropFirst(2), radix: 2)
        } else {
            value = Int64(body)
        }
        guard let parsed = value else { return nil }
        return negative ? -parsed : parsed
    }

    // MARK: - テキスト処理

    private func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var previous: Character = "\0"
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" && previous != "\\" { inString.toggle() }
            if !inString && char == ";" { break }
            if !inString && char == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }
            result.append(char)
            previous = char
            i += 1
        }
        return result
    }

    private func splitLabel(_ line: String) -> (String, String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" "), !name.contains("\"") else { return nil }
        let rest = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        return (name, rest)
    }

    /// カンマ区切りのオペランド分割（[] と {} の内側は区切らない）
    private func splitOperands(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for char in text {
            if char == "[" || char == "{" { depth += 1 }
            if char == "]" || char == "}" { depth -= 1 }
            if char == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }
        return parts
    }

    private func parseRegister(_ token: String, lineNumber: Int) throws -> Int {
        let text = token.trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "sp": return 13
        case "lr": return 14
        case "pc": return 15
        default:
            if text.hasPrefix("r"), let number = Int(text.dropFirst()), (0...15).contains(number) {
                return number
            }
            throw ARMAssemblerError.syntax(line: lineNumber, message: "レジスタ '\(token)' が不正です")
        }
    }

    private func writeWord(_ word: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(word & 0xFF)
        bytes[offset + 1] = UInt8((word >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((word >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((word >> 24) & 0xFF)
    }

    // MARK: - ニーモニック解析

    private struct Mnemonic {
        var base: String
        var condition: UInt32 = 14
        var setFlags: Bool = false
        /// ブロック転送のアドレッシング（pre / up）
        var blockPre: Bool = false
        var blockUp: Bool = true
    }

    private func parseMnemonic(_ token: String, lineNumber: Int) throws -> Mnemonic {
        let text = token.lowercased()

        // 分岐系（b / bl / bx）は条件サフィックスと紛らわしいため個別に処理
        if text == "bx" { return Mnemonic(base: "bx") }
        if text == "b" { return Mnemonic(base: "b") }
        if text == "bl" { return Mnemonic(base: "bl") }
        if text.hasPrefix("bx"), let condition = Self.conditionCodes[String(text.dropFirst(2))] {
            return Mnemonic(base: "bx", condition: condition)
        }
        if text.hasPrefix("bl"), let condition = Self.conditionCodes[String(text.dropFirst(2))] {
            return Mnemonic(base: "bl", condition: condition)
        }
        if text.hasPrefix("b"), let condition = Self.conditionCodes[String(text.dropFirst(1))] {
            return Mnemonic(base: "b", condition: condition)
        }
        if text == "push" { return Mnemonic(base: "push") }
        if text == "pop" { return Mnemonic(base: "pop") }

        // バイト転送（ldrb / strb）は通常の ldr / str より先に判定する
        for base in ["ldrb", "strb"] where text.hasPrefix(base) {
            let rest = String(text.dropFirst(4))
            if rest.isEmpty { return Mnemonic(base: base) }
            if rest == "s" { return Mnemonic(base: base, setFlags: true) }
            if let condition = Self.conditionCodes[rest] {
                return Mnemonic(base: base, condition: condition)
            }
        }

        // ブロック転送（ldm / stm + 条件 + モード）
        for base in ["ldm", "stm"] where text.hasPrefix(base) {
            var rest = String(text.dropFirst(3))
            var mode: (pre: Bool, up: Bool)?
            for (suffix, value) in [("ia", (false, true)), ("ib", (true, true)), ("da", (false, false)), ("db", (true, false))] {
                if rest.hasSuffix(suffix) {
                    mode = value
                    rest = String(rest.dropLast(2))
                    break
                }
            }
            if mode == nil && base == "stm" && rest.hasSuffix("fd") {
                mode = (true, false) // STMFD = STMDB
                rest = String(rest.dropLast(2))
            }
            if mode == nil && base == "ldm" && rest.hasSuffix("fd") {
                mode = (false, true) // LDMFD = LDMIA
                rest = String(rest.dropLast(2))
            }
            var condition: UInt32 = 14
            if !rest.isEmpty {
                guard let parsed = Self.conditionCodes[rest] else { continue }
                condition = parsed
            }
            let resolved = mode ?? (false, true)
            return Mnemonic(base: base, condition: condition, blockPre: resolved.0, blockUp: resolved.1)
        }

        // 通常命令: base + [条件] + [s]
        let bases = ["svc", "ldr", "str", "mov", "mvn", "add", "adc", "sub", "sbc",
                     "rsb", "rsc", "and", "orr", "eor", "bic", "cmp", "cmn",
                     "tst", "teq", "mul", "mla"]
        for base in bases where text.hasPrefix(base) {
            let rest = String(text.dropFirst(base.count))
            if rest.isEmpty { return Mnemonic(base: base) }
            if rest == "s" { return Mnemonic(base: base, setFlags: true) }
            if let condition = Self.conditionCodes[rest] {
                return Mnemonic(base: base, condition: condition)
            }
            if rest.count == 3, rest.hasSuffix("s"),
               let condition = Self.conditionCodes[String(rest.dropLast())] {
                return Mnemonic(base: base, condition: condition, setFlags: true)
            }
        }
        throw ARMAssemblerError.unknownMnemonic(line: lineNumber, mnemonic: token)
    }

    // MARK: - 命令エンコード

    private func encodeInstruction(_ line: String, lineNumber: Int, address: UInt32, poolAddress: UInt32) throws -> UInt32 {
        let parts = line.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let mnemonic = try parseMnemonic(parts[0], lineNumber: lineNumber)
        let operandText = parts.count > 1 ? parts[1] : ""
        let operands = splitOperands(operandText)
        let cond = mnemonic.condition << 28

        switch mnemonic.base {
        case "b", "bl":
            guard operands.count == 1 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "分岐先が必要です") }
            let target = try evaluate(operands[0], lineNumber: lineNumber)
            let offset = target - Int64(address) - 8
            guard offset % 4 == 0, offset >= -(1 << 25), offset < (1 << 25) else {
                throw ARMAssemblerError.outOfRange(line: lineNumber, message: "分岐先が範囲外です")
            }
            let link: UInt32 = mnemonic.base == "bl" ? (1 << 24) : 0
            return cond | 0x0A000000 | link | (UInt32(bitPattern: Int32(offset >> 2)) & 0x00FFFFFF)
        case "bx":
            guard operands.count == 1 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "レジスタが必要です") }
            let rm = try parseRegister(operands[0], lineNumber: lineNumber)
            return cond | 0x012FFF10 | UInt32(rm)
        case "svc":
            guard operands.count == 1 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "svc 番号が必要です") }
            let number = try evaluate(operands[0].replacingOccurrences(of: "#", with: ""), lineNumber: lineNumber)
            guard (0...0xFFFFFF).contains(number) else {
                throw ARMAssemblerError.outOfRange(line: lineNumber, message: "svc 番号が範囲外です")
            }
            return cond | 0x0F000000 | UInt32(number)
        case "mul", "mla":
            guard operands.count >= 3 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "mul/mla にはレジスタが 3 つ必要です") }
            if mnemonic.base == "mla" {
                guard operands.count == 4 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "mla には加算レジスタが必要です") }
            }
            let rd = try parseRegister(operands[0], lineNumber: lineNumber)
            let rm = try parseRegister(operands[1], lineNumber: lineNumber)
            let rs = try parseRegister(operands[2], lineNumber: lineNumber)
            var word = cond | (UInt32(rd) << 16) | (UInt32(rs) << 8) | 0x90 | UInt32(rm)
            if mnemonic.base == "mla" {
                let rn = try parseRegister(operands[3], lineNumber: lineNumber)
                word |= (1 << 21) | (UInt32(rn) << 12)
            }
            if mnemonic.setFlags { word |= 1 << 20 }
            return word
        case "ldm", "stm", "push", "pop":
            return try encodeBlockTransfer(mnemonic: mnemonic, operands: operands, operandText: operandText, lineNumber: lineNumber)
        case "ldr", "str", "ldrb", "strb":
            return try encodeLoadStore(mnemonic: mnemonic, operandText: operandText, lineNumber: lineNumber, address: address, poolAddress: poolAddress)
        default:
            return try encodeDataProcessing(mnemonic: mnemonic, operands: operands, lineNumber: lineNumber)
        }
    }

    private func encodeBlockTransfer(mnemonic: Mnemonic, operands: [String], operandText: String, lineNumber: Int) throws -> UInt32 {
        let isLoad = mnemonic.base == "ldm" || mnemonic.base == "pop"
        var rn = 13
        var writeBack = true
        var listText: String
        if mnemonic.base == "push" || mnemonic.base == "pop" {
            listText = operandText
        } else {
            guard operands.count == 2 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "ベースレジスタとレジスタリストが必要です") }
            var baseText = operands[0]
            if baseText.hasSuffix("!") {
                writeBack = true
                baseText = String(baseText.dropLast())
            } else {
                writeBack = false
            }
            rn = try parseRegister(baseText, lineNumber: lineNumber)
            listText = operands[1]
        }
        guard listText.hasPrefix("{"), listText.hasSuffix("}") else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "レジスタリストは { } で囲んでください")
        }
        var list: UInt32 = 0
        let inner = listText.dropFirst().dropLast()
        for item in inner.split(separator: ",") {
            let item = item.trimmingCharacters(in: .whitespaces)
            if item.contains("-") {
                let bounds = item.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                guard bounds.count == 2 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "レジスタ範囲 '\(item)' が不正です") }
                let from = try parseRegister(String(bounds[0]), lineNumber: lineNumber)
                let to = try parseRegister(String(bounds[1]), lineNumber: lineNumber)
                guard from <= to else { throw ARMAssemblerError.syntax(line: lineNumber, message: "レジスタ範囲 '\(item)' が不正です") }
                for register in from...to { list |= UInt32(1) << register }
            } else {
                list |= UInt32(1) << (try parseRegister(item, lineNumber: lineNumber))
            }
        }
        let pre = mnemonic.base == "push" ? true : mnemonic.blockPre
        let up = mnemonic.base == "push" ? false : (mnemonic.base == "pop" ? true : mnemonic.blockUp)
        var word = mnemonic.condition << 28 | 0x08000000
        if pre { word |= 1 << 24 }
        if up { word |= 1 << 23 }
        if writeBack { word |= 1 << 21 }
        if isLoad { word |= 1 << 20 }
        word |= UInt32(rn) << 16 | list
        return word
    }

    /// 回転即値で表現できるか試し、(ローテーション, imm8) を返す。
    private func encodeRotatedImmediate(_ value: UInt32) -> (rotation: UInt32, imm8: UInt32)? {
        for rotation in 0..<16 {
            let shift = UInt32(rotation) * 2
            let rotated = shift == 0 ? value : ((value << shift) | (value >> (32 - shift)))
            if rotated <= 0xFF {
                return (UInt32(rotation), rotated)
            }
        }
        return nil
    }

    /// オペランド 2 をエンコードする。parts は対象部分の配列、consumed には使った要素数を返す。
    private func encodeOperand2(_ parts: [String], lineNumber: Int) throws -> UInt32 {
        guard let first = parts.first else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "オペランド 2 が必要です")
        }
        if first.hasPrefix("#") {
            let value = try evaluate(String(first.dropFirst()), lineNumber: lineNumber)
            guard value >= 0, let encoded = encodeRotatedImmediate(UInt32(value)) else {
                throw ARMAssemblerError.unencodableImmediate(line: lineNumber, value: UInt32(truncatingIfNeeded: value))
            }
            return (1 << 25) | (encoded.rotation << 8) | encoded.imm8
        }
        let rm = try parseRegister(first, lineNumber: lineNumber)
        var word = UInt32(rm)
        if parts.count > 1 {
            let shiftParts = parts[1].split(separator: " ").map(String.init)
            guard shiftParts.count == 2 else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: "シフト指定 '\(parts[1])' が不正です")
            }
            let shiftType: UInt32
            switch shiftParts[0].lowercased() {
            case "lsl": shiftType = 0
            case "lsr": shiftType = 1
            case "asr": shiftType = 2
            case "ror": shiftType = 3
            default: throw ARMAssemblerError.syntax(line: lineNumber, message: "シフト種別 '\(shiftParts[0])' が不正です")
            }
            if shiftParts[1].hasPrefix("#") {
                let amount = try evaluate(String(shiftParts[1].dropFirst()), lineNumber: lineNumber)
                guard (0...32).contains(amount) else {
                    throw ARMAssemblerError.outOfRange(line: lineNumber, message: "シフト量が範囲外です")
                }
                if amount == 32 && shiftType == 0 {
                    throw ARMAssemblerError.outOfRange(line: lineNumber, message: "lsl のシフト量は 0〜31 です")
                }
                if amount == 32 && shiftType == 3 {
                    // ror #32 は回転なしと等価（シフト指定を付けない）
                } else {
                    word |= (shiftType << 5) | (UInt32(amount == 32 ? 0 : amount) << 7)
                }
            } else {
                word |= shiftType << 5
                let rs = try parseRegister(shiftParts[1], lineNumber: lineNumber)
                word |= (UInt32(rs) << 8) | (1 << 4)
            }
        }
        return word
    }

    private func encodeDataProcessing(mnemonic: Mnemonic, operands: [String], lineNumber: Int) throws -> UInt32 {
        let opcodes: [String: UInt32] = [
            "and": 0, "eor": 1, "sub": 2, "rsb": 3, "add": 4, "adc": 5,
            "sbc": 6, "rsc": 7, "tst": 8, "teq": 9, "cmp": 10, "cmn": 11,
            "orr": 12, "mov": 13, "bic": 14, "mvn": 15,
        ]
        var opcode = opcodes[mnemonic.base]!
        var base = mnemonic.base
        let cond = mnemonic.condition << 28
        let setFlags: UInt32 = mnemonic.setFlags ? (1 << 20) : 0

        switch base {
        case "mov", "mvn":
            guard operands.count >= 2 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "mov には 2 オペランドが必要です") }
            let rd = try parseRegister(operands[0], lineNumber: lineNumber)
            // 負の即値は mov <-> mvn を入れ替えて表現する
            if operands[1].hasPrefix("#") {
                let value = try evaluate(String(operands[1].dropFirst()), lineNumber: lineNumber)
                if value < 0 {
                    let flipped = base == "mov" ? "mvn" : "mov"
                    opcode = opcodes[flipped]!
                    base = flipped
                    let operand2 = try encodeOperand2(["#\(~value)"], lineNumber: lineNumber)
                    return cond | opcode << 21 | setFlags | (UInt32(rd) << 12) | operand2
                }
            }
            let operand2 = try encodeOperand2(Array(operands[1...]), lineNumber: lineNumber)
            return cond | opcode << 21 | setFlags | (UInt32(rd) << 12) | operand2
        case "cmp", "cmn", "tst", "teq":
            guard operands.count >= 2 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "比較には 2 オペランドが必要です") }
            let rn = try parseRegister(operands[0], lineNumber: lineNumber)
            let operand2 = try encodeOperand2(Array(operands[1...]), lineNumber: lineNumber)
            return cond | opcode << 21 | (1 << 20) | (UInt32(rn) << 16) | operand2
        default:
            guard operands.count >= 3 else { throw ARMAssemblerError.syntax(line: lineNumber, message: "\(base) には 3 オペランドが必要です") }
            let rd = try parseRegister(operands[0], lineNumber: lineNumber)
            let rn = try parseRegister(operands[1], lineNumber: lineNumber)
            let operand2 = try encodeOperand2(Array(operands[2...]), lineNumber: lineNumber)
            return cond | opcode << 21 | setFlags | (UInt32(rn) << 16) | (UInt32(rd) << 12) | operand2
        }
    }

    private func encodeLoadStore(mnemonic: Mnemonic, operandText: String, lineNumber: Int, address: UInt32, poolAddress: UInt32) throws -> UInt32 {
        // 最初のカンマ（括弧の外）で Rd とアドレス指定を分ける。
        // ポストインデックス形式（[rn], #4）のカンマをアドレス側に残すため、
        // splitOperands で一括分割せず、ここで個別に処理する。
        var depth = 0
        var splitIndex: String.Index?
        for index in operandText.indices {
            let char = operandText[index]
            if char == "[" || char == "{" { depth += 1 }
            if char == "]" || char == "}" { depth -= 1 }
            if char == "," && depth == 0 {
                splitIndex = index
                break
            }
        }
        guard let splitIndex else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "アドレス指定が必要です")
        }
        let rd = try parseRegister(String(operandText[..<splitIndex]), lineNumber: lineNumber)
        let isLoad: UInt32 = (mnemonic.base == "ldr" || mnemonic.base == "ldrb") ? (1 << 20) : 0
        let isByte: UInt32 = (mnemonic.base == "ldrb" || mnemonic.base == "strb") ? (1 << 22) : 0
        let cond = mnemonic.condition << 28
        let target = String(operandText[operandText.index(after: splitIndex)...]).trimmingCharacters(in: .whitespaces)

        // リテラルプール参照（ldr rd, =式）
        if target.hasPrefix("=") {
            guard mnemonic.base == "ldr" || mnemonic.base == "ldrb" else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: "=式 は ldr でのみ使えます")
            }
            let expression = String(target.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let poolIndex = literalPoolIndex[expression] else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: "リテラル '\(expression)' が登録されていません")
            }
            let poolEntryAddress = Int64(poolAddress) + Int64(poolIndex) * 4
            let offset = poolEntryAddress - (Int64(address) + 8)
            guard (-4095...4095).contains(offset) else {
                throw ARMAssemblerError.outOfRange(line: lineNumber, message: "リテラルプールが遠すぎます")
            }
            var word = cond | 0x059F0000 | isByte | (UInt32(rd) << 12) | UInt32(abs(offset))
            if offset < 0 { word &= ~(1 << 23) } // U ビットを落として減算形式にする
            return word
        }

        // ラベル直接参照（PC 相対）
        if !target.hasPrefix("[") {
            let targetAddress = try evaluate(target, lineNumber: lineNumber)
            let offset = targetAddress - (Int64(address) + 8)
            guard (-4095...4095).contains(offset) else {
                throw ARMAssemblerError.outOfRange(line: lineNumber, message: "ラベル '\(target)' が遠すぎます")
            }
            var word = cond | 0x050F0000 | isLoad | isByte | (UInt32(rd) << 12) | UInt32(abs(offset))
            if offset >= 0 { word |= 1 << 23 }
            word |= 1 << 24
            return word
        }

        // [rn, ...] 形式
        guard let closeIndex = target.firstIndex(of: "]") else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "']' がありません")
        }
        let inside = String(target[target.index(after: target.startIndex)..<closeIndex])
        let after = String(target[target.index(after: closeIndex)...]).trimmingCharacters(in: .whitespaces)
        let insideParts = splitOperands(inside)
        guard let baseText = insideParts.first else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "ベースレジスタが必要です")
        }
        let rn = try parseRegister(baseText, lineNumber: lineNumber)
        var preIndex = true
        var writeBack: UInt32 = 0
        var offsetParts: [String] = Array(insideParts.dropFirst())
        if !after.isEmpty {
            if after == "!" {
                writeBack = 1 << 21
            } else if after.hasPrefix(",") {
                preIndex = false
                offsetParts = splitOperands(String(after.dropFirst()))
            } else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: "アドレス指定 '\(target)' が不正です")
            }
        }

        var word = cond | 0x04000000 | isLoad | isByte | (UInt32(rn) << 16) | (UInt32(rd) << 12)
        if preIndex { word |= 1 << 24 }
        word |= writeBack

        if offsetParts.isEmpty {
            word |= 1 << 23 // +0
            return word
        }
        let offsetText = offsetParts[0]
        if offsetText.hasPrefix("#") || offsetText.hasPrefix("-#") || offsetText.hasPrefix("+#") {
            let value = try evaluate(String(offsetText.dropFirst(offsetText.hasPrefix("#") ? 1 : 2)), lineNumber: lineNumber)
            let negative = offsetText.hasPrefix("-")
            let magnitude = negative ? -value : value
            guard (0...4095).contains(magnitude) else {
                throw ARMAssemblerError.outOfRange(line: lineNumber, message: "オフセットが範囲外です")
            }
            if !negative { word |= 1 << 23 }
            return word | UInt32(magnitude)
        }
        // レジスタオフセット
        let rm = try parseRegister(offsetText, lineNumber: lineNumber)
        word |= 1 << 25 | UInt32(rm)
        if offsetParts.count > 1 {
            let shift = try encodeOperand2(["r0", offsetParts[1]], lineNumber: lineNumber)
            word |= shift & 0xFF0
        }
        word |= 1 << 23
        return word
    }

    // MARK: - ディレクティブ

    private mutating func directiveSize(_ line: String, lineNumber: Int, currentAddress: UInt32) throws -> UInt32 {
        let parts = line.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let directive = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""
        switch directive {
        case ".text", ".data", ".globl":
            return 0
        case ".equ":
            let pair = splitOperands(argument)
            guard pair.count == 2, let value = parseNumber(pair[1]) else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: ".equ の形式が不正です")
            }
            constants[pair[0]] = value
            return 0
        case ".asciiz":
            return UInt32(try parseStringLiteral(argument, lineNumber: lineNumber).count + 1)
        case ".ascii":
            return UInt32(try parseStringLiteral(argument, lineNumber: lineNumber).count)
        case ".byte":
            return UInt32(splitOperands(argument).count)
        case ".half":
            return UInt32(splitOperands(argument).count * 2)
        case ".word":
            return UInt32(splitOperands(argument).count * 4)
        case ".space":
            guard let count = parseNumber(argument), count >= 0 else {
                throw ARMAssemblerError.syntax(line: lineNumber, message: ".space の値が不正です")
            }
            return UInt32(count)
        case ".align":
            let power = min(16, max(0, Int(parseNumber(argument) ?? 0)))
            let alignment = 1 << power
            if alignment <= 1 { return 0 }
            let remainder = Int(currentAddress) % alignment
            return UInt32(remainder == 0 ? 0 : alignment - remainder)
        default:
            throw ARMAssemblerError.syntax(line: lineNumber, message: "未知のディレクティブ '\(directive)'")
        }
    }

    private func emitDirective(_ line: String, lineNumber: Int, address: UInt32, bytes: inout [UInt8]) throws -> UInt32 {
        let parts = line.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let directive = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""
        var cursor = Int(address)
        switch directive {
        case ".text", ".data", ".globl", ".equ":
            break
        case ".asciiz", ".ascii":
            let stringBytes = try parseStringLiteral(argument, lineNumber: lineNumber)
            for byte in stringBytes {
                bytes[cursor] = byte
                cursor += 1
            }
            if directive == ".asciiz" {
                bytes[cursor] = 0
                cursor += 1
            }
        case ".byte":
            for token in splitOperands(argument) {
                bytes[cursor] = UInt8(try evaluate(token, lineNumber: lineNumber) & 0xFF)
                cursor += 1
            }
        case ".half":
            for token in splitOperands(argument) {
                let value = try evaluate(token, lineNumber: lineNumber)
                bytes[cursor] = UInt8(value & 0xFF)
                bytes[cursor + 1] = UInt8((value >> 8) & 0xFF)
                cursor += 2
            }
        case ".word":
            for token in splitOperands(argument) {
                writeWord(UInt32(truncatingIfNeeded: try evaluate(token, lineNumber: lineNumber)), at: cursor, into: &bytes)
                cursor += 4
            }
        case ".space":
            cursor += Int(parseNumber(argument) ?? 0)
        case ".align":
            let power = min(16, max(0, Int(parseNumber(argument) ?? 0)))
            let alignment = 1 << power
            if alignment > 1 {
                cursor = (cursor + alignment - 1) / alignment * alignment
            }
        default:
            throw ARMAssemblerError.syntax(line: lineNumber, message: "未知のディレクティブ '\(directive)'")
        }
        return UInt32(cursor)
    }

    private func parseStringLiteral(_ text: String, lineNumber: Int) throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            throw ARMAssemblerError.syntax(line: lineNumber, message: "文字列リテラルが必要です")
        }
        let inner = trimmed.dropFirst().dropLast()
        var result: [UInt8] = []
        var iterator = inner.makeIterator()
        while let char = iterator.next() {
            if char == "\\" {
                guard let escaped = iterator.next() else { break }
                switch escaped {
                case "n": result.append(0x0A)
                case "r": result.append(0x0D)
                case "t": result.append(0x09)
                case "0": result.append(0x00)
                case "\\": result.append(0x5C)
                case "\"": result.append(0x22)
                default: result.append(contentsOf: [UInt8](String(escaped).utf8))
                }
            } else {
                result.append(contentsOf: [UInt8](String(char).utf8))
            }
        }
        return result
    }
}
