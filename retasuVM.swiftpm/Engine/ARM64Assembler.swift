import Foundation

enum ARM64AssemblerError: Error, CustomStringConvertible, LocalizedError {
    case syntax(line: Int, message: String)
    case unknownMnemonic(line: Int, mnemonic: String)
    case unknownSymbol(line: Int, name: String)
    case outOfRange(line: Int, message: String)

    var description: String {
        switch self {
        case .syntax(let line, let message):
            return "ARM64 アセンブラ: \(line) 行目: \(message)"
        case .unknownMnemonic(let line, let mnemonic):
            return "ARM64 アセンブラ: \(line) 行目: 未知の命令 '\(mnemonic)'"
        case .unknownSymbol(let line, let name):
            return "ARM64 アセンブラ: \(line) 行目: 未定義のシンボル '\(name)'"
        case .outOfRange(let line, let message):
            return "ARM64 アセンブラ: \(line) 行目: \(message)"
        }
    }
    var errorDescription: String? { description }
}

/// 自作の AArch64 アセンブラ。
///
/// `ARM64CPU` が実行する命令サブセットに対応する。2 パス方式でラベルを
/// 解決し、`ldr rd, =式` のリテラルプール（8 バイト要素）はイメージ末尾に
/// 配置する。アドレスは読み込みベース（既定 0x4000_0000）からの絶対値。
/// コメントは `;` と `//`。ディレクティブは .text / .data / .asciz /
/// .ascii / .byte / .half / .word / .xword / .space / .align / .equ /
/// .globl に対応する。
struct ARM64Assembler {
    struct Program {
        var bytes: [UInt8]
        var entry: UInt64
    }

    /// プログラムを配置するベースアドレス。
    var baseAddress: UInt64 = ARM64CPU.ramBase

    private var labels: [String: UInt64] = [:]
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

