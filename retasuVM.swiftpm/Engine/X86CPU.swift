import Foundation

enum X86Fault: Error, CustomStringConvertible, LocalizedError {
    case unimplementedOpcode(UInt8, address: UInt32)
    case unsupportedPrefix(address: UInt32)
    case memoryOutOfBounds(address: UInt32)
    case divideError(address: UInt32)
    case noInterruptHandler(UInt8)
    case exceptionUndeliverable(UInt8)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unimplementedOpcode(let opcode, let address):
            return String(format: "x86: 未実装の命令 0x%02X（アドレス 0x%05X）", opcode, address)
        case .unsupportedPrefix(let address):
            return String(format: "x86: 未対応のアドレスサイズ prefix（アドレス 0x%05X）", address)
        case .memoryOutOfBounds(let address):
            return String(format: "x86: メモリ範囲外アクセス（アドレス 0x%X）", address)
        case .divideError(let address):
            return String(format: "x86: ゼロ除算または商オーバーフロー（アドレス 0x%05X）", address)
        case .noInterruptHandler(let vector):
            return String(format: "x86: BIOS が接続されていない割り込み INT %02Xh", vector)
        case .exceptionUndeliverable(let vector):
            return String(format: "x86: 例外 %02Xh を配送できませんでした（IDT 未設定）", vector)
        }
    }
}

/// 自作の x86 CPU エミュレータ（リアルモード + 32 ビット プロテクトモード）。
///
/// BIOS ブートしたゲスト（ブートセクタ、El Torito 対応 ISO の起動コード、
/// リアルモードで動作する小さな OS）に加え、GDT / IDT を使う 32 ビット
/// プロテクトモードのコード（ページング、例外配送、Multiboot カーネル）を
/// 実行できる。リアルモードの割り込み（INT 命令）はホスト側の BIOS
/// サービス（`X86BIOS`）へ委譲し、プロテクトモードでは IDT のゲートを
/// 使う。シリアルポート（COM1: 0x3F8）はコンソールへ接続されている。
///
/// 対象外: ロングモード、タスクスイッチ（TSS 切り替え）、ユーザーモード
/// （特権レベルはリング 0 のみ）、浮動小数点。これらに当たると
/// `X86Fault` で停止する。
final class X86CPU {
    /// レジスタ番号（x86 エンコーディング順）: 0=EAX 1=ECX 2=EDX 3=EBX 4=ESP 5=EBP 6=ESI 7=EDI
    private(set) var registers: [UInt32] = [UInt32](repeating: 0, count: 8)
    /// セグメントレジスタ（0=ES 1=CS 2=SS 3=DS 4=FS 5=GS）
    private(set) var segments: [UInt16] = [UInt16](repeating: 0, count: 6)
    private(set) var instructionPointer: UInt32 = 0
    private(set) var flags: UInt32 = 0x0002

    private(set) var memory: [UInt8]
    private(set) var halted = false
    private(set) var exitCode: Int32 = 0
    private(set) var waitingForInput = false
    private(set) var instructionsExecuted: UInt64 = 0

    var onChar: ((UInt8) -> Void)?
    var onClearScreen: (() -> Void)?

    /// INT 命令の処理結果。needsInput のときは IP を進めずに入力待ちになる。
    enum InterruptOutcome {
        case handled
        case needsInput
    }

    /// BIOS サービスへの委譲先（X86BIOS が設定する）。
    var interruptHandler: ((UInt8) -> InterruptOutcome)?

    private var inputQueue: [UInt8] = []

    // MARK: プロテクトモード状態

    /// セグメントディスクリプタの隠しキャッシュ（base / limit / 属性）。
    struct SegmentCache {
        var base: UInt32 = 0
        var limit: UInt32 = 0xFFFF
        /// コードセグメントなら既定オペランドサイズ、データならスタック幅（B ビット）。
        var defaultSize32 = false
        var present = true
        var isCode = false
        var isExpandDown = false
        var permitsRead = true
        var permitsWrite = true
    }

    /// コントロールレジスタ（CR0 / CR2 / CR3 / CR4 を使用）。
    private(set) var controlRegisters: [UInt32] = [UInt32](repeating: 0, count: 8)
    private var gdtrBase: UInt32 = 0
    private var gdtrLimit: UInt16 = 0
    private var idtrBase: UInt32 = 0
    private var idtrLimit: UInt16 = 0xFFFF
    private var ldtrSelector: UInt16 = 0
    private var ldtrCache = SegmentCache()
    private var taskRegister: UInt16 = 0
    private(set) var segmentCaches: [SegmentCache] = [SegmentCache](repeating: SegmentCache(), count: 6)

    var protectedMode: Bool { controlRegisters[0] & 0x00000001 != 0 }
    var pagingEnabled: Bool { protectedMode && controlRegisters[0] & 0x80000000 != 0 }

    /// CPU 内部で発生した例外（IDT へ配送するため step 内で捕捉する）。
    private enum CPUTrap: Error {
        case exception(vector: UInt8, errorCode: UInt32?)
    }

    // フラグビット
    static let flagCarry: UInt32 = 0x0001
    static let flagParity: UInt32 = 0x0004
    static let flagAuxCarry: UInt32 = 0x0010
    static let flagZero: UInt32 = 0x0040
    static let flagSign: UInt32 = 0x0080
    static let flagTrap: UInt32 = 0x0100
    static let flagInterrupt: UInt32 = 0x0200
    static let flagDirection: UInt32 = 0x0400
    static let flagOverflow: UInt32 = 0x0800

    init(memorySize: Int = 16 << 20) {
        memory = [UInt8](repeating: 0, count: memorySize)
    }

    // MARK: - 公開操作

    /// メモリへデータを配置する（ブートセクタの読み込みなど）。
    func loadData(_ data: [UInt8], at address: Int) {
        guard address >= 0, address + data.count <= memory.count else { return }
        memory.replaceSubrange(address..<(address + data.count), with: data)
    }

    /// CPU 状態を初期位置へ設定する（BIOS ブート用）。
    func resetForBoot(bootDrive: UInt8) {
        registers = [UInt32](repeating: 0, count: 8)
        segments = [UInt16](repeating: 0, count: 6)
        instructionPointer = 0x7C00
        flags = 0x0002
        halted = false
        exitCode = 0
        waitingForInput = false
        controlRegisters = [UInt32](repeating: 0, count: 8)
        gdtrBase = 0
        gdtrLimit = 0
        idtrBase = 0
        idtrLimit = 0xFFFF
        ldtrSelector = 0
        ldtrCache = SegmentCache()
        taskRegister = 0
        segmentCaches = [SegmentCache](repeating: SegmentCache(), count: 6)
        setRegister16(4, 0x7C00) // SP
        setRegister8(2, bootDrive) // DL = ブートドライブ
    }