        // パス 1: ラベルとサイズ
        var offset: UInt64 = 0
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            while let (label, rest) = splitLabel(line) {
                if labels[label] != nil {
                    throw ARM64AssemblerError.syntax(line: lineNumber, message: "ラベル '\(label)' が重複しています")
                }
                labels[label] = baseAddress + offset
                line = rest
                if line.isEmpty { break }
            }
            if line.isEmpty { continue }
            if line.hasPrefix(".equ") {
                // 定数はパス 1 で登録する（前方参照できるように）
                let argument = line.split(separator: " ", maxSplits: 1).map(String.init)
                if argument.count == 2 {
                    let pair = splitOperands(argument[1])
                    if pair.count == 2 {
                        constants[pair[0]] = try evaluate(pair[1], lineNumber: lineNumber)
                    }
                }
                continue
            }
            if line.hasPrefix(".") {
                offset += try directiveSize(line, lineNumber: lineNumber, currentOffset: offset)
            } else {
                registerLiterals(in: line)
                offset += 4
            }
        }
        // リテラルプールは 8 バイト境界に置く
        let poolOffset = (offset + 7) & ~UInt64(7)
        let totalSize = poolOffset + UInt64(literalPool.count) * 8

        // パス 2: コード生成
        var bytes = [UInt8](repeating: 0, count: Int(totalSize))
        offset = 0
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
                offset = try emitDirective(line, lineNumber: lineNumber, offset: offset, bytes: &bytes)
            } else {
                let word = try encodeInstruction(line, lineNumber: lineNumber, address: baseAddress + offset, poolAddress: baseAddress + poolOffset)
                writeWord(word, at: Int(offset), into: &bytes)
                offset += 4
            }
        }
        for (poolIndex, expression) in literalPool.enumerated() {
            let value = try evaluate(expression, lineNumber: 0)
            writeDoubleWord(UInt64(bitPattern: value), at: Int(poolOffset) + poolIndex * 8, into: &bytes)
        }
        return Program(bytes: bytes, entry: baseAddress)
    }

    // MARK: - リテラルプール

    private mutating func registerLiterals(in line: String) {
        // `ldr rd, =式` の式をプールへ登録する
        guard let eqRange = line.range(of: "=") else { return }
        let mnemonic = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard mnemonic == "ldr" else { return }
        let expression = String(line[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if literalPoolIndex[expression] == nil {
            literalPoolIndex[expression] = literalPool.count
            literalPool.append(expression)
        }
    }

    // MARK: - テキスト処理

    private func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if ch == ";" { break }
                if ch == "/" && previous == "/" {
                    return String(result.dropLast())
                }
            }
            result.append(ch)
            previous = ch
        }
        return result
    }

    private func splitLabel(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return nil }
        let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (name, rest)
    }

    /// オペランドをカンマで分割する（角括弧内もそのまま要素にする）。
    private func splitOperands(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "[" { depth += 1 }
            if ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }
        return parts
    }

    // MARK: - 式評価

    private func evaluate(_ expression: String, lineNumber: Int) throws -> Int64 {
        let text = expression.trimmingCharacters(in: .whitespaces)
        if let constant = constants[text] { return constant }
        if let label = labels[text] { return Int64(bitPattern: label) }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            if let value = Int64(text.dropFirst(2), radix: 16) { return value }
            // 符号なし 64 ビットとして解釈できる場合（0xFF00... など）はビットパターンで返す
            if let value = UInt64(text.dropFirst(2), radix: 16) { return Int64(bitPattern: value) }
        }
        if let value = Int64(text) { return value }
        if text.count == 3, text.hasPrefix("'"), text.hasSuffix("'") {
            return Int64(text[text.index(text.startIndex, offsetBy: 1)].asciiValue ?? 0)
        }
        throw ARM64AssemblerError.unknownSymbol(line: lineNumber, name: text)
    }

    private func parseImmediate(_ text: String, lineNumber: Int) throws -> Int64 {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value = String(value.dropFirst()) }
        return try evaluate(value, lineNumber: lineNumber)
    }

    // MARK: - ディレクティブ

    private func directiveSize(_ line: String, lineNumber: Int, currentOffset: UInt64) throws -> UInt64 {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let directive = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        switch directive {
        case ".text", ".data", ".globl", ".global":
            return 0
        case ".equ":
            return 0
        case ".asciz":
            return UInt64(parseStringLiteral(argument).count + 1)
        case ".ascii":
            return UInt64(parseStringLiteral(argument).count)
        case ".byte":
            return UInt64(splitOperands(argument).count)
        case ".half":
            return UInt64(splitOperands(argument).count * 2)
        case ".word":
            return UInt64(splitOperands(argument).count * 4)
        case ".xword":
            return UInt64(splitOperands(argument).count * 8)
        case ".space":
            return UInt64(try evaluate(argument, lineNumber: lineNumber))
        case ".align":
            let power = try evaluate(argument, lineNumber: lineNumber)
            let alignment = UInt64(1) << power
            let aligned = (currentOffset + alignment - 1) & ~(alignment - 1)
            return aligned - currentOffset
        default:
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "未知のディレクティブ '\(directive)'")
        }
    }

    private func emitDirective(_ line: String, lineNumber: Int, offset: UInt64, bytes: inout [UInt8]) throws -> UInt64 {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let directive = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        var offset = offset
        switch directive {
        case ".text", ".data", ".globl", ".global":
            break
        case ".equ":
            break  // パス 1 で登録済み
        case ".asciz":
            for byte in parseStringLiteral(argument) { bytes[Int(offset)] = byte; offset += 1 }
            bytes[Int(offset)] = 0
            offset += 1
        case ".ascii":
            for byte in parseStringLiteral(argument) { bytes[Int(offset)] = byte; offset += 1 }
        case ".byte":
            for item in splitOperands(argument) {
                bytes[Int(offset)] = UInt8(truncatingIfNeeded: try evaluate(item, lineNumber: lineNumber))
                offset += 1
            }
        case ".half":
            for item in splitOperands(argument) {
                let value = UInt16(truncatingIfNeeded: try evaluate(item, lineNumber: lineNumber))
                bytes[Int(offset)] = UInt8(value & 0xFF)
                bytes[Int(offset) + 1] = UInt8(value >> 8)
                offset += 2
            }
        case ".word":
            for item in splitOperands(argument) {
                writeWord(UInt32(truncatingIfNeeded: try evaluate(item, lineNumber: lineNumber)), at: Int(offset), into: &bytes)
                offset += 4
            }
        case ".xword":
            for item in splitOperands(argument) {
                writeDoubleWord(UInt64(bitPattern: try evaluate(item, lineNumber: lineNumber)), at: Int(offset), into: &bytes)
                offset += 8
            }
        case ".space":
            offset += UInt64(try evaluate(argument, lineNumber: lineNumber))
        case ".align":
            let power = try evaluate(argument, lineNumber: lineNumber)
            let alignment = UInt64(1) << power
            offset = (offset + alignment - 1) & ~(alignment - 1)
        default:
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "未知のディレクティブ '\(directive)'")
        }
        return offset
    }

    private func parseStringLiteral(_ text: String) -> [UInt8] {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else { return [] }
        trimmed = String(trimmed.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let ch = trimmed[index]
            if ch == "\\" {
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex {
                    switch trimmed[next] {
                    case "n": bytes.append(0x0A)
                    case "t": bytes.append(0x09)
                    case "r": bytes.append(0x0D)
                    case "0": bytes.append(0x00)
                    case "\\": bytes.append(0x5C)
                    case "\"": bytes.append(0x22)
                    default: bytes.append(UInt8(ascii: " "))
                    }
                    index = trimmed.index(after: next)
                    continue
                }
            }
            bytes.append(contentsOf: String(ch).utf8)
            index = trimmed.index(after: index)
        }
        return bytes
    }

    private func writeWord(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeDoubleWord(_ value: UInt64, at offset: Int, into bytes: inout [UInt8]) {
        for i in 0..<8 {
            bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }

    // MARK: - レジスタ

    /// レジスタ名を (番号, 64 ビットか, SP 可否) へ変換する。xzr は番号 31。
    private func parseRegister(_ text: String) -> (number: Int, is64: Bool, isSP: Bool)? {
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "sp" { return (31, true, true) }
        if name == "xzr" { return (31, true, false) }
        if name == "wzr" { return (31, false, false) }
        if name == "lr" { return (30, true, false) }
        if name.hasPrefix("x"), let n = Int(name.dropFirst()), (0...30).contains(n) { return (n, true, false) }
        if name.hasPrefix("w"), let n = Int(name.dropFirst()), (0...30).contains(n) { return (n, false, false) }
        return nil
    }

    // MARK: - 命令エンコード

    private func encodeInstruction(_ line: String, lineNumber: Int, address: UInt64, poolAddress: UInt64) throws -> UInt32 {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let mnemonic = parts[0].lowercased()
        let operandText = parts.count > 1 ? parts[1] : ""
        let operands = splitOperands(operandText)

        // 条件分岐 b.<cond>
        if mnemonic.hasPrefix("b.") {
            let condName = String(mnemonic.dropFirst(2))
            guard let cond = Self.conditionCodes[condName] else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "未知の条件 '\(condName)'")
            }
            let target = try evaluate(operands[0], lineNumber: lineNumber)
            let offset = Int64(bitPattern: UInt64(bitPattern: target)) &- Int64(bitPattern: address)
            guard offset % 4 == 0, offset >= -(1 << 20), offset < (1 << 20) else {
                throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "分岐先が範囲外です")
            }
            return 0x5400_0000 | (UInt32((offset >> 2) & 0x7_FFFF) << 5) | cond
        }

        switch mnemonic {
        case "nop": return 0xD503_201F
        case "wfi": return 0xD503_207F
        case "eret": return 0xD69F_03E0
        case "svc":
            let imm = try parseImmediate(operands[0], lineNumber: lineNumber)
            return 0xD400_0001 | (UInt32(imm & 0xFFFF) << 5)
        case "b", "bl":
            let target = try evaluate(operands[0], lineNumber: lineNumber)
            let offset = target &- Int64(bitPattern: address)
            guard offset % 4 == 0, offset >= -(1 << 27), offset < (1 << 27) else {
                throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "分岐先が範囲外です")
            }
            let base: UInt32 = mnemonic == "bl" ? 0x9400_0000 : 0x1400_0000
            return base | UInt32((offset >> 2) & 0x03FF_FFFF)
        case "ret":
            let rn = operands.isEmpty ? 30 : (parseRegister(operands[0])?.number ?? 30)
            return 0xD65F_0000 | (UInt32(rn) << 5)
        case "br", "blr":
            guard let reg = parseRegister(operands[0]) else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "レジスタが必要です")
            }
            let base: UInt32 = mnemonic == "br" ? 0xD61F_0000 : 0xD63F_0000
            return base | (UInt32(reg.number) << 5)
        case "cbz", "cbnz", "tbz", "tbnz":
            guard let reg = parseRegister(operands[0]) else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "レジスタが必要です")
            }
            let isTB = mnemonic.hasPrefix("t")
            let targetIndex = isTB ? 2 : 1
            let target = try evaluate(operands[targetIndex], lineNumber: lineNumber)
            let offset = target &- Int64(bitPattern: address)
            let invert = mnemonic.hasSuffix("nz") || mnemonic.hasSuffix("bnz")
            if isTB {
                let bit = try parseImmediate(operands[1], lineNumber: lineNumber)
                guard offset % 4 == 0, offset >= -(1 << 15), offset < (1 << 15) else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "分岐先が範囲外です")
                }
                return (((UInt32(bit) >> 5) & 1) << 31) | ((invert ? UInt32(1) : 0) << 24) | 0x3600_0000
                    | ((UInt32(bit) & 0x1F) << 19) | (UInt32((offset >> 2) & 0x3FFF) << 5) | UInt32(reg.number)
            }
            guard offset % 4 == 0, offset >= -(1 << 20), offset < (1 << 20) else {
                throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "分岐先が範囲外です")
            }
            return ((reg.is64 ? UInt32(1) : 0) << 31) | ((invert ? UInt32(1) : 0) << 24) | 0x3400_0000
                | (UInt32((offset >> 2) & 0x7_FFFF) << 5) | UInt32(reg.number)
        case "adr", "adrp":
            guard let reg = parseRegister(operands[0]) else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "レジスタが必要です")
            }
            let target = try evaluate(operands[1], lineNumber: lineNumber)
            if mnemonic == "adr" {
                let offset = target &- Int64(bitPattern: address)
                guard offset >= -(1 << 20), offset < (1 << 20) else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "ADR の範囲外です")
                }
                let imm = UInt32(bitPattern: Int32(offset))
                return 0x1000_0000 | ((imm & 0x3) << 29) | (((imm >> 2) & 0x7_FFFF) << 5) | UInt32(reg.number)
            }
            let offset = (target & ~Int64(0xFFF)) &- (Int64(bitPattern: address) & ~Int64(0xFFF))
            let imm = UInt32(bitPattern: Int32(offset >> 12))
            return 0x9000_0000 | ((imm & 0x3) << 29) | (((imm >> 2) & 0x7_FFFF) << 5) | UInt32(reg.number)
        default:
            break
        }

        // ロード / ストア
        if ["ldr", "str", "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh", "ldrsw", "ldur", "stur"].contains(mnemonic) {
            return try encodeLoadStore(mnemonic: mnemonic, operands: operands, line: line, lineNumber: lineNumber, address: address, poolAddress: poolAddress)
        }
        if mnemonic == "ldp" || mnemonic == "stp" {
            return try encodePair(mnemonic: mnemonic, operands: operands, lineNumber: lineNumber)
        }

        // データ処理
        if let word = try encodeDataProcessing(mnemonic: mnemonic, operands: operands, lineNumber: lineNumber) {
            return word
        }
        throw ARM64AssemblerError.unknownMnemonic(line: lineNumber, mnemonic: mnemonic)
    }

    // MARK: ロード / ストアのエンコード

    private func loadStoreFields(mnemonic: String, rtIs64: Bool) -> (size: UInt32, opc: UInt32) {
        switch mnemonic {
        case "str", "ldr": return (rtIs64 ? 3 : 2, mnemonic == "str" ? 0 : 1)
        case "strb": return (0, 0)
        case "ldrb": return (0, 1)
        case "ldrsb": return (0, rtIs64 ? 2 : 3)
        case "strh": return (1, 0)
        case "ldrh": return (1, 1)
        case "ldrsh": return (1, rtIs64 ? 2 : 3)
        case "ldrsw": return (2, 2)
        case "stur": return (rtIs64 ? 3 : 2, 0)
        case "ldur": return (rtIs64 ? 3 : 2, 1)
        default: return (3, 1)
        }
    }

    private func encodeLoadStore(mnemonic: String, operands: [String], line: String, lineNumber: Int, address: UInt64, poolAddress: UInt64) throws -> UInt32 {
        guard let rt = parseRegister(operands[0]) else {
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "レジスタが必要です")
        }
        let (size, opc) = loadStoreFields(mnemonic: mnemonic, rtIs64: rt.is64)
        let rest = operands.dropFirst().joined(separator: ", ")

        // リテラル: ldr rt, =式 / ldr rt, ラベル
        if mnemonic == "ldr", !rest.hasPrefix("[") {
            let target: UInt64
            if rest.hasPrefix("=") {
                let expression = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let index = literalPoolIndex[expression] else {
                    throw ARM64AssemblerError.syntax(line: lineNumber, message: "リテラルプールにありません")
                }
                target = poolAddress + UInt64(index) * 8
            } else {
                target = UInt64(bitPattern: try evaluate(rest, lineNumber: lineNumber))
            }
            let offset = Int64(bitPattern: target) &- Int64(bitPattern: address)
            guard offset % 4 == 0, offset >= -(1 << 20), offset < (1 << 20) else {
                throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "リテラルが範囲外です")
            }
            let literalOpc: UInt32 = rt.is64 ? 1 : 0
            return (literalOpc << 30) | 0x1800_0000 | (UInt32((offset >> 2) & 0x7_FFFF) << 5) | UInt32(rt.number)
        }

        // メモリオペランドを分解する: [rn], [rn, #imm], [rn, #imm]!, [rn], #imm, [rn, rm, ...]
        var memoryText = rest
        var postImmediate: Int64? = nil
        var preIndex = false
        if memoryText.hasSuffix("!") {
            preIndex = true
            memoryText = String(memoryText.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if !memoryText.hasPrefix("[") {
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "メモリオペランドが必要です")
        }
        if let closeRange = memoryText.range(of: "]") {
            let after = String(memoryText[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(",") {
                postImmediate = try parseImmediate(String(after.dropFirst()), lineNumber: lineNumber)
            }
            memoryText = String(memoryText[..<closeRange.lowerBound].dropFirst())
        } else {
            memoryText = String(memoryText.dropFirst())
        }
        let inner = splitOperands(memoryText)
        guard let rnReg = parseRegister(inner[0]) else {
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "ベースレジスタが必要です")
        }
        let baseFields = (size << 30) | (opc << 22) | (UInt32(rnReg.number) << 5) | UInt32(rt.number)

        if inner.count == 1 {
            if let post = postImmediate {
                // ポストインデックス
                guard post >= -256, post <= 255 else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "オフセットが範囲外です")
                }
                return baseFields | 0x3800_0000 | (UInt32(post & 0x1FF) << 12) | (0b01 << 10)
            }
            // [rn] のみ: オフセット 0
            if mnemonic == "ldur" || mnemonic == "stur" {
                return baseFields | 0x3800_0000
            }
            return baseFields | 0x3900_0000
        }
        if inner.count == 2 {
            let second = inner[1]
            if second.hasPrefix("#") || Int64(second) != nil || constants[second] != nil {
                let offset = try parseImmediate(second, lineNumber: lineNumber)
                if preIndex {
                    guard offset >= -256, offset <= 255 else {
                        throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "オフセットが範囲外です")
                    }
                    return baseFields | 0x3800_0000 | (UInt32(offset & 0x1FF) << 12) | (0b11 << 10)
                }
                let scale = Int64(1) << size
                if offset >= 0 && offset % scale == 0 && (offset / scale) <= 0xFFF && mnemonic != "ldur" && mnemonic != "stur" {
                    return baseFields | 0x3900_0000 | (UInt32(offset / scale) << 10)
                }
                guard offset >= -256, offset <= 255 else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "オフセットが範囲外です（アンスケールド形式）")
                }
                return baseFields | 0x3800_0000 | (UInt32(offset & 0x1FF) << 12)
            }
            // レジスタオフセット
            guard let rmReg = parseRegister(second) else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "オフセットレジスタが必要です")
            }
            return baseFields | 0x3820_0000 | (UInt32(1) << 21) | (UInt32(rmReg.number) << 16) | (0b011 << 13) | (0b10 << 10)
        }
        if inner.count == 3 {
            // [rn, rm, lsl #n] / [rn, rm, sxtw #n] など（単純な形式のみ）
            guard let rmReg = parseRegister(inner[1]) else {
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "オフセットレジスタが必要です")
            }
            let extParts = inner[2].split(separator: " ").map(String.init)
            let extName = extParts[0].lowercased()
            let amount = extParts.count > 1 ? (try parseImmediate(extParts[1], lineNumber: lineNumber)) : 0
            let option: UInt32
            switch extName {
            case "lsl", "uxtx": option = 0b011
            case "uxtw": option = 0b010
            case "sxtw": option = 0b110
            case "sxtx": option = 0b111
            default:
                throw ARM64AssemblerError.syntax(line: lineNumber, message: "未知の拡張 '\(extName)'")
            }
            let sBit: UInt32 = amount == Int64(size) ? 1 : 0
            return baseFields | 0x3820_0000 | (UInt32(1) << 21) | (UInt32(rmReg.number) << 16) | (option << 13) | (sBit << 12) | (0b10 << 10)
        }
        throw ARM64AssemblerError.syntax(line: lineNumber, message: "メモリオペランドを解釈できません")
    }

    private func encodePair(mnemonic: String, operands: [String], lineNumber: Int) throws -> UInt32 {
        guard operands.count >= 3, let rt = parseRegister(operands[0]), let rt2 = parseRegister(operands[1]) else {
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "レジスタが 2 つ必要です")
        }
        let isLoad = mnemonic == "ldp"
        let opc: UInt32 = rt.is64 ? 0b10 : 0b00
        var memoryText = operands.dropFirst(2).joined(separator: ", ")
        var mode: UInt32 = 0b010   // オフセット
        var postImmediate: Int64? = nil
        if memoryText.hasSuffix("!") {
            mode = 0b011           // プレインデックス
            memoryText = String(memoryText.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var offset: Int64 = 0
        if let closeRange = memoryText.range(of: "]") {
            let after = String(memoryText[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(",") {
                postImmediate = try parseImmediate(String(after.dropFirst()), lineNumber: lineNumber)
                mode = 0b001       // ポストインデックス
            }
            memoryText = String(memoryText[..<closeRange.lowerBound].dropFirst())
        } else {
            memoryText = String(memoryText.dropFirst())
        }
        let inner = splitOperands(memoryText)
        guard let rnReg = parseRegister(inner[0]) else {
            throw ARM64AssemblerError.syntax(line: lineNumber, message: "ベースレジスタが必要です")
        }
        if inner.count == 2 {
            offset = try parseImmediate(inner[1], lineNumber: lineNumber)
        }
        if let post = postImmediate { offset = post }
        let scale: Int64 = rt.is64 ? 8 : 4
        guard offset % scale == 0, (offset / scale) >= -64, (offset / scale) <= 63 else {
            throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "ペアのオフセットが範囲外です")
        }
        return (opc << 30) | 0x2800_0000 | (mode << 23) | ((isLoad ? UInt32(1) : 0) << 22)
            | (UInt32((offset / scale) & 0x7F) << 15) | (UInt32(rt2.number) << 10)
            | (UInt32(rnReg.number) << 5) | UInt32(rt.number)
    }

    // MARK: データ処理のエンコード

    /// シフト指定（"lsl #3" など）を (種別, 量) に変換する。種別: LSL=0, LSR=1, ASR=2, ROR=3。
    private func parseShiftOperand(_ text: String, lineNumber: Int) throws -> (type: UInt32, amount: UInt32)? {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return nil }
        let type: UInt32
        switch parts[0].lowercased() {
        case "lsl": type = 0
        case "lsr": type = 1
        case "asr": type = 2
        case "ror": type = 3
        default: return nil
        }
        let amount = try parseImmediate(parts[1], lineNumber: lineNumber)
        guard amount >= 0 && amount < 64 else { return nil }
        return (type, UInt32(amount))
    }

    private func encodeDataProcessing(mnemonic: String, operands: [String], lineNumber: Int) throws -> UInt32? {
        // MOV 系
        if mnemonic == "mov" {
            guard operands.count == 2, let rd = parseRegister(operands[0]) else { return nil }
            if operands[1].lowercased() == "sp" {
                // mov rd, sp は ADD rd, sp, #0 として符号化する
                return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1100_0000 | (31 << 5) | UInt32(rd.number)
            }
            if let rmReg = parseRegister(operands[1]) {
                if operands[0].lowercased() == "sp" {
                    // mov sp, rm は ADD sp, rm, #0 として符号化する（ORR では SP へ書けない）
                    return (1 << 31) | 0x1100_0000 | (UInt32(rmReg.number) << 5) | 31
                }
                // レジスタ間コピー: ORR rd, xzr, rm
                return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x2A00_0000 | (UInt32(rmReg.number) << 16) | (31 << 5) | UInt32(rd.number)
            }
            let value = try parseImmediate(operands[1], lineNumber: lineNumber)
            return try encodeMoveImmediate(rd: rd, value: value, lineNumber: lineNumber)
        }
        if mnemonic == "movz" || mnemonic == "movn" || mnemonic == "movk" {
            guard operands.count >= 2, let rd = parseRegister(operands[0]) else { return nil }
            let value = try parseImmediate(operands[1], lineNumber: lineNumber)
            var shift = 0
            if operands.count == 3 {
                let shiftParts = operands[2].split(separator: " ").map(String.init)
                if shiftParts.count == 2 { shift = Int(try parseImmediate(shiftParts[1], lineNumber: lineNumber)) }
            }
            let opc: UInt32 = mnemonic == "movn" ? 0 : (mnemonic == "movz" ? 2 : 3)
            return ((rd.is64 ? UInt32(1) : 0) << 31) | (opc << 29) | 0x1280_0000
                | (UInt32(shift / 16) << 21) | (UInt32(value & 0xFFFF) << 5) | UInt32(rd.number)
        }

        // エイリアス
        if mnemonic == "cmp" || mnemonic == "cmn" {
            guard operands.count == 2, let rn = parseRegister(operands[0]) else { return nil }
            let isSub = mnemonic == "cmp"
            if operands[1].hasPrefix("#") {
                let imm = try parseImmediate(operands[1], lineNumber: lineNumber)
                return try encodeAddSubImmediate(rd: 31, rn: rn.number, imm: imm, isSub: isSub, setFlags: true, is64: rn.is64, lineNumber: lineNumber)
            }
            guard let rmReg = parseRegister(operands[1]) else { return nil }
            return ((rn.is64 ? UInt32(1) : 0) << 31) | ((isSub ? UInt32(1) : 0) << 30) | (1 << 29) | 0x0B00_0000
                | (UInt32(rmReg.number) << 16) | (UInt32(rn.number) << 5) | 31
        }
        if mnemonic == "tst" {
            guard operands.count == 2, let rn = parseRegister(operands[0]) else { return nil }
            if operands[1].hasPrefix("#") {
                let imm = try parseImmediate(operands[1], lineNumber: lineNumber)
                guard let fields = encodeBitMask(value: UInt64(bitPattern: imm), is64: rn.is64) else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "ビットマスク即値で表現できません")
                }
                return ((rn.is64 ? UInt32(1) : 0) << 31) | (3 << 29) | 0x1200_0000
                    | (fields.n << 22) | (fields.immr << 16) | (fields.imms << 10) | (UInt32(rn.number) << 5) | 31
            }
            guard let rmReg = parseRegister(operands[1]) else { return nil }
            return ((rn.is64 ? UInt32(1) : 0) << 31) | (3 << 29) | 0x0A00_0000 | (UInt32(rmReg.number) << 16) | (UInt32(rn.number) << 5) | 31
        }
        if mnemonic == "neg" || mnemonic == "mvn" {
            guard operands.count == 2, let rd = parseRegister(operands[0]), let rmReg = parseRegister(operands[1]) else { return nil }
            if mnemonic == "neg" {
                return ((rd.is64 ? UInt32(1) : 0) << 31) | (1 << 30) | 0x0B00_0000 | (UInt32(rmReg.number) << 16) | (31 << 5) | UInt32(rd.number)
            }
            return ((rd.is64 ? UInt32(1) : 0) << 31) | (1 << 29) | 0x0A00_0000 | (1 << 21) | (UInt32(rmReg.number) << 16) | (31 << 5) | UInt32(rd.number)
        }
        if mnemonic == "sxtb" || mnemonic == "sxth" || mnemonic == "sxtw" || mnemonic == "uxtb" || mnemonic == "uxth" {
            guard operands.count == 2, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]) else { return nil }
            let isSigned = mnemonic.hasPrefix("s")
            let imms: UInt32 = mnemonic.hasSuffix("tb") ? 7 : (mnemonic.hasSuffix("th") ? 15 : 31)
            let base: UInt32 = isSigned ? 0x1300_0000 : 0x5300_0000
            return ((rd.is64 ? UInt32(1) : 0) << 31) | base | ((rd.is64 ? UInt32(1) : 0) << 22) | (imms << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        if mnemonic == "cset" {
            guard operands.count == 2, let rd = parseRegister(operands[0]),
                  let cond = Self.conditionCodes[operands[1].lowercased()] else { return nil }
            let inverted = cond ^ 1
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1A80_0400 | (31 << 16) | (inverted << 12) | (31 << 5) | UInt32(rd.number)
        }
        if mnemonic == "csel" {
            guard operands.count == 4, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]),
                  let rmReg = parseRegister(operands[2]), let cond = Self.conditionCodes[operands[3].lowercased()] else { return nil }
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1A80_0000 | (UInt32(rmReg.number) << 16) | (cond << 12) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }

        // ADD / SUB / 論理（レジスタ・即値）
        let addSubOps: [String: (isSub: Bool, setFlags: Bool)] = [
            "add": (false, false), "adds": (false, true), "sub": (true, false), "subs": (true, true),
        ]
        if let op = addSubOps[mnemonic] {
            guard operands.count == 3 || operands.count == 4, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]) else { return nil }
            if operands.count == 3 && operands[2].hasPrefix("#") {
                let imm = try parseImmediate(operands[2], lineNumber: lineNumber)
                return try encodeAddSubImmediate(rd: rd.number, rn: rn.number, imm: imm, isSub: op.isSub, setFlags: op.setFlags, is64: rd.is64, lineNumber: lineNumber)
            }
            guard let rmReg = parseRegister(operands[2]) else { return nil }
            var shiftField: UInt32 = 0
            if operands.count == 4 {
                guard let shift = try parseShiftOperand(operands[3], lineNumber: lineNumber) else { return nil }
                shiftField = (shift.type << 22) | (shift.amount << 10)
            }
            return ((rd.is64 ? UInt32(1) : 0) << 31) | ((op.isSub ? UInt32(1) : 0) << 30) | ((op.setFlags ? UInt32(1) : 0) << 29)
                | 0x0B00_0000 | shiftField | (UInt32(rmReg.number) << 16) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        let logicalOps: [String: UInt32] = ["and": 0, "orr": 1, "eor": 2, "ands": 3]
        if let opc = logicalOps[mnemonic] {
            guard operands.count == 3 || operands.count == 4, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]) else { return nil }
            if operands.count == 3 && operands[2].hasPrefix("#") {
                let imm = try parseImmediate(operands[2], lineNumber: lineNumber)
                guard let fields = encodeBitMask(value: UInt64(bitPattern: imm), is64: rd.is64) else {
                    throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "ビットマスク即値で表現できません")
                }
                return ((rd.is64 ? UInt32(1) : 0) << 31) | (opc << 29) | 0x1200_0000
                    | (fields.n << 22) | (fields.immr << 16) | (fields.imms << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
            }
            guard let rmReg = parseRegister(operands[2]) else { return nil }
            var shiftField: UInt32 = 0
            if operands.count == 4 {
                guard let shift = try parseShiftOperand(operands[3], lineNumber: lineNumber) else { return nil }
                shiftField = (shift.type << 22) | (shift.amount << 10)
            }
            return ((rd.is64 ? UInt32(1) : 0) << 31) | (opc << 29) | 0x0A00_0000 | shiftField | (UInt32(rmReg.number) << 16) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }

        // 乗算 / 除算 / シフト
        if mnemonic == "mul" || mnemonic == "madd" || mnemonic == "msub" {
            let raIndex = mnemonic == "mul" ? 31 : 3
            guard operands.count == (mnemonic == "mul" ? 3 : 4), let rd = parseRegister(operands[0]),
                  let rn = parseRegister(operands[1]), let rmReg = parseRegister(operands[2]) else { return nil }
            let ra = mnemonic == "mul" ? 31 : (parseRegister(operands[raIndex])?.number ?? 31)
            let o0: UInt32 = mnemonic == "msub" ? 1 : 0
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1B00_0000 | (UInt32(rmReg.number) << 16) | (o0 << 15) | (UInt32(ra) << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        if mnemonic == "udiv" || mnemonic == "sdiv" {
            guard operands.count == 3, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]),
                  let rmReg = parseRegister(operands[2]) else { return nil }
            let opcode: UInt32 = mnemonic == "udiv" ? 2 : 3
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1AC0_0000 | (UInt32(rmReg.number) << 16) | (opcode << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        if ["lsl", "lsr", "asr", "ror"].contains(mnemonic) {
            guard operands.count == 3, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]) else { return nil }
            let width: UInt32 = rd.is64 ? 64 : 32
            if operands[2].hasPrefix("#") {
                let amount = UInt32(try parseImmediate(operands[2], lineNumber: lineNumber))
                switch mnemonic {
                case "lsl":
                    let immr = (width - amount) % width
                    let imms = width - 1 - amount
                    return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x5300_0000 | ((rd.is64 ? UInt32(1) : 0) << 22) | (immr << 16) | (imms << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
                case "lsr":
                    return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x5300_0000 | ((rd.is64 ? UInt32(1) : 0) << 22) | (amount << 16) | ((width - 1) << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
                case "asr":
                    return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1300_0000 | ((rd.is64 ? UInt32(1) : 0) << 22) | (amount << 16) | ((width - 1) << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
                default:  // ROR 即値 = EXTR rd, rn, rn, #amount
                    return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1380_0000 | ((rd.is64 ? UInt32(1) : 0) << 22) | (UInt32(rn.number) << 16) | (amount << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
                }
            }
            guard let rmReg = parseRegister(operands[2]) else { return nil }
            let opcode: UInt32 = mnemonic == "lsl" ? 8 : (mnemonic == "lsr" ? 9 : (mnemonic == "asr" ? 10 : 11))
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1AC0_0000 | (UInt32(rmReg.number) << 16) | (opcode << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        if mnemonic == "clz" || mnemonic == "rbit" || mnemonic == "rev" {
            guard operands.count == 2, let rd = parseRegister(operands[0]), let rn = parseRegister(operands[1]) else { return nil }
            // REV は 32 ビット形が opcode 2、64 ビット形が opcode 3
            let opcode: UInt32 = mnemonic == "clz" ? 4 : (mnemonic == "rbit" ? 0 : (rd.is64 ? 3 : 2))
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1AC0_0000 | (1 << 30) | (opcode << 10) | (UInt32(rn.number) << 5) | UInt32(rd.number)
        }
        return nil
    }

    private func encodeMoveImmediate(rd: (number: Int, is64: Bool, isSP: Bool), value: Int64, lineNumber: Int) throws -> UInt32 {
        let raw = UInt64(bitPattern: value)
        let width: UInt64 = rd.is64 ? UInt64.max : 0xFFFF_FFFF
        let v = raw & width
        // 単一の 16 ビットチャンクだけが非ゼロ → MOVZ
        if v == 0 {
            return ((rd.is64 ? UInt32(1) : 0) << 31) | (2 << 29) | 0x1280_0000 | UInt32(rd.number)
        }
        let nonzeroChunks = stride(from: 0, through: rd.is64 ? 48 : 16, by: 16).filter { (v >> $0) & 0xFFFF != 0 }
        if nonzeroChunks.count == 1, let shift = nonzeroChunks.first {
            let imm16 = UInt32((v >> shift) & 0xFFFF)
            return ((rd.is64 ? UInt32(1) : 0) << 31) | (2 << 29) | 0x1280_0000 | (UInt32(shift / 16) << 21) | (imm16 << 5) | UInt32(rd.number)
        }
        // 補数が単一チャンク（補数 0 = オール 1 の場合も含む）→ MOVN
        let inverted = ~v & width
        for shift in stride(from: 0, through: rd.is64 ? 48 : 16, by: 16) {
            if inverted & ~(UInt64(0xFFFF) << shift) == 0 {
                let imm16 = UInt32((inverted >> shift) & 0xFFFF)
                return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1280_0000 | (UInt32(shift / 16) << 21) | (imm16 << 5) | UInt32(rd.number)
            }
        }
        // ADD 即値で表現できる場合（0〜4095、または 12 ビットシフト）
        if v <= 0xFFF {
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1100_0000 | (UInt32(v) << 10) | (31 << 5) | UInt32(rd.number)
        }
        if v & 0xFFF == 0 && (v >> 12) <= 0xFFF {
            return ((rd.is64 ? UInt32(1) : 0) << 31) | 0x1100_0000 | (1 << 22) | (UInt32(v >> 12) << 10) | (31 << 5) | UInt32(rd.number)
        }
        throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "MOV 即値で表現できません（ldr rd, =式 を使ってください）")
    }

    private func encodeAddSubImmediate(rd: Int, rn: Int, imm: Int64, isSub: Bool, setFlags: Bool, is64: Bool = true, lineNumber: Int) throws -> UInt32 {
        var value = imm
        var shift: UInt32 = 0
        if value < 0 {
            // 負数は反転して反対の演算にする
            value = -value
            return try encodeAddSubImmediate(rd: rd, rn: rn, imm: value, isSub: !isSub, setFlags: setFlags, is64: is64, lineNumber: lineNumber)
        }
        if value > 0xFFF {
            guard value & 0xFFF == 0, (value >> 12) <= 0xFFF else {
                throw ARM64AssemblerError.outOfRange(line: lineNumber, message: "即値が範囲外です")
            }
            value >>= 12
            shift = 1
        }
        return ((is64 ? UInt32(1) : 0) << 31) | ((isSub ? UInt32(1) : 0) << 30) | ((setFlags ? UInt32(1) : 0) << 29)
            | 0x1100_0000 | (shift << 22) | (UInt32(value) << 10) | (UInt32(rn) << 5) | UInt32(rd)
    }

    /// ビットマスク即値のエンコード（DecodeBitMasks の逆）。
    private func encodeBitMask(value: UInt64, is64: Bool) -> (n: UInt32, immr: UInt32, imms: UInt32)? {
        let width = is64 ? 64 : 32
        let v = is64 ? value : (value & 0xFFFF_FFFF)
        if v == 0 || v == (width == 64 ? UInt64.max : 0xFFFF_FFFF) { return nil }
        for esize in [64, 32, 16, 8, 4, 2] where esize <= width {
            // 要素サイズで繰り返されているか
            let elementMask: UInt64 = esize == 64 ? UInt64.max : ((UInt64(1) << esize) - 1)
            let element = v & elementMask
            var repeated = true
            var pos = esize
            while pos < width {
                if (v >> pos) & elementMask != element { repeated = false; break }
                pos += esize
            }
            if !repeated { continue }
            // 要素が「回転した連続 1 ビット」か調べる
            let ones = element.nonzeroBitCount
            if ones == 0 || ones == esize { continue }
            let unrotated = (UInt64(1) << ones) - 1
            for rotation in 0..<esize {
                let rotated: UInt64
                if rotation == 0 { rotated = unrotated }
                else { rotated = ((unrotated >> rotation) | (unrotated << (esize - rotation))) & elementMask }
                if rotated == element {
                    let n: UInt32 = esize == 64 ? 1 : 0
                    let lengthBits: UInt32
                    switch esize {
                    case 64: lengthBits = 0
                    case 32: lengthBits = 0b010000
                    case 16: lengthBits = 0b100000
                    case 8: lengthBits = 0b110000
                    case 4: lengthBits = 0b111000
                    default: lengthBits = 0b111100
                    }
                    let imms = lengthBits | UInt32(ones - 1)
                    if !is64 && esize == 64 { continue }
                    return (n, UInt32(rotation), imms)
                }
            }
        }
        return nil
    }
}