    /// Multiboot 仕様の初期状態にする（フラット GDT を用意し、プロテクト
    /// モードでカーネルのエントリへ入る）。`Multiboot` ローダから使う。
    func prepareMultibootEntry(entry: UInt32, infoAddress: UInt32, stackTop: UInt32) {
        resetForBoot(bootDrive: 0)
        // GDT を 0x0800 に置く: null / コード (0x08) / データ (0x10)、いずれも base 0・limit 4 GiB
        var gdt = [UInt8](repeating: 0, count: 24)
        let code: [UInt8] = [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00]
        let data: [UInt8] = [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00]
        gdt.replaceSubrange(8..<16, with: code)
        gdt.replaceSubrange(16..<24, with: data)
        loadData(gdt, at: 0x0800)
        gdtrBase = 0x0800
        gdtrLimit = 23
        controlRegisters[0] = 0x00000011 // PE + ET（ページング無効）
        let flatCode = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: true, present: true, isCode: true, isExpandDown: false, permitsRead: true, permitsWrite: false)
        let flatData = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: true, present: true, isCode: false, isExpandDown: false, permitsRead: true, permitsWrite: true)
        segments[1] = 0x08
        segmentCaches[1] = flatCode
        for index in [0, 2, 3, 4, 5] {
            segments[index] = 0x10
            segmentCaches[index] = flatData
        }
        instructionPointer = entry
        registers[4] = stackTop // ESP
        registers[0] = 0x2BADB002 // EAX: Multiboot マジック
        registers[3] = infoAddress // EBX: Multiboot 情報構造体
        flags = 0x0002 // 割り込み無効
    }

    /// ゲストを停止させる（BIOS のブート失敗・電源断に相当）。
    func halt(exitCode: Int32) {
        halted = true
        self.exitCode = exitCode
    }

    /// コンソール入力をキューへ追加する。
    func provideInput(_ bytes: [UInt8]) {
        inputQueue.append(contentsOf: bytes)
        if !bytes.isEmpty { waitingForInput = false }
    }

    /// 入力を 1 バイト取り出す（無ければ nil）。BIOS のキーボード処理から使う。
    func nextInputByte() -> UInt8? {
        inputQueue.isEmpty ? nil : inputQueue.removeFirst()
    }

    /// 入力を先読みする（取り出さない）。
    func peekInputByte() -> UInt8? {
        inputQueue.first
    }

    var hasInput: Bool { !inputQueue.isEmpty }

    /// 最大で指定した命令数だけ実行する。停止・入力待ちで早期に返る。
    func run(maxInstructions: Int) throws {
        var count = 0
        while !halted && !waitingForInput && count < maxInstructions {
            try step()
            count += 1
            instructionsExecuted += 1
        }
    }

    // MARK: - レジスタアクセス

    func register32(_ index: Int) -> UInt32 { registers[index] }
    func register16(_ index: Int) -> UInt16 { UInt16(registers[index] & 0xFFFF) }
    func register8(_ index: Int) -> UInt8 {
        if index < 4 { return UInt8(registers[index] & 0xFF) }
        return UInt8((registers[index - 4] >> 8) & 0xFF)
    }

    func setRegister32(_ index: Int, _ value: UInt32) { registers[index] = value }
    func setRegister16(_ index: Int, _ value: UInt16) {
        registers[index] = (registers[index] & 0xFFFF0000) | UInt32(value)
    }
    func setRegister8(_ index: Int, _ value: UInt8) {
        if index < 4 {
            registers[index] = (registers[index] & 0xFFFFFF00) | UInt32(value)
        } else {
            registers[index - 4] = (registers[index - 4] & 0xFFFF00FF) | (UInt32(value) << 8)
        }
    }

    func segment(_ index: Int) -> UInt16 { segments[index] }

    /// ホスト（BIOS）からのセグメント設定。リアルモード前提で、隠し
    /// キャッシュも実モードの値（base = 値 × 16、limit = 64 KiB）に保つ。
    func setSegment(_ index: Int, _ value: UInt16) {
        segments[index] = value
        if !protectedMode {
            segmentCaches[index] = SegmentCache(base: UInt32(value) << 4, limit: 0xFFFF, defaultSize32: false, present: true, isCode: index == 1, isExpandDown: false, permitsRead: true, permitsWrite: true)
        }
    }

    func setInstructionPointer(_ value: UInt32) { instructionPointer = value }
    func setFlags(_ value: UInt32) { flags = value | 0x0002 }

    /// 現在の CS に適用される IP のマスク（32 ビット CS なら全幅）。
    var ipMask: UInt32 { segmentCaches[1].defaultSize32 ? 0xFFFFFFFF : 0xFFFF }

    // MARK: - ディスクリプタ

    /// GDT / LDT からディスクリプタを読み、検証済みキャッシュへ変換する。
    private func descriptorCache(selector: UInt16) throws -> SegmentCache {
        let tableBase: UInt32
        let tableLimit: UInt32
        if selector & 0x0004 != 0 {
            tableBase = ldtrCache.base
            tableLimit = ldtrCache.limit
        } else {
            tableBase = gdtrBase
            tableLimit = UInt32(gdtrLimit)
        }
        let offset = UInt32(selector & 0xFFF8)
        guard offset + 7 <= tableLimit else {
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        let address = Int(tableBase + offset)
        let low = try readMemory(at: address, size: 4)
        let high = try readMemory(at: address + 4, size: 4)
        let limitLow = low & 0xFFFF
        let baseLow = (low >> 16) & 0xFFFF
        let baseMiddle = high & 0xFF
        let access = (high >> 8) & 0xFF
        let limitHigh = (high >> 16) & 0x0F
        let granularity = (high >> 20) & 0x0F
        let baseHigh = (high >> 24) & 0xFF
        var limit = (limitHigh << 16) | limitLow
        if granularity & 0x8 != 0 { limit = (limit << 12) | 0xFFF } // G ビット: 4 KiB 単位
        let base = baseLow | (baseMiddle << 16) | (baseHigh << 24)
        let isSystem = access & 0x10 == 0
        let type = access & 0x0F
        return SegmentCache(
            base: base,
            limit: limit,
            defaultSize32: granularity & 0x4 != 0,
            present: access & 0x80 != 0,
            isCode: !isSystem && type & 0x8 != 0,
            isExpandDown: !isSystem && type & 0x8 == 0 && type & 0x4 != 0,
            permitsRead: isSystem ? false : (type & 0x8 == 0 || type & 0x2 != 0),
            permitsWrite: isSystem ? false : (type & 0x8 == 0 && type & 0x2 != 0)
        )
    }

    /// ゲスト命令によるセグメントレジスタのロード。プロテクトモードでは
    /// ディスクリプタを検証する（CS は far 転送専用のためここでは扱わない）。
    func loadSegmentRegister(_ index: Int, _ selector: UInt16) throws {
        guard protectedMode else {
            setSegment(index, selector)
            return
        }
        if selector & 0xFFF8 == 0 {
            // NULL セレクタ: DS / ES / FS / GS は使用不可としてマークする
            if index == 1 || index == 2 {
                throw CPUTrap.exception(vector: 13, errorCode: 0)
            }
            segments[index] = selector
            segmentCaches[index] = SegmentCache(base: 0, limit: 0, defaultSize32: false, present: false, isCode: false, isExpandDown: false, permitsRead: false, permitsWrite: false)
            return
        }
        let cache = try descriptorCache(selector: selector)
        guard cache.present, !cache.isCode || cache.permitsRead else {
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        if index == 2 && (cache.isCode || !cache.permitsWrite) {
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        segments[index] = selector
        segmentCaches[index] = cache
    }

    /// far ジャンプ / コール / リターンで CS をロードする。
    func loadCodeSegment(_ selector: UInt16) throws {
        guard protectedMode else {
            setSegment(1, selector)
            return
        }
        guard selector & 0xFFF8 != 0 else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
        let cache = try descriptorCache(selector: selector)
        guard cache.present, cache.isCode else {
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        segments[1] = selector
        segmentCaches[1] = cache
    }

    func flag(_ bit: UInt32) -> Bool { flags & bit != 0 }
    func setFlag(_ bit: UInt32, _ on: Bool) {
        flags = on ? (flags | bit) : (flags & ~bit)
    }

    // MARK: - メモリアクセス

    func physicalAddress(segment: UInt16, offset: UInt32) -> Int {
        (Int(segment) << 4) + Int(offset)
    }

    func readMemory8(at address: Int) throws -> UInt8 {
        guard address >= 0, address < memory.count else {
            throw X86Fault.memoryOutOfBounds(address: UInt32(bitPattern: Int32(address)))
        }
        return memory[address]
    }

    func writeMemory8(at address: Int, _ value: UInt8) throws {
        guard address >= 0, address < memory.count else {
            throw X86Fault.memoryOutOfBounds(address: UInt32(bitPattern: Int32(address)))
        }
        memory[address] = value
    }

    func readMemory(at address: Int, size: Int) throws -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<size {
            value |= UInt32(try readMemory8(at: address + i)) << (8 * i)
        }
        return value
    }

    func writeMemory(at address: Int, size: Int, _ value: UInt32) throws {
        for i in 0..<size {
            try writeMemory8(at: address + i, UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    // MARK: - ゲストメモリアクセス（セグメント変換 + ページング）

    /// セグメントキャッシュ経由のリニアアドレスを求める。
    func linearAddress(segmentIndex: Int, offset: UInt32) -> UInt32 {
        segmentCaches[segmentIndex].base &+ offset
    }

    /// プロテクトモード時のセグメント範囲・権限チェック。
    private func checkSegmentAccess(_ segmentIndex: Int, offset: UInt32, size: Int, isWrite: Bool) throws {
        guard protectedMode else { return }
        let cache = segmentCaches[segmentIndex]
        let errorCode = UInt32(segments[segmentIndex] & 0xFFFC)
        guard cache.present else { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        if isWrite && !cache.permitsWrite { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        if !isWrite && !cache.permitsRead && !cache.isCode { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        let last = offset &+ UInt32(size - 1)
        if cache.isExpandDown {
            let floor = cache.limit &+ 1
            let ceiling: UInt32 = cache.defaultSize32 ? 0xFFFFFFFF : 0xFFFF
            if offset < floor || last > ceiling { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        } else if last > cache.limit {
            throw CPUTrap.exception(vector: 13, errorCode: errorCode)
        }
    }

    /// ページング変換（線形 → 物理）。ページ不在などは #PF を送出する。
    private func translate(linear: UInt32, isWrite: Bool, isFetch: Bool) throws -> Int {
        guard pagingEnabled else {
            guard linear < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
            return Int(linear)
        }
        let directoryBase = controlRegisters[3] & 0xFFFFF000
        let directoryIndex = (linear >> 22) & 0x3FF
        let pdeAddress = Int(directoryBase + directoryIndex * 4)
        var pde = try readMemory(at: pdeAddress, size: 4)
        func pageFault(present: Bool) -> CPUTrap {
            controlRegisters[2] = linear
            var code: UInt32 = 0
            if present { code |= 0x01 }
            if isWrite { code |= 0x02 }
            if isFetch { code |= 0x10 }
            return .exception(vector: 14, errorCode: code)
        }
        guard pde & 1 != 0 else { throw pageFault(present: false) }
        if pde & 0x80 != 0 {
            // 4 MiB ページ（PSE）
            if pde & 0x20 == 0 || (isWrite && pde & 0x40 == 0) {
                pde |= 0x20
                if isWrite { pde |= 0x40 }
                try writeMemory(at: pdeAddress, size: 4, pde)
            }
            let physical = Int((pde & 0xFFC00000) | (linear & 0x3FFFFF))
            guard physical < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
            return physical
        }
        let tableIndex = (linear >> 12) & 0x3FF
        let pteAddress = Int((pde & 0xFFFFF000) + tableIndex * 4)
        var pte = try readMemory(at: pteAddress, size: 4)
        guard pte & 1 != 0 else { throw pageFault(present: false) }
        if pde & 0x20 == 0 {
            try writeMemory(at: pdeAddress, size: 4, pde | 0x20)
        }
        if pte & 0x20 == 0 || (isWrite && pte & 0x40 == 0) {
            pte |= 0x20
            if isWrite { pte |= 0x40 }
            try writeMemory(at: pteAddress, size: 4, pte)
        }
        let physical = Int((pte & 0xFFFFF000) | (linear & 0xFFF))
        guard physical < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
        return physical
    }

    /// ゲストのデータ読み取り（セグメント + ページング適用）。
    func readGuest(segmentIndex: Int, offset: UInt32, size: Int) throws -> UInt32 {
        try checkSegmentAccess(segmentIndex, offset: offset, size: size, isWrite: false)
        var value: UInt32 = 0
        for i in 0..<size {
            let physical = try translate(linear: linearAddress(segmentIndex: segmentIndex, offset: offset &+ UInt32(i)), isWrite: false, isFetch: false)
            value |= UInt32(memory[physical]) << (8 * i)
        }
        return value
    }

    /// ゲストのデータ書き込み（セグメント + ページング適用）。
    func writeGuest(segmentIndex: Int, offset: UInt32, size: Int, _ value: UInt32) throws {
        try checkSegmentAccess(segmentIndex, offset: offset, size: size, isWrite: true)
        for i in 0..<size {
            let physical = try translate(linear: linearAddress(segmentIndex: segmentIndex, offset: offset &+ UInt32(i)), isWrite: true, isFetch: false)
            memory[physical] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }

    /// 物理メモリの直接読み取り（ページテーブル走査・ホスト処理用）。
    func readPhysical(at address: Int, size: Int) throws -> UInt32 {
        try readMemory(at: address, size: size)
    }

    // MARK: - フェッチ

    private func fetch8() throws -> UInt8 {
        if protectedMode && instructionPointer > segmentCaches[1].limit {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
        let physical = try translate(linear: linearAddress(segmentIndex: 1, offset: instructionPointer), isWrite: false, isFetch: true)
        let value = memory[physical]
        instructionPointer = (instructionPointer + 1) & ipMask
        return value
    }

    private func fetch16() throws -> UInt16 {
        let low = UInt16(try fetch8())
        let high = UInt16(try fetch8())
        return low | (high << 8)
    }

    private func fetch32() throws -> UInt32 {
        let low = UInt32(try fetch16())
        let high = UInt32(try fetch16())
        return low | (high << 16)
    }

    private func fetchSigned8() throws -> Int8 { Int8(bitPattern: try fetch8()) }

    // MARK: - デコード補助

    private var decodeOperandSize = 2
    private var decodeAddressSize = 2
    private var decodeSegmentOverride: Int?

    private struct ModRM {
        var reg: Int
        var isRegister: Bool
        var registerIndex: Int
        var segmentIndex: Int
        /// セグメント内のオフセット（LEA 用）
        var effectiveOffset: UInt32
    }

    /// ModR/M バイトを読み、実効アドレス（セグメント内オフセット）を解決する。
    private func decodeModRM() throws -> ModRM {
        let byte = try fetch8()
        let mod = Int(byte >> 6)
        let reg = Int((byte >> 3) & 7)
        let rm = Int(byte & 7)
        if mod == 3 {
            return ModRM(reg: reg, isRegister: true, registerIndex: rm, segmentIndex: 3, effectiveOffset: 0)
        }
        if decodeAddressSize == 4 {
            return try decodeModRM32(mod: mod, reg: reg, rm: rm)
        }
        var offset: UInt32 = 0
        var defaultSegment = 3 // DS
        switch rm {
        case 0: offset = UInt32(register16(3)) &+ UInt32(register16(6))
        case 1: offset = UInt32(register16(3)) &+ UInt32(register16(7))
        case 2: offset = UInt32(register16(5)) &+ UInt32(register16(6)); defaultSegment = 2
        case 3: offset = UInt32(register16(5)) &+ UInt32(register16(7)); defaultSegment = 2
        case 4: offset = UInt32(register16(6))
        case 5: offset = UInt32(register16(7))
        case 6:
            if mod == 0 {
                offset = UInt32(try fetch16())
            } else {
                offset = UInt32(register16(5)); defaultSegment = 2
            }
        case 7: offset = UInt32(register16(3))
        default: break
        }
        if mod == 1 {
            let displacement = Int8(bitPattern: try fetch8())
            offset = (offset &+ UInt32(bitPattern: Int32(displacement))) & 0xFFFF
        } else if mod == 2 {
            let displacement = Int16(bitPattern: try fetch16())
            offset = (offset &+ UInt32(bitPattern: Int32(displacement))) & 0xFFFF
        }
        let segmentIndex = decodeSegmentOverride ?? defaultSegment
        return ModRM(reg: reg, isRegister: false, registerIndex: rm, segmentIndex: segmentIndex, effectiveOffset: offset)
    }

    /// 32 ビットアドレッシングの ModR/M（SIB バイト対応）。
    private func decodeModRM32(mod: Int, reg: Int, rm: Int) throws -> ModRM {
        var offset: UInt32 = 0
        var defaultSegment = 3 // DS
        if rm == 4 {
            // SIB バイト
            let sib = try fetch8()
            let scale = Int(sib >> 6)
            let index = Int((sib >> 3) & 7)
            let base = Int(sib & 7)
            if index != 4 {
                offset = offset &+ (registers[index] &<< scale)
            }
            if base == 5 && mod == 0 {
                offset = offset &+ (try fetch32())
            } else {
                offset = offset &+ registers[base]
                if base == 5 { defaultSegment = 2 } // EBP ベースは SS
            }
        } else if rm == 5 && mod == 0 {
            offset = try fetch32()
        } else {
            offset = registers[rm]
            if rm == 5 { defaultSegment = 2 } // EBP は SS
        }
        if mod == 1 {
            let displacement = Int8(bitPattern: try fetch8())
            offset = offset &+ UInt32(bitPattern: Int32(displacement))
        } else if mod == 2 {
            offset = offset &+ (try fetch32())
        }
        let segmentIndex = decodeSegmentOverride ?? defaultSegment
        return ModRM(reg: reg, isRegister: false, registerIndex: rm, segmentIndex: segmentIndex, effectiveOffset: offset)
    }

    private func readOperand(_ operand: ModRM, size: Int) throws -> UInt32 {
        if operand.isRegister {
            return size == 1 ? UInt32(register8(operand.registerIndex)) : (size == 2 ? UInt32(register16(operand.registerIndex)) : register32(operand.registerIndex))
        }
        return try readGuest(segmentIndex: operand.segmentIndex, offset: operand.effectiveOffset, size: size)
    }

    private func writeOperand(_ operand: ModRM, size: Int, _ value: UInt32) throws {
        if operand.isRegister {
            if size == 1 { setRegister8(operand.registerIndex, UInt8(value & 0xFF)) }
            else if size == 2 { setRegister16(operand.registerIndex, UInt16(value & 0xFFFF)) }
            else { setRegister32(operand.registerIndex, value) }
        } else {
            try writeGuest(segmentIndex: operand.segmentIndex, offset: operand.effectiveOffset, size: size, value)
        }
    }

    // MARK: - フラグ計算

    private func mask(forSize size: Int) -> UInt32 {
        size == 1 ? 0xFF : (size == 2 ? 0xFFFF : 0xFFFFFFFF)
    }

    private func setSignZeroParity(_ result: UInt32, size: Int) {
        let value = result & mask(forSize: size)
        setFlag(Self.flagSign, value & (UInt32(1) << (size * 8 - 1)) != 0)
        setFlag(Self.flagZero, value == 0)
        setFlag(Self.flagParity, (value & 0xFF).nonzeroBitCount % 2 == 0)
    }

    /// 加算系（ADD / ADC）のフラグを更新して結果を返す。
    private func addWithFlags(_ a: UInt32, _ b: UInt32, size: Int, carryIn: Bool) -> UInt32 {
        let m = mask(forSize: size)
        let full = UInt64(a & m) + UInt64(b & m) + (carryIn ? 1 : 0)
        let result = UInt32(full) & m
        setFlag(Self.flagCarry, full > UInt64(m))
        let signBit = UInt32(1) << (size * 8 - 1)
        setFlag(Self.flagOverflow, ((~(a ^ b) & (a ^ result)) & signBit) != 0)
        setFlag(Self.flagAuxCarry, ((a ^ b ^ result) & 0x10) != 0)
        setSignZeroParity(result, size: size)
        return result
    }

    /// 減算系（SUB / SBB / CMP）のフラグを更新して結果を返す。
    private func subtractWithFlags(_ a: UInt32, _ b: UInt32, size: Int, borrowIn: Bool) -> UInt32 {
        let m = mask(forSize: size)
        let subtrahend = UInt64(b & m) + (borrowIn ? 1 : 0)
        let result = (a & m) &- UInt32(truncatingIfNeeded: subtrahend)
        let resultMasked = result & m
        setFlag(Self.flagCarry, UInt64(a & m) < subtrahend)
        let signBit = UInt32(1) << (size * 8 - 1)
        setFlag(Self.flagOverflow, (((a ^ b) & (a ^ resultMasked)) & signBit) != 0)
        setFlag(Self.flagAuxCarry, ((a ^ b ^ resultMasked) & 0x10) != 0)
        setSignZeroParity(resultMasked, size: size)
        return resultMasked
    }

    /// 論理演算のフラグ（CF / OF はクリア）。
    private func logicFlags(_ result: UInt32, size: Int) -> UInt32 {
        setFlag(Self.flagCarry, false)
        setFlag(Self.flagOverflow, false)
        setFlag(Self.flagAuxCarry, false)
        setSignZeroParity(result, size: size)
        return result & mask(forSize: size)
    }

    /// ALU 演算。operation: 0=ADD 1=OR 2=ADC 3=SBB 4=AND 5=SUB 6=XOR 7=CMP
    private func alu(_ operation: Int, _ a: UInt32, _ b: UInt32, size: Int) -> UInt32 {
        switch operation {
        case 0: return addWithFlags(a, b, size: size, carryIn: false)
        case 1: return logicFlags(a | b, size: size)
        case 2: return addWithFlags(a, b, size: size, carryIn: flag(Self.flagCarry))
        case 3: return subtractWithFlags(a, b, size: size, borrowIn: flag(Self.flagCarry))
        case 4: return logicFlags(a & b, size: size)
        case 5: return subtractWithFlags(a, b, size: size, borrowIn: false)
        case 6: return logicFlags(a ^ b, size: size)
        case 7: return subtractWithFlags(a, b, size: size, borrowIn: false)
        default: return a
        }
    }

    /// 条件コード（Jcc の下位 4 ビット）を評価する。
    private func condition(_ index: Int) -> Bool {
        switch index {
        case 0: return flag(Self.flagOverflow)
        case 1: return !flag(Self.flagOverflow)
        case 2: return flag(Self.flagCarry)
        case 3: return !flag(Self.flagCarry)
        case 4: return flag(Self.flagZero)
        case 5: return !flag(Self.flagZero)
        case 6: return flag(Self.flagCarry) || flag(Self.flagZero)
        case 7: return !flag(Self.flagCarry) && !flag(Self.flagZero)
        case 8: return flag(Self.flagSign)
        case 9: return !flag(Self.flagSign)
        case 10: return flag(Self.flagParity)
        case 11: return !flag(Self.flagParity)
        case 12: return flag(Self.flagSign) != flag(Self.flagOverflow)
        case 13: return flag(Self.flagSign) == flag(Self.flagOverflow)
        case 14: return flag(Self.flagZero) || (flag(Self.flagSign) != flag(Self.flagOverflow))
        default: return !flag(Self.flagZero) && (flag(Self.flagSign) == flag(Self.flagOverflow))
        }
    }

    // MARK: - スタック

    /// 現在のスタックポインタ（SS の B ビットが立っていれば ESP、全幅）。
    private var stackPointer: UInt32 {
        segmentCaches[2].defaultSize32 ? registers[4] : UInt32(register16(4))
    }

    private func setStackPointer(_ value: UInt32) {
        if segmentCaches[2].defaultSize32 {
            registers[4] = value
        } else {
            setRegister16(4, UInt16(value & 0xFFFF))
        }
    }

    private func push(_ value: UInt32, size: Int) throws {
        let newPointer = stackPointer &- UInt32(size)
        setStackPointer(newPointer)
        try writeGuest(segmentIndex: 2, offset: newPointer, size: size, value)
    }

    private func pop(size: Int) throws -> UInt32 {
        let pointer = stackPointer
        let value = try readGuest(segmentIndex: 2, offset: pointer, size: size)
        setStackPointer(pointer &+ UInt32(size))
        return value
    }

    // MARK: - シフト / ローテート

    /// kind: 0=ROL 1=ROR 2=RCL 3=RCR 4=SHL 5=SHR 7=SAR
    private func shift(_ kind: Int, _ value: UInt32, _ rawCount: Int, size: Int) -> UInt32 {
        let m = mask(forSize: size)
        let v = value & m
        let count = rawCount & 31
        if count == 0 { return v }
        let bits = size * 8
        var result: UInt32 = v
        var carry = flag(Self.flagCarry)
        switch kind {
        case 0: // ROL
            let c = count % bits
            result = c == 0 ? v : ((v << c) | (v >> (bits - c))) & m
            carry = result & 1 != 0
            setFlag(Self.flagCarry, carry)
            if count == 1 { setFlag(Self.flagOverflow, ((result >> (bits - 1)) & 1 != 0) != carry) }
        case 1: // ROR
            let c = count % bits
            result = c == 0 ? v : ((v >> c) | (v << (bits - c))) & m
            carry = (result >> (bits - 1)) & 1 != 0
            setFlag(Self.flagCarry, carry)
            if count == 1 { setFlag(Self.flagOverflow, ((result >> (bits - 1)) & 1) != ((result >> (bits - 2)) & 1)) }
        case 2, 3: // RCL / RCR（キャリー込みローテートは 1 ビットずつ処理）
            var current = v
            for _ in 0..<count {
                if kind == 2 {
                    let newCarry = (current >> (bits - 1)) & 1 != 0
                    current = ((current << 1) | (carry ? 1 : 0)) & m
                    carry = newCarry
                } else {
                    let newCarry = current & 1 != 0
                    current = (current >> 1) | (carry ? (UInt32(1) << (bits - 1)) : 0)
                    carry = newCarry
                }
            }
            result = current
            setFlag(Self.flagCarry, carry)
            if count == 1 {
                setFlag(Self.flagOverflow, kind == 2 ? (((result >> (bits - 1)) & 1 != 0) != carry) : (((result >> (bits - 1)) & 1) != ((result >> (bits - 2)) & 1)))
            }
        case 4, 6: // SHL / SAL
            if count >= bits {
                result = 0
                setFlag(Self.flagCarry, false)
            } else {
                setFlag(Self.flagCarry, (v >> (bits - count)) & 1 != 0)
                result = (v << count) & m
            }
            if count == 1 { setFlag(Self.flagOverflow, ((result >> (bits - 1)) & 1 != 0) != flag(Self.flagCarry)) }
            setSignZeroParity(result, size: size)
        case 5: // SHR
            if count >= bits {
                result = 0
                setFlag(Self.flagCarry, count == bits ? ((v >> (bits - 1)) & 1 != 0) : false)
            } else {
                setFlag(Self.flagCarry, (v >> (count - 1)) & 1 != 0)
                result = v >> count
            }
            if count == 1 { setFlag(Self.flagOverflow, (v >> (bits - 1)) & 1 != 0) }
            setSignZeroParity(result, size: size)
        case 7: // SAR
            let signed: Int32 = size == 1 ? Int32(Int8(bitPattern: UInt8(v))) : (size == 2 ? Int32(Int16(bitPattern: UInt16(v))) : Int32(bitPattern: v))
            if count >= bits {
                result = signed < 0 ? m : 0
                setFlag(Self.flagCarry, signed < 0)
            } else {
                setFlag(Self.flagCarry, count == 0 ? carry : ((v >> (count - 1)) & 1 != 0))
                result = UInt32(bitPattern: signed >> count) & m
            }
            if count == 1 { setFlag(Self.flagOverflow, false) }
            setSignZeroParity(result, size: size)
        default:
            break
        }
        return result & m
    }

    // MARK: - 実行

    private func fetchImmediate(_ size: Int) throws -> UInt32 {
        switch size {
        case 1: return UInt32(try fetch8())
        case 2: return UInt32(try fetch16())
        default: return try fetch32()
        }
    }

    private func incrementWithFlags(_ value: UInt32, size: Int, decrement: Bool) -> UInt32 {
        let savedCarry = flag(Self.flagCarry)
        let result = decrement
            ? subtractWithFlags(value, 1, size: size, borrowIn: false)
            : addWithFlags(value, 1, size: size, carryIn: false)
        setFlag(Self.flagCarry, savedCarry)
        return result
    }

    /// 1 命令を実行する。プロテクトモードで例外が発生したら IDT へ配送する。
    private func step() throws {
        let startIP = instructionPointer
        do {
            try stepDecode(startIP: startIP)
        } catch let trap as CPUTrap {
            switch trap {
            case .exception(let vector, let errorCode):
                do {
                    try dispatchGate(vector: vector, errorCode: errorCode, returnIP: startIP)
                } catch is CPUTrap {
                    throw X86Fault.exceptionUndeliverable(vector)
                }
            }
        }
    }

    private func stepDecode(startIP: UInt32) throws {
        let defaultSize = segmentCaches[1].defaultSize32 ? 4 : 2
        var operandSize = defaultSize
        var addressSize = defaultSize
        var segmentOverride: Int?
        var repeatPrefix: UInt8 = 0
        while true {
            let byte = try fetch8()
            switch byte {
            case 0x66: operandSize = operandSize == 2 ? 4 : 2
            case 0x67: addressSize = addressSize == 2 ? 4 : 2
            case 0x26: segmentOverride = 0
            case 0x2E: segmentOverride = 1
            case 0x36: segmentOverride = 2
            case 0x3E: segmentOverride = 3
            case 0x64: segmentOverride = 4
            case 0x65: segmentOverride = 5
            case 0xF2: repeatPrefix = 0xF2
            case 0xF3: repeatPrefix = 0xF3
            case 0xF0: continue
            default:
                decodeOperandSize = operandSize
                decodeAddressSize = addressSize
                decodeSegmentOverride = segmentOverride
                try execute(opcode: byte, operandSize: operandSize, repeatPrefix: repeatPrefix, startIP: startIP)
                return
            }
        }
    }

    /// IDT ゲート経由で割り込み / 例外を配送する（プロテクトモード用）。
    private func dispatchGate(vector: UInt8, errorCode: UInt32?, returnIP: UInt32) throws {
        let entryOffset = UInt32(vector) * 8
        guard entryOffset + 7 <= UInt32(idtrLimit) else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let address = Int(idtrBase + entryOffset)
        let low = try readMemory(at: address, size: 4)
        let high = try readMemory(at: address + 4, size: 4)
        let access = (high >> 8) & 0xFF
        let gateType = access & 0x1F
        guard access & 0x80 != 0, gateType == 0xE || gateType == 0xF || gateType == 0x6 || gateType == 0x7 else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let selector = UInt16((low >> 16) & 0xFFFF)
        let is32BitGate = gateType == 0xE || gateType == 0xF
        let offset: UInt32 = is32BitGate ? ((high & 0xFFFF0000) | (low & 0xFFFF)) : (low & 0xFFFF)
        let size = is32BitGate ? 4 : 2
        let savedFlags = flags
        let savedCS = segments[1]
        try loadCodeSegment(selector)
        try push(savedFlags, size: size)
        try push(UInt32(savedCS), size: size)
        try push(returnIP, size: size)
        if let errorCode {
            try push(errorCode, size: size)
        }
        if gateType == 0xE || gateType == 0x6 {
            setFlag(Self.flagInterrupt, false)
        }
        instructionPointer = offset & ipMask
    }

    private func execute(opcode: UInt8, operandSize: Int, repeatPrefix: UInt8, startIP: UInt32) throws {
        let address = linearAddress(segmentIndex: 1, offset: startIP)

        // ALU グリッド（0x00〜0x3D）とセグメント push/pop、BCD 補正
        if opcode <= 0x3D {
            switch opcode {
            case 0x06: try push(UInt32(segments[0]), size: operandSize); return
            case 0x07: try loadSegmentRegister(0, UInt16(try pop(size: operandSize) & 0xFFFF)); return
            case 0x0E: try push(UInt32(segments[1]), size: operandSize); return
            case 0x16: try push(UInt32(segments[2]), size: operandSize); return
            case 0x17: try loadSegmentRegister(2, UInt16(try pop(size: operandSize) & 0xFFFF)); return
            case 0x1E: try push(UInt32(segments[3]), size: operandSize); return
            case 0x1F: try loadSegmentRegister(3, UInt16(try pop(size: operandSize) & 0xFFFF)); return
            case 0x27, 0x2F, 0x37, 0x3F: executeBCDAdjust(opcode); return
            default: break
            }
            if opcode & 7 <= 5 {
                try executeALUGrid(opcode: opcode, operandSize: operandSize)
                return
            }
        }

        switch opcode {
        case 0x0F:
            try executeTwoByte(operandSize: operandSize, address: address)
        case 0x40...0x47: // INC r
            let index = Int(opcode - 0x40)
            let value = operandSize == 2 ? UInt32(register16(index)) : register32(index)
            let result = incrementWithFlags(value, size: operandSize, decrement: false)
            if operandSize == 2 { setRegister16(index, UInt16(result & 0xFFFF)) } else { setRegister32(index, result) }
        case 0x48...0x4F: // DEC r
            let index = Int(opcode - 0x48)
            let value = operandSize == 2 ? UInt32(register16(index)) : register32(index)
            let result = incrementWithFlags(value, size: operandSize, decrement: true)
            if operandSize == 2 { setRegister16(index, UInt16(result & 0xFFFF)) } else { setRegister32(index, result) }
        case 0x50...0x57: // PUSH r
            let index = Int(opcode - 0x50)
            try push(operandSize == 2 ? UInt32(register16(index)) : register32(index), size: operandSize)
        case 0x58...0x5F: // POP r
            let index = Int(opcode - 0x58)
            let value = try pop(size: operandSize)
            if operandSize == 2 { setRegister16(index, UInt16(value & 0xFFFF)) } else { setRegister32(index, value) }
        case 0x60: // PUSHA / PUSHAD
            if operandSize == 4 {
                let savedSP = registers[4]
                for index in [0, 1, 2, 3] { try push(registers[index], size: 4) }
                try push(savedSP, size: 4)
                for index in [5, 6, 7] { try push(registers[index], size: 4) }
            } else {
                let savedSP = register16(4)
                for index in [0, 1, 2, 3] { try push(UInt32(register16(index)), size: 2) }
                try push(UInt32(savedSP), size: 2)
                for index in [5, 6, 7] { try push(UInt32(register16(index)), size: 2) }
            }
        case 0x61: // POPA / POPAD
            if operandSize == 4 {
                for index in [7, 6, 5] { registers[index] = try pop(size: 4) }
                _ = try pop(size: 4)
                for index in [3, 2, 1, 0] { registers[index] = try pop(size: 4) }
            } else {
                for index in [7, 6, 5] { setRegister16(index, UInt16(try pop(size: 2) & 0xFFFF)) }
                _ = try pop(size: 2)
                for index in [3, 2, 1, 0] { setRegister16(index, UInt16(try pop(size: 2) & 0xFFFF)) }
            }
        case 0x68: // PUSH imm
            try push(try fetchImmediate(operandSize), size: operandSize)
        case 0x6A: // PUSH imm8（符号拡張）
            let value = Int8(bitPattern: try fetch8())
            try push(UInt32(bitPattern: Int32(value)) & (operandSize == 2 ? 0xFFFF : 0xFFFFFFFF), size: operandSize)
        case 0x69, 0x6B: // IMUL r, r/m, imm
            let modRM = try decodeModRM()
            let source = try readOperand(modRM, size: operandSize)
            let immediate = opcode == 0x69 ? try fetchImmediate(operandSize) : UInt32(bitPattern: Int32(Int8(bitPattern: try fetch8())))
            let result = multiplySigned(source, immediate, size: operandSize)
            if operandSize == 2 { setRegister16(modRM.reg, UInt16(result & 0xFFFF)) } else { setRegister32(modRM.reg, UInt32(truncatingIfNeeded: result)) }
        case 0x70...0x7F: // Jcc rel8
            let displacement = Int8(bitPattern: try fetch8())
            if condition(Int(opcode & 0x0F)) {
                instructionPointer = (instructionPointer &+ UInt32(bitPattern: Int32(displacement))) & ipMask
            }
        case 0x80, 0x81, 0x82, 0x83: // グループ1（ALU + 即値）
            let size = opcode == 0x80 || opcode == 0x82 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            let immediate: UInt32
            if opcode == 0x83 {
                immediate = UInt32(bitPattern: Int32(Int8(bitPattern: try fetch8()))) & mask(forSize: size)
            } else {
                immediate = try fetchImmediate(size)
            }
            let result = alu(modRM.reg, operand, immediate, size: size)
            if modRM.reg != 7 { try writeOperand(modRM, size: size, result) }
        case 0x84, 0x85: // TEST
            let size = opcode == 0x84 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            let regValue = size == 1 ? UInt32(register8(modRM.reg)) : (size == 2 ? UInt32(register16(modRM.reg)) : register32(modRM.reg))
            _ = logicFlags(operand & regValue, size: size)
        case 0x86, 0x87: // XCHG
            let size = opcode == 0x86 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            let regValue = size == 1 ? UInt32(register8(modRM.reg)) : (size == 2 ? UInt32(register16(modRM.reg)) : register32(modRM.reg))
            try writeOperand(modRM, size: size, regValue)
            if size == 1 { setRegister8(modRM.reg, UInt8(operand & 0xFF)) }
            else if size == 2 { setRegister16(modRM.reg, UInt16(operand & 0xFFFF)) }
            else { setRegister32(modRM.reg, operand) }
        case 0x88, 0x89, 0x8A, 0x8B: // MOV
            let size = (opcode == 0x88 || opcode == 0x8A) ? 1 : operandSize
            let modRM = try decodeModRM()
            if opcode == 0x88 || opcode == 0x89 {
                let regValue = size == 1 ? UInt32(register8(modRM.reg)) : (size == 2 ? UInt32(register16(modRM.reg)) : register32(modRM.reg))
                try writeOperand(modRM, size: size, regValue)
            } else {
                let value = try readOperand(modRM, size: size)
                if size == 1 { setRegister8(modRM.reg, UInt8(value & 0xFF)) }
                else if size == 2 { setRegister16(modRM.reg, UInt16(value & 0xFFFF)) }
                else { setRegister32(modRM.reg, value) }
            }
        case 0x8C: // MOV セグメント → r/m
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 2, UInt32(segments[modRM.reg]))
        case 0x8D: // LEA
            let modRM = try decodeModRM()
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(opcode, address: address) }
            if operandSize == 2 { setRegister16(modRM.reg, UInt16(modRM.effectiveOffset & 0xFFFF)) }
            else { setRegister32(modRM.reg, modRM.effectiveOffset) }
        case 0x8E: // MOV r/m → セグメント
            let modRM = try decodeModRM()
            guard modRM.reg != 1 else { throw X86Fault.unimplementedOpcode(opcode, address: address) }
            let value = try readOperand(modRM, size: 2)
            try loadSegmentRegister(modRM.reg, UInt16(value & 0xFFFF))
        case 0x8F: // POP r/m
            let modRM = try decodeModRM()
            let value = try pop(size: operandSize)
            try writeOperand(modRM, size: operandSize, value)
        case 0x90...0x97: // NOP / XCHG EAX, r
            if opcode != 0x90 {
                let index = Int(opcode - 0x90)
                let accumulator = operandSize == 2 ? UInt32(register16(0)) : register32(0)
                let other = operandSize == 2 ? UInt32(register16(index)) : register32(index)
                if operandSize == 2 { setRegister16(0, UInt16(other & 0xFFFF)); setRegister16(index, UInt16(accumulator & 0xFFFF)) }
                else { setRegister32(0, other); setRegister32(index, accumulator) }
            }
        case 0x98: // CBW / CWDE
            if operandSize == 2 {
                setRegister16(0, UInt16(bitPattern: Int16(Int8(bitPattern: register8(0)))))
            } else {
                setRegister32(0, UInt32(bitPattern: Int32(Int16(bitPattern: register16(0)))))
            }
        case 0x99: // CWD / CDQ
            if operandSize == 2 {
                setRegister16(2, Int16(bitPattern: register16(0)) < 0 ? 0xFFFF : 0)
            } else {
                setRegister32(2, Int32(bitPattern: register32(0)) < 0 ? 0xFFFFFFFF : 0)
            }
        case 0x9A: // CALL far
            let offset = try fetchImmediate(operandSize)
            let newSegment = try fetch16()
            try push(UInt32(segments[1]), size: operandSize)
            try push(instructionPointer, size: operandSize)
            try loadCodeSegment(newSegment)
            instructionPointer = offset & ipMask
        case 0x9C: // PUSHF
            try push(operandSize == 2 ? flags & 0xFFFF : flags, size: operandSize)
        case 0x9D: // POPF
            let value = try pop(size: operandSize)
            if operandSize == 2 {
                flags = (value & 0x0FD5) | 0x0002 | (flags & 0xFFFF0000)
            } else {
                flags = value | 0x0002
            }
        case 0x9E: // SAHF
            flags = (flags & ~0xD5) | (UInt32(register8(4)) & 0xD5)
        case 0x9F: // LAHF
            setRegister8(4, UInt8((flags & 0xD5) | 0x02))
        case 0xA0, 0xA1, 0xA2, 0xA3: // MOV moffs
            let size = (opcode == 0xA0 || opcode == 0xA2) ? 1 : operandSize
            let offset = decodeAddressSize == 4 ? try fetch32() : UInt32(try fetch16())
            let segmentIndex = decodeSegmentOverride ?? 3
            if opcode == 0xA0 || opcode == 0xA1 {
                let value = try readGuest(segmentIndex: segmentIndex, offset: offset, size: size)
                if size == 1 { setRegister8(0, UInt8(value & 0xFF)) }
                else if size == 2 { setRegister16(0, UInt16(value & 0xFFFF)) }
                else { setRegister32(0, value) }
            } else {
                let value = size == 1 ? UInt32(register8(0)) : (size == 2 ? UInt32(register16(0)) : register32(0))
                try writeGuest(segmentIndex: segmentIndex, offset: offset, size: size, value)
            }
        case 0xA4...0xA7, 0xAA...0xAF: // 文字列操作
            try executeStringOperation(opcode: opcode, operandSize: operandSize, repeatPrefix: repeatPrefix)
        case 0xA8, 0xA9: // TEST AL / eAX, imm
            let size = opcode == 0xA8 ? 1 : operandSize
            let immediate = try fetchImmediate(size)
            _ = logicFlags(registerValue(0, size: size) & immediate, size: size)
        case 0xB0...0xB7: // MOV r8, imm8
            setRegister8(Int(opcode - 0xB0), try fetch8())
        case 0xB8...0xBF: // MOV r, imm
            let index = Int(opcode - 0xB8)
            let value = try fetchImmediate(operandSize)
            if operandSize == 2 { setRegister16(index, UInt16(value & 0xFFFF)) } else { setRegister32(index, value) }
        case 0xC0, 0xC1: // シフト（imm8）
            let size = opcode == 0xC0 ? 1 : operandSize
            let modRM = try decodeModRM()
            let count = Int(try fetch8())
            let value = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, shift(modRM.reg, value, count, size: size))
        case 0xC2: // RET imm16
            let extra = try fetch16()
            instructionPointer = try pop(size: operandSize) & ipMask
            setStackPointer(stackPointer &+ UInt32(extra))
        case 0xC3: // RET
            instructionPointer = try pop(size: operandSize) & ipMask
        case 0xC6, 0xC7: // MOV r/m, imm
            let size = opcode == 0xC6 ? 1 : operandSize
            let modRM = try decodeModRM()
            let value = try fetchImmediate(size)
            try writeOperand(modRM, size: size, value)
        case 0xC9: // LEAVE
            if operandSize == 2 {
                setRegister16(4, register16(5))
            } else {
                setRegister32(4, register32(5))
            }
            let value = try pop(size: operandSize)
            if operandSize == 2 { setRegister16(5, UInt16(value & 0xFFFF)) } else { setRegister32(5, value) }
        case 0xCA: // RETF imm16
            let extra = try fetch16()
            let returnIP = try pop(size: operandSize)
            let newSegment = UInt16(try pop(size: operandSize) & 0xFFFF)
            try loadCodeSegment(newSegment)
            instructionPointer = returnIP & ipMask
            setStackPointer(stackPointer &+ UInt32(extra))
        case 0xCB: // RETF
            let returnIP = try pop(size: operandSize)
            let newSegment = UInt16(try pop(size: operandSize) & 0xFFFF)
            try loadCodeSegment(newSegment)
            instructionPointer = returnIP & ipMask
        case 0xCC: // INT 3
            try executeInterrupt(vector: 3, startIP: startIP)
        case 0xCD: // INT imm8
            let vector = try fetch8()
            try executeInterrupt(vector: vector, startIP: startIP)
        case 0xCE: // INTO
            if flag(Self.flagOverflow) { try executeInterrupt(vector: 4, startIP: startIP) }
        case 0xCF: // IRET
            let returnIP = try pop(size: operandSize)
            let newSegment = UInt16(try pop(size: operandSize) & 0xFFFF)
            let value = try pop(size: operandSize)
            try loadCodeSegment(newSegment)
            instructionPointer = returnIP & ipMask
            if operandSize == 2 {
                flags = (value & 0x0FD5) | 0x0002 | (flags & 0xFFFF0000)
            } else {
                flags = value | 0x0002
            }
        case 0xD0, 0xD1, 0xD2, 0xD3: // シフト（1 / CL）
            let size = (opcode == 0xD0 || opcode == 0xD2) ? 1 : operandSize
            let modRM = try decodeModRM()
            let count = (opcode == 0xD0 || opcode == 0xD1) ? 1 : Int(register8(1))
            let value = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, shift(modRM.reg, value, count, size: size))
        case 0xD4: // AAM
            let base = UInt32(try fetch8())
            guard base != 0 else { throw divideFault(address: address) }
            let al = UInt32(register8(0))
            setRegister8(4, UInt8(al / base))
            setRegister8(0, UInt8(al % base))
            setSignZeroParity(UInt32(register8(0)), size: 1)
        case 0xD5: // AAD
            let base = UInt32(try fetch8())
            let result = (UInt32(register8(4)) * base + UInt32(register8(0))) & 0xFF
            setRegister8(0, UInt8(result))
            setRegister8(4, 0)
            setSignZeroParity(result, size: 1)
        case 0xD7: // XLAT
            let base = decodeAddressSize == 4 ? register32(3) : UInt32(register16(3))
            let value = try readGuest(segmentIndex: decodeSegmentOverride ?? 3, offset: base &+ UInt32(register8(0)), size: 1)
            setRegister8(0, UInt8(value & 0xFF))
        case 0xE0, 0xE1, 0xE2, 0xE3: // LOOP 系
            let displacement = Int8(bitPattern: try fetch8())
            var take = false
            if decodeAddressSize == 4 {
                switch opcode {
                case 0xE0: registers[1] &-= 1; take = registers[1] != 0 && !flag(Self.flagZero)
                case 0xE1: registers[1] &-= 1; take = registers[1] != 0 && flag(Self.flagZero)
                case 0xE2: registers[1] &-= 1; take = registers[1] != 0
                default: take = registers[1] == 0
                }
            } else {
                switch opcode {
                case 0xE0: setRegister16(1, register16(1) &- 1); take = register16(1) != 0 && !flag(Self.flagZero)
                case 0xE1: setRegister16(1, register16(1) &- 1); take = register16(1) != 0 && flag(Self.flagZero)
                case 0xE2: setRegister16(1, register16(1) &- 1); take = register16(1) != 0
                default: take = register16(1) == 0
                }
            }
            if take { instructionPointer = (instructionPointer &+ UInt32(bitPattern: Int32(displacement))) & ipMask }
        case 0xE4, 0xE5: // IN AL / eAX, imm8
            let port = UInt16(try fetch8())
            let size = opcode == 0xE4 ? 1 : operandSize
            let value = portIn(port, size: size)
            if size == 1 { setRegister8(0, UInt8(value & 0xFF)) }
            else if size == 2 { setRegister16(0, UInt16(value & 0xFFFF)) }
            else { setRegister32(0, value) }
        case 0xE6, 0xE7: // OUT imm8, AL / eAX
            let port = UInt16(try fetch8())
            let size = opcode == 0xE6 ? 1 : operandSize
            portOut(port, value: size == 1 ? UInt32(register8(0)) : (size == 2 ? UInt32(register16(0)) : register32(0)), size: size)
        case 0xE8: // CALL rel
            let displacement = operandSize == 2 ? Int32(Int16(bitPattern: try fetch16())) : Int32(bitPattern: try fetch32())
            try push(instructionPointer, size: operandSize)
            instructionPointer = (instructionPointer &+ UInt32(bitPattern: displacement)) & (operandSize == 2 ? 0xFFFF : 0xFFFFFFFF)
        case 0xE9: // JMP rel
            let displacement = operandSize == 2 ? Int32(Int16(bitPattern: try fetch16())) : Int32(bitPattern: try fetch32())
            instructionPointer = (instructionPointer &+ UInt32(bitPattern: displacement)) & (operandSize == 2 ? 0xFFFF : 0xFFFFFFFF)
        case 0xEA: // JMP far
            let offset = try fetchImmediate(operandSize)
            let newSegment = try fetch16()
            try loadCodeSegment(newSegment)
            instructionPointer = offset & ipMask
        case 0xEB: // JMP rel8
            let displacement = Int8(bitPattern: try fetch8())
            instructionPointer = (instructionPointer &+ UInt32(bitPattern: Int32(displacement))) & ipMask
        case 0xEC, 0xED: // IN AL / eAX, DX
            let size = opcode == 0xEC ? 1 : operandSize
            let value = portIn(register16(2), size: size)
            if size == 1 { setRegister8(0, UInt8(value & 0xFF)) }
            else if size == 2 { setRegister16(0, UInt16(value & 0xFFFF)) }
            else { setRegister32(0, value) }
        case 0xEE, 0xEF: // OUT DX, AL / eAX
            let size = opcode == 0xEE ? 1 : operandSize
            portOut(register16(2), value: size == 1 ? UInt32(register8(0)) : (size == 2 ? UInt32(register16(0)) : register32(0)), size: size)
        case 0xF4: // HLT
            halted = true
            exitCode = 0
        case 0xF5: // CMC
            setFlag(Self.flagCarry, !flag(Self.flagCarry))
        case 0xF6, 0xF7: // グループ3
            try executeGroup3(opcode: opcode, operandSize: operandSize, address: address)
        case 0xF8: setFlag(Self.flagCarry, false)
        case 0xF9: setFlag(Self.flagCarry, true)
        case 0xFA: setFlag(Self.flagInterrupt, false)
        case 0xFB: setFlag(Self.flagInterrupt, true)
        case 0xFC: setFlag(Self.flagDirection, false)
        case 0xFD: setFlag(Self.flagDirection, true)
        case 0xFE: // グループ4（INC / DEC byte）
            let modRM = try decodeModRM()
            let value = try readOperand(modRM, size: 1)
            let result = incrementWithFlags(value, size: 1, decrement: modRM.reg == 1)
            try writeOperand(modRM, size: 1, result)
        case 0xFF: // グループ5
            try executeGroup5(operandSize: operandSize, address: address)
        case 0x9B, 0xF1:
            break // WAIT / 未定義（NOP 扱い）
        default:
            throw X86Fault.unimplementedOpcode(opcode, address: address)
        }
    }

    // MARK: - 命令グループの実装

    private func registerValue(_ index: Int, size: Int) -> UInt32 {
        size == 1 ? UInt32(register8(index)) : (size == 2 ? UInt32(register16(index)) : register32(index))
    }

    private func setRegisterValue(_ index: Int, size: Int, _ value: UInt32) {
        if size == 1 { setRegister8(index, UInt8(value & 0xFF)) }
        else if size == 2 { setRegister16(index, UInt16(value & 0xFFFF)) }
        else { setRegister32(index, value) }
    }

    private func signExtend(_ value: UInt32, size: Int) -> Int64 {
        switch size {
        case 1: return Int64(Int8(bitPattern: UInt8(value & 0xFF)))
        case 2: return Int64(Int16(bitPattern: UInt16(value & 0xFFFF)))
        default: return Int64(Int32(bitPattern: value))
        }
    }

    /// 符号付き乗算。結果が size に収まらなければ CF / OF を立てる。
    private func multiplySigned(_ a: UInt32, _ b: UInt32, size: Int) -> Int64 {
        let full = signExtend(a, size: size) * signExtend(b, size: size)
        let truncated = signExtend(UInt32(truncatingIfNeeded: full), size: size)
        let overflow = full != truncated
        setFlag(Self.flagCarry, overflow)
        setFlag(Self.flagOverflow, overflow)
        return full
    }

    private func executeALUGrid(opcode: UInt8, operandSize: Int) throws {
        let operation = Int((opcode >> 3) & 7)
        let form = Int(opcode & 7)
        switch form {
        case 0, 1: // r/m ← r/m OP r
            let size = form == 0 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            let result = alu(operation, operand, registerValue(modRM.reg, size: size), size: size)
            if operation != 7 { try writeOperand(modRM, size: size, result) }
        case 2, 3: // r ← r OP r/m
            let size = form == 2 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            let result = alu(operation, registerValue(modRM.reg, size: size), operand, size: size)
            if operation != 7 { setRegisterValue(modRM.reg, size: size, result) }
        case 4: // AL, imm8
            let immediate = UInt32(try fetch8())
            let result = alu(operation, UInt32(register8(0)), immediate, size: 1)
            if operation != 7 { setRegister8(0, UInt8(result & 0xFF)) }
        default: // eAX, imm
            let immediate = try fetchImmediate(operandSize)
            let result = alu(operation, registerValue(0, size: operandSize), immediate, size: operandSize)
            if operation != 7 { setRegisterValue(0, size: operandSize, result) }
        }
    }

    /// 未実装命令に対するエラー（プロテクトモードでは #UD 例外にする）。
    private func opcodeFault(_ opcode: UInt8, address: UInt32) -> Error {
        if protectedMode {
            return CPUTrap.exception(vector: 6, errorCode: nil)
        }
        return X86Fault.unimplementedOpcode(opcode, address: address)
    }

    private func executeTwoByte(operandSize: Int, address: UInt32) throws {
        let opcode = try fetch8()
        switch opcode {
        case 0x00: // グループ6（SLDT / STR / LLDT / LTR）
            let modRM = try decodeModRM()
            switch modRM.reg {
            case 0: try writeOperand(modRM, size: 2, UInt32(ldtrSelector))
            case 1: try writeOperand(modRM, size: 2, UInt32(taskRegister))
            case 2:
                let selector = UInt16(try readOperand(modRM, size: 2) & 0xFFFF)
                ldtrSelector = selector
                if selector & 0xFFF8 != 0 {
                    ldtrCache = try descriptorCache(selector: selector)
                } else {
                    ldtrCache = SegmentCache()
                }
            case 3:
                taskRegister = UInt16(try readOperand(modRM, size: 2) & 0xFFFF)
            default:
                throw opcodeFault(opcode, address: address)
            }
        case 0x01: // グループ7（SGDT / SIDT / LGDT / LIDT / SMSW / LMSW / INVLPG）
            let modRM = try decodeModRM()
            switch modRM.reg {
            case 0, 1: // SGDT / SIDT
                guard !modRM.isRegister else { throw opcodeFault(opcode, address: address) }
                let base = modRM.reg == 0 ? gdtrBase : idtrBase
                let limit = modRM.reg == 0 ? gdtrLimit : idtrLimit
                try writeGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset, size: 2, UInt32(limit))
                try writeGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset &+ 2, size: 4, base)
            case 2, 3: // LGDT / LIDT
                guard !modRM.isRegister else { throw opcodeFault(opcode, address: address) }
                let limit = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset, size: 2)
                let base = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset &+ 2, size: 4)
                if modRM.reg == 2 {
                    gdtrBase = base
                    gdtrLimit = UInt16(limit & 0xFFFF)
                } else {
                    idtrBase = base
                    idtrLimit = UInt16(limit & 0xFFFF)
                }
            case 4: // SMSW
                try writeOperand(modRM, size: 2, controlRegisters[0] & 0xFFFF)
            case 6: // LMSW
                let value = try readOperand(modRM, size: 2) & 0xFFFF
                var newValue = (controlRegisters[0] & 0xFFFF0000) | value
                if controlRegisters[0] & 1 != 0 { newValue |= 1 } // PE は落とせない
                controlRegisters[0] = newValue
            case 7: // INVLPG（TLB は持たないため何もしない）
                break
            default:
                throw opcodeFault(opcode, address: address)
            }
        case 0x06: // CLTS
            break
        case 0x08, 0x09: // INVD / WBINVD（キャッシュを持たないため何もしない）
            break
        case 0x0B: // UD2
            throw opcodeFault(opcode, address: address)
        case 0x1F: // マルチバイト NOP
            _ = try decodeModRM()
        case 0x20, 0x21, 0x22, 0x23: // MOV CRn / DRn
            let modRM = try decodeModRM()
            let controlIndex = modRM.reg
            if opcode == 0x20 {
                try writeOperand(modRM, size: 4, controlRegisters[controlIndex])
            } else if opcode == 0x22 {
                controlRegisters[controlIndex] = try readOperand(modRM, size: 4)
            } else if opcode == 0x21 {
                try writeOperand(modRM, size: 4, 0) // DR は未実装（読み出しは 0）
            }
            // 0x23: DR への書き込みは無視
        case 0x30: // WRMSR（無視）
            break
        case 0x32: // RDMSR（0 を返す）
            registers[0] = 0
            registers[2] = 0
        case 0x40...0x4F: // CMOVcc
            let modRM = try decodeModRM()
            if condition(Int(opcode & 0x0F)) {
                let value = try readOperand(modRM, size: operandSize)
                setRegisterValue(modRM.reg, size: operandSize, value)
            }
        case 0x80...0x8F: // Jcc near
            let displacement = operandSize == 2 ? Int32(Int16(bitPattern: try fetch16())) : Int32(bitPattern: try fetch32())
            if condition(Int(opcode & 0x0F)) {
                instructionPointer = (instructionPointer &+ UInt32(bitPattern: displacement)) & (operandSize == 2 ? 0xFFFF : 0xFFFFFFFF)
            }
        case 0x90...0x9F: // SETcc
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 1, condition(Int(opcode & 0x0F)) ? 1 : 0)
        case 0xA0: try push(UInt32(segments[4]), size: operandSize) // PUSH FS
        case 0xA1: try loadSegmentRegister(4, UInt16(try pop(size: operandSize) & 0xFFFF)) // POP FS
        case 0xA2: // CPUID
            switch registers[0] {
            case 0:
                registers[0] = 1
                registers[3] = 0x61746552 // EBX: "Reta"
                registers[2] = 0x4D567573 // EDX: "suVM"
                registers[1] = 0x20363878 // ECX: "x86 "
            case 1:
                registers[0] = 0x00000611
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0x00000139 // FPU / PSE / TSC / MSR / CX8
            case 0x80000000:
                registers[0] = 0x80000001
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            default:
                registers[0] = 0
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            }
        case 0xA8: try push(UInt32(segments[5]), size: operandSize) // PUSH GS
        case 0xA9: try loadSegmentRegister(5, UInt16(try pop(size: operandSize) & 0xFFFF)) // POP GS
        case 0xB6, 0xB7: // MOVZX
            let modRM = try decodeModRM()
            let value = try readOperand(modRM, size: opcode == 0xB6 ? 1 : 2)
            setRegisterValue(modRM.reg, size: operandSize, value)
        case 0xBE, 0xBF: // MOVSX
            let sourceSize = opcode == 0xBE ? 1 : 2
            let modRM = try decodeModRM()
            let raw = try readOperand(modRM, size: sourceSize)
            setRegisterValue(modRM.reg, size: operandSize, UInt32(bitPattern: Int32(signExtend(raw, size: sourceSize))))
        case 0xC8...0xCF: // BSWAP
            let index = Int(opcode - 0xC8)
            registers[index] = registers[index].byteSwapped
        default:
            throw opcodeFault(opcode, address: address)
        }
    }

    private func executeBCDAdjust(_ opcode: UInt8) {
        switch opcode {
        case 0x27: // DAA
            var al = UInt32(register8(0))
            let oldCarry = flag(Self.flagCarry)
            setFlag(Self.flagCarry, false)
            if (al & 0x0F) > 9 || flag(Self.flagAuxCarry) {
                al += 6
                setFlag(Self.flagAuxCarry, true)
            } else {
                setFlag(Self.flagAuxCarry, false)
            }
            if al > 0x9F || oldCarry {
                al += 0x60
                setFlag(Self.flagCarry, true)
            }
            setRegister8(0, UInt8(al & 0xFF))
            setSignZeroParity(al & 0xFF, size: 1)
        case 0x2F: // DAS
            let original = UInt32(register8(0))
            var al = Int32(original)
            let oldCarry = flag(Self.flagCarry)
            setFlag(Self.flagCarry, false)
            if (original & 0x0F) > 9 || flag(Self.flagAuxCarry) {
                al -= 6
                setFlag(Self.flagAuxCarry, true)
            } else {
                setFlag(Self.flagAuxCarry, false)
            }
            if original > 0x99 || oldCarry {
                al -= 0x60
                setFlag(Self.flagCarry, true)
            }
            setRegister8(0, UInt8(al & 0xFF))
            setSignZeroParity(UInt32(al & 0xFF), size: 1)
        case 0x37: // AAA
            if (register8(0) & 0x0F) > 9 || flag(Self.flagAuxCarry) {
                setRegister16(0, register16(0) &+ 0x106)
                setFlag(Self.flagAuxCarry, true)
                setFlag(Self.flagCarry, true)
            } else {
                setFlag(Self.flagAuxCarry, false)
                setFlag(Self.flagCarry, false)
            }
            setRegister8(0, register8(0) & 0x0F)
        default: // 0x3F AAS
            if (register8(0) & 0x0F) > 9 || flag(Self.flagAuxCarry) {
                setRegister16(0, register16(0) &- 0x106)
                setFlag(Self.flagAuxCarry, true)
                setFlag(Self.flagCarry, true)
            } else {
                setFlag(Self.flagAuxCarry, false)
                setFlag(Self.flagCarry, false)
            }
            setRegister8(0, register8(0) & 0x0F)
        }
    }

    private func executeStringOperation(opcode: UInt8, operandSize: Int, repeatPrefix: UInt8) throws {
        let size = opcode & 1 == 0 ? 1 : operandSize
        let isRepeated = repeatPrefix == 0xF3 || repeatPrefix == 0xF2
        let use32 = decodeAddressSize == 4
        while true {
            if isRepeated {
                if use32 {
                    if registers[1] == 0 { return }
                    registers[1] &-= 1
                } else {
                    if register16(1) == 0 { return }
                    setRegister16(1, register16(1) &- 1)
                }
            }
            try singleStringStep(opcode: opcode, size: size)
            if !isRepeated { return }
            if opcode == 0xA6 || opcode == 0xA7 || opcode == 0xAE || opcode == 0xAF {
                if repeatPrefix == 0xF3 && !flag(Self.flagZero) { return }
                if repeatPrefix == 0xF2 && flag(Self.flagZero) { return }
            }
        }
    }

    private func singleStringStep(opcode: UInt8, size: Int) throws {
        let use32 = decodeAddressSize == 4
        let stepDelta = Int32(size) * (flag(Self.flagDirection) ? -1 : 1)
        func pointer(_ index: Int) -> UInt32 { use32 ? registers[index] : UInt32(register16(index)) }
        func advance(_ index: Int) {
            if use32 {
                registers[index] = registers[index] &+ UInt32(bitPattern: stepDelta)
            } else {
                setRegister16(index, UInt16((Int32(register16(index)) + stepDelta) & 0xFFFF))
            }
        }
        let sourceSegment = decodeSegmentOverride ?? 3
        let sourceOffset = pointer(6)
        let destinationOffset = pointer(7)
        switch opcode {
        case 0xA4, 0xA5: // MOVS
            try writeGuest(segmentIndex: 0, offset: destinationOffset, size: size, try readGuest(segmentIndex: sourceSegment, offset: sourceOffset, size: size))
            advance(6); advance(7)
        case 0xA6, 0xA7: // CMPS
            let a = try readGuest(segmentIndex: sourceSegment, offset: sourceOffset, size: size)
            let b = try readGuest(segmentIndex: 0, offset: destinationOffset, size: size)
            _ = subtractWithFlags(a, b, size: size, borrowIn: false)
            advance(6); advance(7)
        case 0xAA, 0xAB: // STOS
            try writeGuest(segmentIndex: 0, offset: destinationOffset, size: size, registerValue(0, size: size))
            advance(7)
        case 0xAC, 0xAD: // LODS
            setRegisterValue(0, size: size, try readGuest(segmentIndex: sourceSegment, offset: sourceOffset, size: size))
            advance(6)
        case 0xAE, 0xAF: // SCAS
            let b = try readGuest(segmentIndex: 0, offset: destinationOffset, size: size)
            _ = subtractWithFlags(registerValue(0, size: size), b, size: size, borrowIn: false)
            advance(7)
        default:
            break
        }
    }

    private func executeGroup3(opcode: UInt8, operandSize: Int, address: UInt32) throws {
        let size = opcode == 0xF6 ? 1 : operandSize
        let modRM = try decodeModRM()
        switch modRM.reg {
        case 0: // TEST imm
            let operand = try readOperand(modRM, size: size)
            let immediate = try fetchImmediate(size)
            _ = logicFlags(operand & immediate, size: size)
        case 2: // NOT
            let operand = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, ~operand & mask(forSize: size))
        case 3: // NEG
            let operand = try readOperand(modRM, size: size)
            let result = subtractWithFlags(0, operand, size: size, borrowIn: false)
            setFlag(Self.flagCarry, operand != 0)
            try writeOperand(modRM, size: size, result)
        case 4: // MUL
            let operand = try readOperand(modRM, size: size)
            switch size {
            case 1:
                let full = UInt32(register8(0)) * operand
                setRegister16(0, UInt16(full & 0xFFFF))
                let overflow = (full >> 8) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            case 2:
                let full = UInt32(register16(0)) * operand
                setRegister16(0, UInt16(full & 0xFFFF))
                setRegister16(2, UInt16((full >> 16) & 0xFFFF))
                let overflow = (full >> 16) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            default:
                let full = UInt64(register32(0)) * UInt64(operand)
                setRegister32(0, UInt32(full & 0xFFFFFFFF))
                setRegister32(2, UInt32(full >> 32))
                let overflow = (full >> 32) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            }
        case 5: // IMUL（1 オペランド）
            let operand = try readOperand(modRM, size: size)
            let full = multiplySigned(registerValue(0, size: size), operand, size: size)
            let bits = UInt64(bitPattern: full)
            switch size {
            case 1: setRegister16(0, UInt16(bits & 0xFFFF))
            case 2:
                setRegister16(0, UInt16(bits & 0xFFFF))
                setRegister16(2, UInt16((bits >> 16) & 0xFFFF))
            default:
                setRegister32(0, UInt32(bits & 0xFFFFFFFF))
                setRegister32(2, UInt32(bits >> 32))
            }
        case 6, 7: // DIV / IDIV
            let divisor = try readOperand(modRM, size: size)
            guard divisor != 0 else { throw divideFault(address: address) }
            let signed = modRM.reg == 7
            switch size {
            case 1:
                if signed {
                    let dividend = Int32(Int16(bitPattern: register16(0)))
                    let d = Int32(Int8(bitPattern: UInt8(divisor & 0xFF)))
                    let quotient = dividend / d
                    guard quotient >= -128 && quotient <= 127 else { throw divideFault(address: address) }
                    setRegister8(0, UInt8(bitPattern: Int8(quotient)))
                    setRegister8(4, UInt8(bitPattern: Int8(dividend % d)))
                } else {
                    let dividend = UInt32(register16(0))
                    let quotient = dividend / divisor
                    guard quotient <= 0xFF else { throw divideFault(address: address) }
                    setRegister8(0, UInt8(quotient))
                    setRegister8(4, UInt8(dividend % divisor))
                }
            case 2:
                let dividendBits = (UInt32(register16(2)) << 16) | UInt32(register16(0))
                if signed {
                    let dividend = Int32(bitPattern: dividendBits)
                    let d = Int32(Int16(bitPattern: UInt16(divisor & 0xFFFF)))
                    let quotient = dividend / d
                    guard quotient >= -32768 && quotient <= 32767 else { throw divideFault(address: address) }
                    setRegister16(0, UInt16(bitPattern: Int16(quotient)))
                    setRegister16(2, UInt16(bitPattern: Int16(dividend % d)))
                } else {
                    let quotient = dividendBits / divisor
                    guard quotient <= 0xFFFF else { throw divideFault(address: address) }
                    setRegister16(0, UInt16(quotient))
                    setRegister16(2, UInt16(dividendBits % divisor))
                }
            default:
                let dividendBits = (UInt64(register32(2)) << 32) | UInt64(register32(0))
                if signed {
                    let dividend = Int64(bitPattern: dividendBits)
                    let d = Int64(Int32(bitPattern: divisor))
                    let quotient = dividend / d
                    guard quotient >= Int64(Int32.min) && quotient <= Int64(Int32.max) else { throw divideFault(address: address) }
                    setRegister32(0, UInt32(bitPattern: Int32(quotient)))
                    setRegister32(2, UInt32(bitPattern: Int32(dividend % d)))
                } else {
                    let quotient = dividendBits / UInt64(divisor)
                    guard quotient <= 0xFFFFFFFF else { throw divideFault(address: address) }
                    setRegister32(0, UInt32(quotient))
                    setRegister32(2, UInt32(dividendBits % UInt64(divisor)))
                }
            }
        default:
            throw X86Fault.unimplementedOpcode(opcode, address: address)
        }
    }

    /// 除算エラー（プロテクトモードでは #DE 例外にする）。
    private func divideFault(address: UInt32) -> Error {
        if protectedMode {
            return CPUTrap.exception(vector: 0, errorCode: nil)
        }
        return X86Fault.divideError(address: address)
    }

    private func executeGroup5(operandSize: Int, address: UInt32) throws {
        let modRM = try decodeModRM()
        switch modRM.reg {
        case 0:
            let value = try readOperand(modRM, size: operandSize)
            try writeOperand(modRM, size: operandSize, incrementWithFlags(value, size: operandSize, decrement: false))
        case 1:
            let value = try readOperand(modRM, size: operandSize)
            try writeOperand(modRM, size: operandSize, incrementWithFlags(value, size: operandSize, decrement: true))
        case 2: // CALL near indirect
            let target = try readOperand(modRM, size: operandSize)
            try push(instructionPointer, size: operandSize)
            instructionPointer = target & ipMask
        case 3: // CALL far indirect
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(0xFF, address: address) }
            let offset = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset, size: operandSize)
            let newSegment = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset &+ UInt32(operandSize), size: 2)
            try push(UInt32(segments[1]), size: operandSize)
            try push(instructionPointer, size: operandSize)
            try loadCodeSegment(UInt16(newSegment & 0xFFFF))
            instructionPointer = offset & ipMask
        case 4: // JMP near indirect
            let target = try readOperand(modRM, size: operandSize)
            instructionPointer = target & ipMask
        case 5: // JMP far indirect
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(0xFF, address: address) }
            let offset = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset, size: operandSize)
            let newSegment = try readGuest(segmentIndex: modRM.segmentIndex, offset: modRM.effectiveOffset &+ UInt32(operandSize), size: 2)
            try loadCodeSegment(UInt16(newSegment & 0xFFFF))
            instructionPointer = offset & ipMask
        case 6: // PUSH r/m
            try push(try readOperand(modRM, size: operandSize), size: operandSize)
        default:
            throw X86Fault.unimplementedOpcode(0xFF, address: address)
        }
    }

    private func executeInterrupt(vector: UInt8, startIP: UInt32) throws {
        if protectedMode {
            // プロテクトモードでは BIOS ではなく IDT ゲートを使う
            try dispatchGate(vector: vector, errorCode: nil, returnIP: instructionPointer)
            return
        }
        guard let handler = interruptHandler else { throw X86Fault.noInterruptHandler(vector) }
        if handler(vector) == .needsInput {
            instructionPointer = startIP
            waitingForInput = true
        }
    }

    // MARK: - ポート I/O（シリアル COM1 / COM2 をコンソールへ接続）

    private func portIn(_ port: UInt16, size: Int) -> UInt32 {
        switch port {
        case 0x3F8, 0x2F8:
            return UInt32(nextInputByte() ?? 0)
        case 0x3FD, 0x2FD:
            return 0x20 | (hasInput ? 0x01 : 0)
        default:
            return mask(forSize: size)
        }
    }

    private func portOut(_ port: UInt16, value: UInt32, size: Int) {
        if port == 0x3F8 || port == 0x2F8 {
            onChar?(UInt8(value & 0xFF))
        }
    }
}
