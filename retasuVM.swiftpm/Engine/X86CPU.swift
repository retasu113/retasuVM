import Foundation

enum X86Fault: Error, CustomStringConvertible, LocalizedError {
    case unimplementedOpcode(UInt8, address: UInt64)
    case unsupportedPrefix(address: UInt64)
    case memoryOutOfBounds(address: UInt64)
    case divideError(address: UInt64)
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

/// 自作の x86 CPU エミュレータ（リアルモード + 32 ビット プロテクトモード + ロングモード）。
///
/// BIOS ブートしたゲスト（ブートセクタ、El Torito 対応 ISO の起動コード、
/// リアルモードで動作する小さな OS）に加え、GDT / IDT を使う 32 ビット
/// プロテクトモードのコード（ページング、例外配送、Multiboot カーネル）を
/// 実行できる。リアルモードの割り込み（INT 命令）はホスト側の BIOS
/// サービス（`X86BIOS`）へ委譲し、プロテクトモードでは IDT のゲートを
/// 使う。シリアルポート（COM1: 0x3F8）はコンソールへ接続されている。
///
/// 特権レベルはリング 0〜3 に対応し、TSS によるスタック切り替え、
/// SYSCALL / SYSRET、ハードウェアタスクスイッチ（32 ビット TSS）も
/// 実装している。対象外は浮動小数点演算で、それに当たると
/// `X86Fault` で停止する。
final class X86CPU {
    /// レジスタ番号（x86 エンコーディング順）: 0=EAX 1=ECX 2=EDX 3=EBX 4=ESP 5=EBP 6=ESI 7=EDI
    private(set) var registers: [UInt64] = [UInt64](repeating: 0, count: 16)
    /// セグメントレジスタ（0=ES 1=CS 2=SS 3=DS 4=FS 5=GS）
    private(set) var segments: [UInt16] = [UInt16](repeating: 0, count: 6)
    private(set) var instructionPointer: UInt64 = 0
    private(set) var flags: UInt32 = 0x0002

    private(set) var memory: [UInt8]
    private(set) var halted = false
    private(set) var exitCode: Int32 = 0
    private(set) var waitingForInput = false
    private(set) var instructionsExecuted: UInt64 = 0

    /// 周辺デバイスバス（PIC / PIT / RTC / キーボード / PCI / IDE など）。
    let devices = X86DeviceBus()
    /// BIOS と IDE で共有するディスクイメージ。
    private(set) var attachedDisk: X86DiskImage?
    /// HLT で割り込み待ちになっている状態（OS のアイドル）。
    private(set) var waitingForInterrupt = false
    /// STI / SS ロード直後の割り込み禁止期間（命令数）。
    private var interruptInhibit = 0
    /// デバイス時刻の供給元（テストで差し替え可能）。
    var timeSource: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var nowNanos: UInt64 { timeSource() }

    var onChar: ((UInt8) -> Void)?
    var onClearScreen: (() -> Void)?
    /// 命令実行直前のフック（UEFI のサービススタブ横取りに使う）。
    /// true を返すとその命令は実行されず、次の命令へ進む。
    var preExecuteHook: ((UInt64) -> Bool)?

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
        var base: UInt64 = 0
        var limit: UInt32 = 0xFFFF
        /// コードセグメントなら既定オペランドサイズ、データならスタック幅（B ビット）。
        var defaultSize32 = false
        /// ロングモードの 64 ビット コードセグメント（L ビット）。
        var longMode = false
        var present = true
        var isCode = false
        var isExpandDown = false
        var permitsRead = true
        var permitsWrite = true
        /// ディスクリプタ特権レベル（DPL）。
        var dpl: Int = 0
        /// 適合型コードセグメントかどうか。
        var conforming = false
    }

    /// コントロールレジスタ（CR0 / CR2 / CR3 / CR4 を使用）。
    private(set) var controlRegisters: [UInt64] = [UInt64](repeating: 0, count: 16)
    private var gdtrBase: UInt64 = 0
    private var gdtrLimit: UInt16 = 0
    private var idtrBase: UInt64 = 0
    private var idtrLimit: UInt16 = 0xFFFF
    private var ldtrSelector: UInt16 = 0
    private var ldtrCache = SegmentCache()
    private var taskRegister: UInt16 = 0
    private(set) var segmentCaches: [SegmentCache] = [SegmentCache](repeating: SegmentCache(), count: 6)

    var protectedMode: Bool { controlRegisters[0] & 0x00000001 != 0 }
    var pagingEnabled: Bool { protectedMode && controlRegisters[0] & 0x80000000 != 0 }
    /// EFER レジスタ（MSR 0xC0000080）。bit8 = LME、bit11 = NXE。
    private(set) var efer: UInt64 = 0
    /// ロングモードが有効（LME 設定済みでページング有効）な状態。
    var longModeActive: Bool { efer & 0x100 != 0 && pagingEnabled }
    /// 現在 64 ビット モードで実行中（CS の L ビットが立っている）。
    var inLongMode: Bool { longModeActive && segmentCaches[1].longMode }
    /// KernelGSBase MSR（0xC0000102）の保存値。
    private var kernelGSBase: UInt64 = 0
    /// TSS ディスクリプタのキャッシュ（LTR で設定）。
    private var tssBase: UInt64 = 0
    private var tssPresent = false
    /// SYSCALL / SYSRET 用 MSR（STAR / LSTAR / CSTAR / SFMASK）。
    private var starMSR: UInt64 = 0
    private var lstarMSR: UInt64 = 0
    private var cstarMSR: UInt64 = 0
    private var sfmaskMSR: UInt64 = 0

    /// 現在の特権レベル（CS ディスクリプタの DPL）。
    var currentPrivilegeLevel: Int { segmentCaches[1].dpl }

    /// IOPL（RFLAGS のビット 12-13）。
    private var iopl: Int { Int((flags >> 12) & 0x3) }

    /// CPL 0 を要求する命令用チェック。
    private func requireCPL0() throws {
        guard currentPrivilegeLevel == 0 else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
    }

    /// I/O と割り込みフラグ操作の IOPL チェック。
    private func requireIOPL() throws {
        guard currentPrivilegeLevel <= iopl else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
    }

    /// TSS からリング 0 のスタックポインタを読む（未設定なら nil）。
    private func tssStackPointer0() -> UInt64? {
        guard tssPresent else { return nil }
        if longModeActive {
            return try? readMemoryValue(at: Int(tssBase + 4), size: 8)
        }
        return try? readMemoryValue(at: Int(tssBase + 4), size: 4)
    }

    /// far 転送先セレクタがタスクゲート / TSS ディスクリプタなら、
    /// 切り替え先の TSS セレクタを返す（通常セグメントなら nil）。
    private func taskGateOrTSS(selector: UInt16) throws -> UInt16? {
        guard protectedMode, selector & 0xFFF8 != 0 else { return nil }
        let tableBase = selector & 0x0004 != 0 ? ldtrCache.base : gdtrBase
        let address = Int(tableBase + UInt64(selector & 0xFFF8))
        let access = try readMemoryValue(at: address + 5, size: 1)
        guard access & 0x10 == 0 else { return nil } // システムセグメントのみ
        switch access & 0xF {
        case 0x5: // タスクゲート
            guard access & 0x80 != 0 else {
                throw CPUTrap.exception(vector: 11, errorCode: UInt32(selector & 0xFFFC))
            }
            return UInt16(try readMemoryValue(at: address + 2, size: 2) & 0xFFFF)
        case 0x9, 0xB, 0x1, 0x3: // TSS（32 ビット / 16 ビット、空き / ビジー）
            return selector
        default:
            return nil
        }
    }

    private enum TaskSwitchKind {
        case jump       // JMP: 旧タスクのビジーを解除する
        case nested     // CALL / 割り込み: 旧タスクはビジーのまま、NT とバックリンクを設定
        case iretReturn // NT つき IRET: 旧タスクのビジーを解除する
    }

    /// ハードウェアタスクスイッチ（32 ビット TSS、レガシーモード専用）。
    /// 現在の状態を現在の TSS へ保存し、新しい TSS から状態を読み込む。
    private func switchTask(toTSSSelector selector: UInt16, kind: TaskSwitchKind, returnIP: UInt64) throws {
        guard !longModeActive else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
        guard selector & 0xFFF8 != 0 else { throw CPUTrap.exception(vector: 10, errorCode: 0) }
        let tableBase = selector & 0x0004 != 0 ? ldtrCache.base : gdtrBase
        let descriptorAddress = Int(tableBase + UInt64(selector & 0xFFF8))
        let access = try readMemoryValue(at: descriptorAddress + 5, size: 1)
        let descriptorType = access & 0xF
        guard access & 0x10 == 0, descriptorType == 0x9 else {
            // ビジー（0xB）や 16 ビット TSS（0x1 / 0x3）への切り替えは不可
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        guard access & 0x80 != 0 else {
            throw CPUTrap.exception(vector: 11, errorCode: UInt32(selector & 0xFFFC))
        }
        let newCache = try descriptorCache(selector: selector)
        guard newCache.limit >= 103 else {
            throw CPUTrap.exception(vector: 10, errorCode: UInt32(selector & 0xFFFC))
        }
        let newBase = newCache.base
        // 新タスクの EFLAGS を先に読み、VM86 タスクは弾く
        let loadedFlags = try readMemoryValue(at: Int(newBase) + 36, size: 4)
        guard loadedFlags & 0x20000 == 0 else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
        // 現在の状態を現在の TSS へ保存する
        if tssPresent && taskRegister & 0xFFF8 != 0 {
            let old = Int(tssBase)
            try writeMemoryValue(at: old + 28, size: 4, controlRegisters[3])
            try writeMemoryValue(at: old + 32, size: 4, returnIP)
            try writeMemoryValue(at: old + 36, size: 4, UInt64(flags))
            for (index, offset) in [40, 44, 48, 52, 56, 60, 64, 68].enumerated() {
                try writeMemoryValue(at: old + offset, size: 4, registers[index])
            }
            for (index, offset) in [72, 76, 80, 84, 88, 92].enumerated() {
                try writeMemoryValue(at: old + offset, size: 2, UInt64(segments[index]))
            }
            try writeMemoryValue(at: old + 96, size: 2, UInt64(ldtrSelector))
            if kind != .nested {
                // JMP / IRET による切り替えでは旧タスクのビジーを解除する
                let oldTableBase = taskRegister & 0x0004 != 0 ? ldtrCache.base : gdtrBase
                let oldDescriptor = Int(oldTableBase + UInt64(taskRegister & 0xFFF8))
                let oldAccess = try readMemoryValue(at: oldDescriptor + 5, size: 1)
                try writeMemoryValue(at: oldDescriptor + 5, size: 1, oldAccess & ~0x2)
            }
        }
        // 新タスクをビジーにし、ネスト時はバックリンクを書く
        try writeMemoryValue(at: descriptorAddress + 5, size: 1, access | 0x2)
        if kind == .nested {
            try writeMemoryValue(at: Int(newBase), size: 2, UInt64(taskRegister))
        }
        // 新しい状態を読み込む
        controlRegisters[3] = try readMemoryValue(at: Int(newBase) + 28, size: 4)
        instructionPointer = try readMemoryValue(at: Int(newBase) + 32, size: 4)
        var newFlags = UInt32(loadedFlags & 0xFFFFFFFF)
        if kind == .nested { newFlags |= 0x4000 } // NT
        flags = newFlags
        for (index, offset) in [40, 44, 48, 52, 56, 60, 64, 68].enumerated() {
            registers[index] = try readMemoryValue(at: Int(newBase) + offset, size: 4)
        }
        let newLDT = UInt16(try readMemoryValue(at: Int(newBase) + 96, size: 2) & 0xFFFF)
        ldtrSelector = newLDT
        ldtrCache = newLDT & 0xFFF8 != 0 ? try descriptorCache(selector: newLDT) : SegmentCache()
        let segmentOffsets = [72, 76, 80, 84, 88, 92]
        let segmentSelectors = try segmentOffsets.map { UInt16(try readMemoryValue(at: Int(newBase) + $0, size: 2) & 0xFFFF) }
        // CS / SS はキャッシュを直接設定し、データセグメントは検証つきで読む
        let csCache = try descriptorCache(selector: segmentSelectors[1])
        guard csCache.present, csCache.isCode else {
            throw CPUTrap.exception(vector: 10, errorCode: UInt32(segmentSelectors[1] & 0xFFFC))
        }
        segments[1] = segmentSelectors[1]
        segmentCaches[1] = csCache
        let ssCache = try descriptorCache(selector: segmentSelectors[2])
        guard ssCache.present, !ssCache.isCode, ssCache.permitsWrite else {
            throw CPUTrap.exception(vector: 10, errorCode: UInt32(segmentSelectors[2] & 0xFFFC))
        }
        segments[2] = segmentSelectors[2]
        segmentCaches[2] = ssCache
        try loadSegmentRegister(0, segmentSelectors[0]) // ES
        try loadSegmentRegister(3, segmentSelectors[3]) // DS
        try loadSegmentRegister(4, segmentSelectors[4]) // FS
        try loadSegmentRegister(5, segmentSelectors[5]) // GS
        taskRegister = selector
        tssBase = newBase
        tssPresent = true
        controlRegisters[0] |= 0x8 // CR0.TS
    }

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
        devices.cpu = self
    }

    /// ディスクイメージを接続する（BIOS ブート時に呼ばれる）。
    func attachDisk(_ disk: X86DiskImage) {
        attachedDisk = disk
    }

    // MARK: - 公開操作

    /// メモリへデータを配置する（ブートセクタの読み込みなど）。
    func loadData(_ data: [UInt8], at address: Int) {
        guard address >= 0, address + data.count <= memory.count else { return }
        memory.replaceSubrange(address..<(address + data.count), with: data)
    }

    /// CPU 状態を初期位置へ設定する（BIOS ブート用）。
    func resetForBoot(bootDrive: UInt8) {
        registers = [UInt64](repeating: 0, count: 16)
        segments = [UInt16](repeating: 0, count: 6)
        instructionPointer = 0x7C00
        flags = 0x0002
        halted = false
        exitCode = 0
        waitingForInput = false
        waitingForInterrupt = false
        interruptInhibit = 0
        devices.reset()
        controlRegisters = [UInt64](repeating: 0, count: 16)
        efer = 0
        kernelGSBase = 0
        gdtrBase = 0
        gdtrLimit = 0
        idtrBase = 0
        idtrLimit = 0xFFFF
        ldtrSelector = 0
        ldtrCache = SegmentCache()
        taskRegister = 0
        tssBase = 0
        tssPresent = false
        starMSR = 0
        lstarMSR = 0
        cstarMSR = 0
        sfmaskMSR = 0
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
        instructionPointer = UInt64(entry)
        registers[4] = UInt64(stackTop) // ESP
        registers[0] = 0x2BADB002 // EAX: Multiboot マジック
        registers[3] = UInt64(infoAddress) // EBX: Multiboot 情報構造体
        flags = 0x0002 // 割り込み無効
    }

    /// ロングモードの初期状態にする（UEFI ファームウェア用）。
    /// ページテーブルと GDT / IDT は呼び出し側がメモリへ配置済みのこと。
    /// CS は 64 ビット コードセグメント（セレクタ 0x08、L ビット）として
    /// 入り、引数は UEFI の呼び出し規約どおり RCX / RDX に置く。
    func enterLongMode(entry: UInt64, stackTop: UInt64, arg1: UInt64, arg2: UInt64,
                       pageTableBase: UInt32, gdtBase: UInt32, gdtLimit: UInt16,
                       idtBase: UInt32, idtLimit: UInt16) {
        resetForBoot(bootDrive: 0)
        gdtrBase = UInt64(gdtBase)
        gdtrLimit = gdtLimit
        idtrBase = UInt64(idtBase)
        idtrLimit = idtLimit
        controlRegisters[3] = UInt64(pageTableBase) // CR3
        controlRegisters[4] = 0x20 // CR4.PAE
        efer = 0x100 // EFER.LME
        controlRegisters[0] = 0x80000001 // CR0.PE + PG（→ LMA 有効）
        let code64 = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: false, longMode: true, present: true, isCode: true, isExpandDown: false, permitsRead: true, permitsWrite: false)
        let dataFlat = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: true, present: true, isCode: false, isExpandDown: false, permitsRead: true, permitsWrite: true)
        segments[1] = 0x08
        segmentCaches[1] = code64
        for index in [0, 2, 3, 4, 5] {
            segments[index] = 0x10
            segmentCaches[index] = dataFlat
        }
        instructionPointer = entry
        registers[4] = stackTop // RSP
        registers[1] = arg1 // RCX
        registers[2] = arg2 // RDX
        flags = 0x0002
    }

    /// 実行位置を直接移す（UEFI サービスの復帰などファームウェア用）。
    func redirectExecution(to address: UInt64) {
        instructionPointer = address
    }

    /// ゲストを停止させる（BIOS のブート失敗・電源断に相当）。
    func halt(exitCode: Int32) {
        halted = true
        self.exitCode = exitCode
    }

    /// コンソール入力をキューへ追加する（シリアル / BIOS 用に加え、
    /// キーボードコントローラへはスキャンコード化して渡す）。
    func provideInput(_ bytes: [UInt8]) {
        inputQueue.append(contentsOf: bytes)
        if !bytes.isEmpty { waitingForInput = false }
        devices.keyboard.receiveText(bytes)
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

    /// 最大で指定した命令数だけ実行する。停止・入力待ち・割り込み待ちで早期に返る。
    func run(maxInstructions: Int) throws {
        var count = 0
        while !halted && !waitingForInput && !waitingForInterrupt && count < maxInstructions {
            if let hook = preExecuteHook, hook(instructionPointer) {
                count += 1
                instructionsExecuted += 1
                continue
            }
            try serviceInterrupts()
            try step()
            if interruptInhibit > 0 { interruptInhibit -= 1 }
            count += 1
            instructionsExecuted += 1
        }
    }

    /// 配送可能なハードウェア割り込みがあれば命令境界で配送する。
    private func serviceInterrupts() throws {
        devices.updateDevices(now: nowNanos)
        guard interruptInhibit == 0, flag(Self.flagInterrupt) else { return }
        if let vector = devices.lapic.pendingInterrupt() {
            devices.lapic.acknowledge(vector: vector)
            try deliverHardwareInterrupt(vector: vector)
            return
        }
        guard let pending = devices.pic.pendingInterrupt() else { return }
        devices.pic.acknowledge(irq: pending.irq)
        try deliverHardwareInterrupt(vector: pending.vector)
    }

    /// HLT で割り込み待ちの間に割り込みが届いたら配送して実行を再開する。
    @discardableResult
    func pollInterrupts() throws -> Bool {
        guard waitingForInterrupt else { return false }
        devices.updateDevices(now: nowNanos)
        guard flag(Self.flagInterrupt) else { return false }
        if let vector = devices.lapic.pendingInterrupt() {
            devices.lapic.acknowledge(vector: vector)
            waitingForInterrupt = false
            try deliverHardwareInterrupt(vector: vector)
            return true
        }
        guard let pending = devices.pic.pendingInterrupt() else { return false }
        devices.pic.acknowledge(irq: pending.irq)
        waitingForInterrupt = false
        try deliverHardwareInterrupt(vector: pending.vector)
        return true
    }

    /// ハードウェア割り込みの配送（リアルモードは IVT、プロテクトモードは IDT）。
    private func deliverHardwareInterrupt(vector: UInt8) throws {
        if protectedMode {
            try dispatchGate(vector: vector, errorCode: nil, returnIP: instructionPointer)
            return
        }
        let entry = Int(vector) * 4
        let newIP = try readMemory(at: entry, size: 2)
        let newCS = try readMemory(at: entry + 2, size: 2)
        try push(UInt64(flags & 0xFFFF), size: 2)
        try push(UInt64(segments[1]), size: 2)
        try push(instructionPointer, size: 2)
        setFlag(Self.flagInterrupt, false)
        setFlag(Self.flagTrap, false)
        setSegment(1, UInt16(newCS & 0xFFFF))
        instructionPointer = UInt64(newIP & 0xFFFF)
    }

    // MARK: - レジスタアクセス

    func register64(_ index: Int) -> UInt64 { registers[index] }
    func register32(_ index: Int) -> UInt32 { UInt32(registers[index] & 0xFFFFFFFF) }
    func register16(_ index: Int) -> UInt16 { UInt16(registers[index] & 0xFFFF) }
    func register8(_ index: Int) -> UInt8 {
        // REX がある命令では 4〜7 は SPL / BPL / SIL / DIL（下位バイト）
        if decodeREX != 0 || index >= 8 { return UInt8(registers[index] & 0xFF) }
        if index < 4 { return UInt8(registers[index] & 0xFF) }
        return UInt8((registers[index - 4] >> 8) & 0xFF)
    }

    func setRegister64(_ index: Int, _ value: UInt64) { registers[index] = value }
    /// 32 ビット書き込みは上位 32 ビットをゼロにする（x86-64 の仕様）。
    func setRegister32(_ index: Int, _ value: UInt32) { registers[index] = UInt64(value) }
    func setRegister16(_ index: Int, _ value: UInt16) {
        registers[index] = (registers[index] & ~0xFFFF) | UInt64(value)
    }
    func setRegister8(_ index: Int, _ value: UInt8) {
        if decodeREX != 0 || index >= 8 {
            registers[index] = (registers[index] & ~0xFF) | UInt64(value)
        } else if index < 4 {
            registers[index] = (registers[index] & ~0xFF) | UInt64(value)
        } else {
            registers[index - 4] = (registers[index - 4] & ~0xFF00) | (UInt64(value) << 8)
        }
    }

    func segment(_ index: Int) -> UInt16 { segments[index] }

    /// ホスト（BIOS）からのセグメント設定。リアルモード前提で、隠し
    /// キャッシュも実モードの値（base = 値 × 16、limit = 64 KiB）に保つ。
    func setSegment(_ index: Int, _ value: UInt16) {
        segments[index] = value
        if !protectedMode {
            segmentCaches[index] = SegmentCache(base: UInt64(value) << 4, limit: 0xFFFF, defaultSize32: false, present: true, isCode: index == 1, isExpandDown: false, permitsRead: true, permitsWrite: true)
        }
    }

    func setInstructionPointer(_ value: UInt64) { instructionPointer = value }
    func setFlags(_ value: UInt32) { flags = value | 0x0002 }

    /// 現在の CS に適用される IP のマスク（32 ビット CS なら全幅）。
    var ipMask: UInt64 { inLongMode ? UInt64.max : (segmentCaches[1].defaultSize32 ? 0xFFFFFFFF : 0xFFFF) }

    // MARK: - ディスクリプタ

    /// GDT / LDT からディスクリプタを読み、検証済みキャッシュへ変換する。
    private func descriptorCache(selector: UInt16) throws -> SegmentCache {
        let tableBase: UInt64
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
        let address = Int(tableBase + UInt64(offset))
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
        let base = UInt64(baseLow | (baseMiddle << 16) | (baseHigh << 24))
        let isSystem = access & 0x10 == 0
        let type = access & 0x0F
        return SegmentCache(
            base: base,
            limit: limit,
            defaultSize32: granularity & 0x4 != 0,
            longMode: granularity & 0x2 != 0,
            present: access & 0x80 != 0,
            isCode: !isSystem && type & 0x8 != 0,
            isExpandDown: !isSystem && type & 0x8 == 0 && type & 0x4 != 0,
            permitsRead: isSystem ? false : (type & 0x8 == 0 || type & 0x2 != 0),
            permitsWrite: isSystem ? false : (type & 0x8 == 0 && type & 0x2 != 0),
            dpl: Int((access >> 5) & 0x3),
            conforming: !isSystem && type & 0x8 != 0 && type & 0x4 != 0
        )
    }

    /// ゲスト命令によるセグメントレジスタのロード。プロテクトモードでは
    /// ディスクリプタを検証する（CS は far 転送専用のためここでは扱わない）。
    func loadSegmentRegister(_ index: Int, _ selector: UInt16) throws {
        guard (0...5).contains(index) else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
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
        // 特権チェック: データセグメントは max(CPL, RPL) <= DPL、
        // SS は DPL = CPL かつ RPL = CPL が必要
        let requestLevel = Int(selector & 0x3)
        if index == 2 {
            guard cache.dpl == currentPrivilegeLevel, requestLevel == currentPrivilegeLevel else {
                throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
            }
        } else if !cache.isCode || cache.permitsRead {
            guard max(currentPrivilegeLevel, requestLevel) <= cache.dpl else {
                throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
            }
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

    /// ゲストの far 転送（JMP FAR / CALL FAR / RETF / IRET）で CS を
    /// ロードする。特権検査を行う: 非適合セグメントは転送では
    /// DPL == CPL、戻りでは DPL >= CPL が必要。適合セグメントは
    /// DPL <= CPL で、CPL は変わらない。
    func loadCodeSegmentForTransfer(_ selector: UInt16, isReturn: Bool) throws {
        guard protectedMode else {
            try loadCodeSegment(selector)
            return
        }
        guard selector & 0xFFF8 != 0 else {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
        let cache = try descriptorCache(selector: selector)
        guard cache.present, cache.isCode else {
            throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
        }
        if cache.conforming {
            guard cache.dpl <= currentPrivilegeLevel else {
                throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
            }
            var adjusted = cache
            adjusted.dpl = currentPrivilegeLevel
            segments[1] = selector
            segmentCaches[1] = adjusted
        } else {
            let allowed = isReturn ? cache.dpl >= currentPrivilegeLevel : cache.dpl == currentPrivilegeLevel
            guard allowed else {
                throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
            }
            segments[1] = selector
            segmentCaches[1] = cache
        }
    }

    func flag(_ bit: UInt32) -> Bool { flags & bit != 0 }
    func setFlag(_ bit: UInt32, _ on: Bool) {
        flags = on ? (flags | bit) : (flags & ~bit)
    }

    /// POPF / IRET 系のフラグ復元。CPL != 0 では IOPL を保持し、
    /// CPL > 現在の IOPL では IF も保持する（実機の規則）。
    func flagsAfterRestore(_ value: UInt64, keepHighHalf: Bool, cpl: Int) -> UInt32 {
        var result = (UInt32(value & 0xFFFFFFFF) & 0x3FD5) | 0x0002
        let currentIOPL = (flags >> 12) & 0x3
        if cpl != 0 {
            result = (result & ~0x3000) | (flags & 0x3000)
        }
        if UInt32(cpl) > currentIOPL {
            result = (result & ~0x0200) | (flags & 0x0200)
        }
        if keepHighHalf {
            result |= flags & 0xFFFF0000
        }
        return result
    }

    // MARK: - メモリアクセス

    func physicalAddress(segment: UInt16, offset: UInt32) -> Int {
        (Int(segment) << 4) + Int(offset)
    }

    func readMemory8(at address: Int) throws -> UInt8 {
        guard address >= 0, address < memory.count else {
            throw X86Fault.memoryOutOfBounds(address: UInt64(bitPattern: Int64(address)))
        }
        return memory[address]
    }

    func writeMemory8(at address: Int, _ value: UInt8) throws {
        guard address >= 0, address < memory.count else {
            throw X86Fault.memoryOutOfBounds(address: UInt64(bitPattern: Int64(address)))
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

    /// 任意サイズの値を UInt64 で読む（ページテーブル走査など内部用）。
    func readMemoryValue(at address: Int, size: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<size {
            value |= UInt64(try readMemory8(at: address + i)) << (8 * i)
        }
        return value
    }

    /// 任意サイズの値を UInt64 で書く（内部用）。
    func writeMemoryValue(at address: Int, size: Int, _ value: UInt64) throws {
        for i in 0..<size {
            try writeMemory8(at: address + i, UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    // MARK: - ゲストメモリアクセス（セグメント変換 + ページング）

    /// セグメントキャッシュ経由のリニアアドレスを求める。
    func linearAddress(segmentIndex: Int, offset: UInt64) -> UInt64 {
        segmentCaches[segmentIndex].base &+ offset
    }

    /// プロテクトモード時のセグメント範囲・権限チェック。
    private func checkSegmentAccess(_ segmentIndex: Int, offset: UInt64, size: Int, isWrite: Bool) throws {
        // ロングモードではセグメント範囲チェックは行われない
        guard protectedMode, !inLongMode else { return }
        let cache = segmentCaches[segmentIndex]
        let errorCode = UInt32(segments[segmentIndex] & 0xFFFC)
        guard cache.present else { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        if isWrite && !cache.permitsWrite { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        if !isWrite && !cache.permitsRead && !cache.isCode { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        let last = offset &+ UInt64(size - 1)
        if cache.isExpandDown {
            let floor = UInt64(cache.limit) &+ 1
            let ceiling: UInt64 = cache.defaultSize32 ? 0xFFFFFFFF : 0xFFFF
            if offset < floor || last > ceiling { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }
        } else if last > UInt64(cache.limit) {
            throw CPUTrap.exception(vector: 13, errorCode: errorCode)
        }
    }

    /// ページング変換（線形 → 物理）。ページ不在などは #PF を送出する。
    /// 戻り値は物理アドレス。RAM の範囲内かどうかは呼び出し側が判定する
    /// （MMIO 領域もここを通るため）。
    private func translate(linear: UInt64, isWrite: Bool, isFetch: Bool) throws -> UInt64 {
        guard pagingEnabled else { return linear }
        if longModeActive || controlRegisters[4] & 0x20 != 0 {
            return try translatePAE(linear: linear, isWrite: isWrite, isFetch: isFetch)
        }
        let directoryBase = controlRegisters[3] & 0xFFFFF000
        let directoryIndex = (linear >> 22) & 0x3FF
        let pdeAddress = Int(directoryBase + directoryIndex * 4)
        var pde = try readMemoryValue(at: pdeAddress, size: 4)
        func pageFault(present: Bool) -> CPUTrap {
            controlRegisters[2] = linear
            var code: UInt32 = 0
            if present { code |= 0x01 }
            if isWrite { code |= 0x02 }
            if isFetch { code |= 0x10 }
            if currentPrivilegeLevel == 3 { code |= 0x04 }
            return .exception(vector: 14, errorCode: code)
        }
        guard pde & 1 != 0 else { throw pageFault(present: false) }
        if currentPrivilegeLevel == 3 && pde & 0x4 == 0 {
            controlRegisters[2] = linear
            var code: UInt32 = 0x01 | 0x04
            if isWrite { code |= 0x02 }
            if isFetch { code |= 0x10 }
            throw CPUTrap.exception(vector: 14, errorCode: code)
        }
        if pde & 0x80 != 0 {
            if isWrite && pde & 0x2 == 0 && (currentPrivilegeLevel == 3 || controlRegisters[0] & 0x10000 != 0) {
                controlRegisters[2] = linear
                var code: UInt32 = 0x01 | 0x02
                if currentPrivilegeLevel == 3 { code |= 0x04 }
                throw CPUTrap.exception(vector: 14, errorCode: code)
            }
            // 4 MiB ページ（PSE）
            if pde & 0x20 == 0 || (isWrite && pde & 0x40 == 0) {
                pde |= 0x20
                if isWrite { pde |= 0x40 }
                try writeMemoryValue(at: pdeAddress, size: 4, pde)
            }
            return (pde & 0xFFC00000) | (linear & 0x3FFFFF)
        }
        let tableIndex = (linear >> 12) & 0x3FF
        let pteAddress = Int((pde & 0xFFFFF000) + tableIndex * 4)
        var pte = try readMemoryValue(at: pteAddress, size: 4)
        guard pte & 1 != 0 else { throw pageFault(present: false) }
        if currentPrivilegeLevel == 3 && pte & 0x4 == 0 {
            controlRegisters[2] = linear
            var code: UInt32 = 0x01 | 0x04
            if isWrite { code |= 0x02 }
            if isFetch { code |= 0x10 }
            throw CPUTrap.exception(vector: 14, errorCode: code)
        }
        if isWrite && (pde & 0x2 == 0 || pte & 0x2 == 0) && (currentPrivilegeLevel == 3 || controlRegisters[0] & 0x10000 != 0) {
            controlRegisters[2] = linear
            var code: UInt32 = 0x01 | 0x02
            if currentPrivilegeLevel == 3 { code |= 0x04 }
            throw CPUTrap.exception(vector: 14, errorCode: code)
        }
        if pde & 0x20 == 0 {
            try writeMemoryValue(at: pdeAddress, size: 4, pde | 0x20)
        }
        if pte & 0x20 == 0 || (isWrite && pte & 0x40 == 0) {
            pte |= 0x20
            if isWrite { pte |= 0x40 }
            try writeMemoryValue(at: pteAddress, size: 4, pte)
        }
        return (pte & 0xFFFFF000) | (linear & 0xFFF)
    }

    /// PAE / ロングモードのページウォーク（8 バイトエントリ、2 MiB / 1 GiB
    /// ラージページ、NX ビット対応）。
    private func translatePAE(linear: UInt64, isWrite: Bool, isFetch: Bool) throws -> UInt64 {
        func pageFault(present: Bool) -> CPUTrap {
            controlRegisters[2] = linear
            var code: UInt32 = 0
            if present { code |= 0x01 }
            if isWrite { code |= 0x02 }
            if isFetch { code |= 0x10 }
            if currentPrivilegeLevel == 3 { code |= 0x04 }
            return .exception(vector: 14, errorCode: code)
        }
        if longModeActive {
            // 正準アドレスチェック（ビット 47 の符号拡張）
            let bit47 = (linear >> 47) & 1
            let upper = linear >> 48
            guard upper == (bit47 == 1 ? 0xFFFF : 0) else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
        }
        let nxEnabled = efer & 0x800 != 0
        var tablePhysical = longModeActive ? (controlRegisters[3] & ~0xFFF) : (controlRegisters[3] & ~0x1F)
        let levelShifts: [UInt64] = longModeActive ? [39, 30, 21, 12] : [30, 21, 12]
        var effectiveWritable = true
        for (level, shift) in levelShifts.enumerated() {
            let index = (linear >> shift) & 0x1FF
            let entryAddress = tablePhysical + index * 8
            var entry = try readMemoryValue(at: Int(entryAddress), size: 8)
            guard entry & 1 != 0 else { throw pageFault(present: false) }
            if currentPrivilegeLevel == 3 && entry & 0x4 == 0 && (longModeActive || level > 0) {
                controlRegisters[2] = linear
                var usCode: UInt32 = 0x01 | 0x04
                if isWrite { usCode |= 0x02 }
                if isFetch { usCode |= 0x10 }
                throw CPUTrap.exception(vector: 14, errorCode: usCode)
            }
            effectiveWritable = effectiveWritable && entry & 0x2 != 0
            let isLast = level == levelShifts.count - 1
            let largePageAllowed = shift == 21 || (shift == 30 && longModeActive)
            if !isLast && largePageAllowed && entry & 0x80 != 0 {
                if isFetch && nxEnabled && entry >> 63 != 0 { throw pageFault(present: true) }
                if isWrite && !effectiveWritable && (currentPrivilegeLevel == 3 || controlRegisters[0] & 0x10000 != 0) {
                    controlRegisters[2] = linear
                    var code: UInt32 = 0x01 | 0x02
                    if currentPrivilegeLevel == 3 { code |= 0x04 }
                    throw CPUTrap.exception(vector: 14, errorCode: code)
                }

                var updated = entry | 0x20
                if isWrite { updated |= 0x40 }
                if updated != entry { try writeMemoryValue(at: Int(entryAddress), size: 8, updated) }
                entry = updated
                if shift == 30 {
                    return (entry & 0x000FFFFFC0000000) | (linear & 0x3FFFFFFF)
                }
                return (entry & 0x000FFFFFFFE00000) | (linear & 0x1FFFFF)
            }
            if isLast {
                if isFetch && nxEnabled && entry >> 63 != 0 { throw pageFault(present: true) }
                if isWrite && !effectiveWritable && (currentPrivilegeLevel == 3 || controlRegisters[0] & 0x10000 != 0) {
                    controlRegisters[2] = linear
                    var code: UInt32 = 0x01 | 0x02
                    if currentPrivilegeLevel == 3 { code |= 0x04 }
                    throw CPUTrap.exception(vector: 14, errorCode: code)
                }

                var updated = entry | 0x20
                if isWrite { updated |= 0x40 }
                if updated != entry { try writeMemoryValue(at: Int(entryAddress), size: 8, updated) }
                return (entry & 0x000FFFFFFFFFF000) | (linear & 0xFFF)
            }
            if entry & 0x20 == 0 {
                try writeMemoryValue(at: Int(entryAddress), size: 8, entry | 0x20)
            }
            tablePhysical = entry & 0x000FFFFFFFFFF000
        }
        throw pageFault(present: false)
    }

    /// ゲストのデータ読み取り（セグメント + ページング適用）。
    func readGuest(segmentIndex: Int, offset: UInt64, size: Int) throws -> UInt64 {
        try checkSegmentAccess(segmentIndex, offset: offset, size: size, isWrite: false)
        let linear = linearAddress(segmentIndex: segmentIndex, offset: offset)
        let firstPhysical = try translate(linear: linear, isWrite: false, isFetch: false)
        if X86DeviceBus.isMMIOAddress(firstPhysical) {
            return devices.readMMIO(physical: firstPhysical, size: size)
        }
        var value: UInt64 = 0
        for i in 0..<size {
            let physical = try translate(linear: linear &+ UInt64(i), isWrite: false, isFetch: false)
            guard physical < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
            value |= UInt64(memory[Int(physical)]) << (8 * i)
        }
        return value
    }

    /// ゲストのデータ書き込み（セグメント + ページング適用）。
    func writeGuest(segmentIndex: Int, offset: UInt64, size: Int, _ value: UInt64) throws {
        try checkSegmentAccess(segmentIndex, offset: offset, size: size, isWrite: true)
        let linear = linearAddress(segmentIndex: segmentIndex, offset: offset)
        let firstPhysical = try translate(linear: linear, isWrite: true, isFetch: false)
        if X86DeviceBus.isMMIOAddress(firstPhysical) {
            devices.writeMMIO(physical: firstPhysical, size: size, value)
            return
        }
        for i in 0..<size {
            let physical = try translate(linear: linear &+ UInt64(i), isWrite: true, isFetch: false)
            guard physical < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
            memory[Int(physical)] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }

    /// 物理メモリの直接読み取り（ページテーブル走査・ホスト処理用）。
    func readPhysical(at address: Int, size: Int) throws -> UInt32 {
        try readMemory(at: address, size: size)
    }

    // MARK: - フェッチ

    private func fetch8() throws -> UInt8 {
        if protectedMode && !inLongMode && instructionPointer > UInt64(segmentCaches[1].limit) {
            throw CPUTrap.exception(vector: 13, errorCode: 0)
        }
        let linear = linearAddress(segmentIndex: 1, offset: instructionPointer)
        let physical = try translate(linear: linear, isWrite: false, isFetch: true)
        guard physical < memory.count else { throw X86Fault.memoryOutOfBounds(address: linear) }
        let value = memory[Int(physical)]
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
    /// 現在デコード中の命令の REX プリフィクス（0 = なし）。64 ビット
    /// モードでのみ現れる。
    private(set) var decodeREX: UInt8 = 0

    private struct ModRM {
        var reg: Int
        var isRegister: Bool
        var registerIndex: Int
        var segmentIndex: Int
        /// セグメント内のオフセット（LEA 用）
        var effectiveOffset: UInt64
        /// RIP 相対アドレッシング（64 ビットモード、mod=0 / r/m=5）。
        var ripRelative = false
        var ripDisplacement: Int64 = 0
    }

    /// RIP 相対を解決した実効オフセット。命令全体をフェッチし終えた
    /// 時点（オペランド読み書き時）の IP を基準にする。
    private func resolvedOffset(_ operand: ModRM) -> UInt64 {
        if operand.ripRelative {
            return UInt64(bitPattern: Int64(bitPattern: instructionPointer) &+ operand.ripDisplacement)
        }
        return operand.effectiveOffset
    }

    /// ModR/M バイトを読み、実効アドレス（セグメント内オフセット）を解決する。
    private func decodeModRM() throws -> ModRM {
        let byte = try fetch8()
        let mod = Int(byte >> 6)
        let reg = Int((byte >> 3) & 7) | (decodeREX & 0x04 != 0 ? 8 : 0) // REX.R
        let rm = Int(byte & 7)
        if mod == 3 {
            let registerIndex = rm | (decodeREX & 0x01 != 0 ? 8 : 0) // REX.B
            return ModRM(reg: reg, isRegister: true, registerIndex: registerIndex, segmentIndex: 3, effectiveOffset: 0)
        }
        if decodeAddressSize != 2 {
            return try decodeModRM32(mod: mod, reg: reg, rm: rm)
        }
        var offset: UInt64 = 0
        var defaultSegment = 3 // DS
        switch rm {
        case 0: offset = UInt64(register16(3)) &+ UInt64(register16(6))
        case 1: offset = UInt64(register16(3)) &+ UInt64(register16(7))
        case 2: offset = UInt64(register16(5)) &+ UInt64(register16(6)); defaultSegment = 2
        case 3: offset = UInt64(register16(5)) &+ UInt64(register16(7)); defaultSegment = 2
        case 4: offset = UInt64(register16(6))
        case 5: offset = UInt64(register16(7))
        case 6:
            if mod == 0 {
                offset = UInt64(try fetch16())
            } else {
                offset = UInt64(register16(5)); defaultSegment = 2
            }
        case 7: offset = UInt64(register16(3))
        default: break
        }
        if mod == 0 {
            offset &= 0xFFFF // 16 ビットアドレッシングでは基底の和も 16 ビットに巻き戻る
        }
        if mod == 1 {
            let displacement = Int8(bitPattern: try fetch8())
            offset = (offset &+ UInt64(bitPattern: Int64(displacement))) & 0xFFFF
        } else if mod == 2 {
            let displacement = Int16(bitPattern: try fetch16())
            offset = (offset &+ UInt64(bitPattern: Int64(displacement))) & 0xFFFF
        }
        let segmentIndex = decodeSegmentOverride ?? defaultSegment
        return ModRM(reg: reg, isRegister: false, registerIndex: rm, segmentIndex: segmentIndex, effectiveOffset: offset)
    }

    /// 32 / 64 ビットアドレッシングの ModR/M（SIB バイト、REX 拡張、
    /// RIP 相対対応）。
    private func decodeModRM32(mod: Int, reg: Int, rm: Int) throws -> ModRM {
        var offset: UInt64 = 0
        var defaultSegment = 3 // DS
        var ripRelative = false
        var ripDisplacement: Int64 = 0
        let rexB = decodeREX & 0x01 != 0
        if rm == 4 {
            // SIB バイト
            let sib = try fetch8()
            let scale = Int(sib >> 6)
            let rawIndex = Int((sib >> 3) & 7)
            let rawBase = Int(sib & 7)
            let index = rawIndex | (decodeREX & 0x02 != 0 ? 8 : 0) // REX.X
            let base = rawBase | (rexB ? 8 : 0)
            if !(rawIndex == 4 && decodeREX & 0x02 == 0) {
                offset = offset &+ (registers[index] &<< scale)
            }
            if rawBase == 5 && mod == 0 {
                let displacement = Int32(bitPattern: try fetch32())
                offset = offset &+ UInt64(bitPattern: Int64(displacement))
                if rexB { offset = offset &+ registers[base] }
            } else {
                offset = offset &+ registers[base]
                if rawBase == 5 { defaultSegment = 2 } // EBP / RBP ベースは SS
            }
        } else if rm == 5 && mod == 0 {
            let displacement = Int32(bitPattern: try fetch32())
            if decodeAddressSize == 8 {
                ripRelative = true
                ripDisplacement = Int64(displacement)
            } else {
                offset = UInt64(UInt32(bitPattern: displacement))
            }
        } else {
            let base = rm | (rexB ? 8 : 0)
            offset = registers[base]
            if rm == 5 { defaultSegment = 2 } // EBP は SS
        }
        if mod == 1 {
            let displacement = Int8(bitPattern: try fetch8())
            offset = offset &+ UInt64(bitPattern: Int64(displacement))
        } else if mod == 2 {
            let displacement = Int32(bitPattern: try fetch32())
            offset = offset &+ UInt64(bitPattern: Int64(displacement))
        }
        if decodeAddressSize == 4 { offset &= 0xFFFFFFFF }
        let segmentIndex = decodeSegmentOverride ?? defaultSegment
        return ModRM(reg: reg, isRegister: false, registerIndex: rm, segmentIndex: segmentIndex, effectiveOffset: offset, ripRelative: ripRelative, ripDisplacement: ripDisplacement)
    }

    private func readOperand(_ operand: ModRM, size: Int) throws -> UInt64 {
        if operand.isRegister {
            return registerValue(operand.registerIndex, size: size)
        }
        return try readGuest(segmentIndex: operand.segmentIndex, offset: resolvedOffset(operand), size: size)
    }

    private func writeOperand(_ operand: ModRM, size: Int, _ value: UInt64) throws {
        if operand.isRegister {
            setRegisterValue(operand.registerIndex, size: size, value)
        } else {
            try writeGuest(segmentIndex: operand.segmentIndex, offset: resolvedOffset(operand), size: size, value)
        }
    }

    // MARK: - フラグ計算

    private func mask(forSize size: Int) -> UInt64 {
        switch size {
        case 1: return 0xFF
        case 2: return 0xFFFF
        case 4: return 0xFFFFFFFF
        default: return UInt64.max
        }
    }

    private func setSignZeroParity(_ result: UInt64, size: Int) {
        let value = result & mask(forSize: size)
        setFlag(Self.flagSign, value & (UInt64(1) << (size * 8 - 1)) != 0)
        setFlag(Self.flagZero, value == 0)
        setFlag(Self.flagParity, (value & 0xFF).nonzeroBitCount % 2 == 0)
    }

    /// 加算系（ADD / ADC）のフラグを更新して結果を返す。
    private func addWithFlags(_ a: UInt64, _ b: UInt64, size: Int, carryIn: Bool) -> UInt64 {
        let m = mask(forSize: size)
        let av = a & m
        let bv = b & m
        let full = av &+ bv &+ (carryIn ? 1 : 0)
        let result = full & m
        let carriedOut: Bool
        if size == 8 {
            carriedOut = full < av || (carryIn && full == av)
        } else {
            carriedOut = (av + bv + (carryIn ? 1 : 0)) > m
        }
        setFlag(Self.flagCarry, carriedOut)
        let signBit = UInt64(1) << (size * 8 - 1)
        setFlag(Self.flagOverflow, ((~(av ^ bv) & (av ^ result)) & signBit) != 0)
        setFlag(Self.flagAuxCarry, ((av ^ bv ^ result) & 0x10) != 0)
        setSignZeroParity(result, size: size)
        return result
    }

    /// 減算系（SUB / SBB / CMP）のフラグを更新して結果を返す。
    private func subtractWithFlags(_ a: UInt64, _ b: UInt64, size: Int, borrowIn: Bool) -> UInt64 {
        let m = mask(forSize: size)
        let av = a & m
        let bv = b & m
        let result = (av &- bv &- (borrowIn ? 1 : 0)) & m
        setFlag(Self.flagCarry, av < bv || (borrowIn && av == bv))
        let signBit = UInt64(1) << (size * 8 - 1)
        setFlag(Self.flagOverflow, (((av ^ bv) & (av ^ result)) & signBit) != 0)
        setFlag(Self.flagAuxCarry, ((av ^ bv ^ result) & 0x10) != 0)
        setSignZeroParity(result, size: size)
        return result
    }

    /// 論理演算のフラグ（CF / OF はクリア）。
    private func logicFlags(_ result: UInt64, size: Int) -> UInt64 {
        setFlag(Self.flagCarry, false)
        setFlag(Self.flagOverflow, false)
        setFlag(Self.flagAuxCarry, false)
        setSignZeroParity(result, size: size)
        return result & mask(forSize: size)
    }

    /// ALU 演算。operation: 0=ADD 1=OR 2=ADC 3=SBB 4=AND 5=SUB 6=XOR 7=CMP
    private func alu(_ operation: Int, _ a: UInt64, _ b: UInt64, size: Int) -> UInt64 {
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

    /// 現在のスタックポインタ（ロングモードでは RSP 全幅、SS の B ビットが
    /// 立っていれば ESP、そうでなければ SP）。
    private var stackPointer: UInt64 {
        if inLongMode { return registers[4] }
        return segmentCaches[2].defaultSize32 ? (registers[4] & 0xFFFFFFFF) : UInt64(register16(4))
    }

    private func setStackPointer(_ value: UInt64) {
        if inLongMode {
            registers[4] = value
        } else if segmentCaches[2].defaultSize32 {
            registers[4] = value & 0xFFFFFFFF
        } else {
            setRegister16(4, UInt16(value & 0xFFFF))
        }
    }

    /// PUSH / POP / CALL / RET などのスタック操作幅。ロングモードでは
    /// 既定 8 バイト（0x66 のとき 2 バイト）になる。
    private func stackOperandSize(_ operandSize: Int) -> Int {
        inLongMode ? (operandSize == 2 ? 2 : 8) : operandSize
    }

    private func push(_ value: UInt64, size: Int) throws {
        let newPointer = stackPointer &- UInt64(size)
        setStackPointer(newPointer)
        try writeGuest(segmentIndex: 2, offset: newPointer, size: size, value)
    }

    private func pop(size: Int) throws -> UInt64 {
        let pointer = stackPointer
        let value = try readGuest(segmentIndex: 2, offset: pointer, size: size)
        setStackPointer(pointer &+ UInt64(size))
        return value
    }

    // MARK: - シフト / ローテート

    /// kind: 0=ROL 1=ROR 2=RCL 3=RCR 4=SHL 5=SHR 7=SAR
    private func shift(_ kind: Int, _ value: UInt64, _ rawCount: Int, size: Int) -> UInt64 {
        let m = mask(forSize: size)
        let v = value & m
        let count = rawCount & (size == 8 ? 63 : 31)
        if count == 0 { return v }
        let bits = size * 8
        var result: UInt64 = v
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
                    current = (current >> 1) | (carry ? (UInt64(1) << (bits - 1)) : 0)
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
            let signed = signExtend(v, size: size)
            if count >= bits {
                result = signed < 0 ? m : 0
                setFlag(Self.flagCarry, signed < 0)
            } else {
                setFlag(Self.flagCarry, count == 0 ? carry : ((v >> (count - 1)) & 1 != 0))
                result = UInt64(bitPattern: signed >> count) & m
            }
            if count == 1 { setFlag(Self.flagOverflow, false) }
            setSignZeroParity(result, size: size)
        default:
            break
        }
        return result & m
    }

    // MARK: - 実行

    /// 即値を読む。64 ビットオペランドでは imm32 を符号拡張する
    /// （MOVABS など 8 バイト即値が必要な命令は fetchImmediate を使う）。
    private func fetchSignExtendedImmediate(_ size: Int) throws -> UInt64 {
        if size == 8 {
            return UInt64(bitPattern: Int64(Int32(bitPattern: try fetch32())))
        }
        return try fetchImmediate(size)
    }

    private func fetchImmediate(_ size: Int) throws -> UInt64 {
        switch size {
        case 1: return UInt64(try fetch8())
        case 2: return UInt64(try fetch16())
        case 4: return UInt64(try fetch32())
        default:
            let low = UInt64(try fetch32())
            let high = UInt64(try fetch32())
            return low | (high << 32)
        }
    }

    private func incrementWithFlags(_ value: UInt64, size: Int, decrement: Bool) -> UInt64 {
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

    private func stepDecode(startIP: UInt64) throws {
        let mode64 = inLongMode
        let defaultOperand = mode64 ? 4 : (segmentCaches[1].defaultSize32 ? 4 : 2)
        let defaultAddress = mode64 ? 8 : defaultOperand
        var operandSize = defaultOperand
        var addressSize = defaultAddress
        var segmentOverride: Int?
        var repeatPrefix: UInt8 = 0
        var rex: UInt8 = 0
        while true {
            let byte = try fetch8()
            // REX の直後が別のプレフィクスバイトなら、その REX は無効になる
            if rex != 0 {
                switch byte {
                case 0x66, 0x67, 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0xF0, 0xF2, 0xF3:
                    rex = 0
                default: break
                }
            }
            switch byte {
            case 0x66: operandSize = operandSize == defaultOperand ? (defaultOperand == 2 ? 4 : 2) : defaultOperand
            case 0x67: addressSize = addressSize == defaultAddress ? (defaultAddress == 8 ? 4 : (defaultAddress == 2 ? 4 : 2)) : defaultAddress
            case 0x26: segmentOverride = 0
            case 0x2E: segmentOverride = 1
            case 0x36: segmentOverride = 2
            case 0x3E: segmentOverride = 3
            case 0x64: segmentOverride = 4
            case 0x65: segmentOverride = 5
            case 0xF2: repeatPrefix = 0xF2
            case 0xF3: repeatPrefix = 0xF3
            case 0xF0: continue
            case 0x40...0x4F where mode64:
                rex = byte // REX プリフィクス（64 ビットモードのみ）
            default:
                if rex & 0x08 != 0 { operandSize = 8 } // REX.W
                decodeOperandSize = operandSize
                decodeAddressSize = addressSize
                decodeSegmentOverride = segmentOverride
                decodeREX = rex
                defer { decodeREX = 0 }
                try execute(opcode: byte, operandSize: operandSize, repeatPrefix: repeatPrefix, startIP: startIP)
                return
            }
        }
    }

    /// IDT ゲート経由で割り込み / 例外を配送する（プロテクトモード用）。
    /// ロングモード有効時は 16 バイトゲート + 8 バイトプッシュになる。
    private func dispatchGate(vector: UInt8, errorCode: UInt32?, returnIP: UInt64) throws {
        if longModeActive {
            try dispatchGate64(vector: vector, errorCode: errorCode, returnIP: returnIP)
            return
        }
        let entryOffset = UInt32(vector) * 8
        guard entryOffset + 7 <= UInt32(idtrLimit) else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let address = Int(idtrBase + UInt64(entryOffset))
        let low = try readMemory(at: address, size: 4)
        let high = try readMemory(at: address + 4, size: 4)
        let access = (high >> 8) & 0xFF
        let gateType = access & 0x1F
        if gateType == 0x5 {
            // タスクゲート: ゲート内の TSS セレクタへ切り替える
            guard access & 0x80 != 0 else {
                throw X86Fault.exceptionUndeliverable(vector)
            }
            let tssSelector = UInt16((low >> 16) & 0xFFFF)
            try switchTask(toTSSSelector: tssSelector, kind: .nested, returnIP: returnIP)
            return
        }
        guard access & 0x80 != 0, gateType == 0xE || gateType == 0xF || gateType == 0x6 || gateType == 0x7 else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let selector = UInt16((low >> 16) & 0xFFFF)
        let is32BitGate = gateType == 0xE || gateType == 0xF
        let offset: UInt32 = is32BitGate ? ((high & 0xFFFF0000) | (low & 0xFFFF)) : (low & 0xFFFF)
        let size = is32BitGate ? 4 : 2
        let savedFlags = flags
        let savedCS = segments[1]
        let savedSS = segments[2]
        let savedSP = registers[4]
        // より特権の高いレベルへ移る場合は TSS の ESP0 へ切り替え、
        // 旧 SS / ESP を新しいスタックへ積む
        var switchedStack = false
        if let targetCache = try? descriptorCache(selector: selector),
           targetCache.dpl < currentPrivilegeLevel,
           let kernelStack = tssStackPointer0() {
            registers[4] = kernelStack
            switchedStack = true
            // SS も TSS の SS0 へ切り替える（32 ビット TSS: SS0 は +8）
            if let ss0 = try? readMemoryValue(at: Int(tssBase + 8), size: 2), ss0 & 0xFFF8 != 0 {
                segments[2] = UInt16(ss0)
                if let ssCache = try? descriptorCache(selector: UInt16(ss0)) {
                    segmentCaches[2] = ssCache
                }
            }
        }
        try loadCodeSegment(selector)
        if switchedStack {
            try push(UInt64(savedSS), size: size)
            try push(savedSP & (size == 4 ? 0xFFFFFFFF : 0xFFFF), size: size)
        }
        try push(UInt64(savedFlags), size: size)
        try push(UInt64(savedCS), size: size)
        try push(returnIP, size: size)
        if let errorCode {
            try push(UInt64(errorCode), size: size)
        }
        if gateType == 0xE || gateType == 0x6 {
            setFlag(Self.flagInterrupt, false)
        }
        instructionPointer = UInt64(offset) & ipMask
    }

    /// ロングモードのゲート配送（16 バイト IDT エントリ、SS / RSP /
    /// RFLAGS / CS / RIP の 8 バイトプッシュ。特権レベルをまたぐ場合は
    /// TSS の RSP0 へ、IST 指定のゲートは TSS の IST スタックへ切り替える）。
    private func dispatchGate64(vector: UInt8, errorCode: UInt32?, returnIP: UInt64) throws {
        let entryOffset = UInt64(vector) * 16
        guard entryOffset + 15 <= UInt64(idtrLimit) else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let address = Int(idtrBase + entryOffset)
        let low = try readMemoryValue(at: address, size: 8)
        let high = try readMemoryValue(at: address + 8, size: 8)
        let access = (low >> 40) & 0xFF
        let gateType = access & 0x1F
        guard access & 0x80 != 0, gateType == 0xE || gateType == 0xF else {
            throw X86Fault.exceptionUndeliverable(vector)
        }
        let selector = UInt16((low >> 16) & 0xFFFF)
        let offset = (low & 0xFFFF) | (((low >> 48) & 0xFFFF) << 16) | ((high & 0xFFFFFFFF) << 32)
        let savedFlags = flags
        let savedCS = segments[1]
        let savedSS = segments[2]
        let savedRSP = registers[4]
        // IST 指定のゲートは TSS の IST スタックを、それ以外で特権レベルを
        // またぐ場合は TSS の RSP0 を使う
        let istIndex = Int((low >> 32) & 0x7)
        if istIndex != 0 && tssPresent {
            if let istStack = try? readMemoryValue(at: Int(tssBase) + 36 + (istIndex - 1) * 8, size: 8) {
                registers[4] = istStack
            }
        } else if let targetCache = try? descriptorCache(selector: selector),
                  targetCache.dpl < currentPrivilegeLevel,
                  let kernelStack = tssStackPointer0() {
            registers[4] = kernelStack
        }
        try loadCodeSegment(selector)
        try push(UInt64(savedSS), size: 8)
        try push(savedRSP, size: 8)
        try push(UInt64(savedFlags), size: 8)
        try push(UInt64(savedCS), size: 8)
        try push(returnIP, size: 8)
        if let errorCode {
            try push(UInt64(errorCode), size: 8)
        }
        if gateType == 0xE {
            setFlag(Self.flagInterrupt, false)
        }
        instructionPointer = offset
    }

    private func execute(opcode: UInt8, operandSize: Int, repeatPrefix: UInt8, startIP: UInt64) throws {
        let address = linearAddress(segmentIndex: 1, offset: startIP)

        // ALU グリッド（0x00〜0x3D）とセグメント push/pop、BCD 補正
        if opcode <= 0x3D {
            switch opcode {
            case 0x06: // PUSH ES（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try push(UInt64(segments[0]), size: stackOperandSize(operandSize)); return
            case 0x07: // POP ES（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try loadSegmentRegister(0, UInt16(try pop(size: stackOperandSize(operandSize)) & 0xFFFF)); return
            case 0x0E: // PUSH CS（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try push(UInt64(segments[1]), size: stackOperandSize(operandSize)); return
            case 0x16: // PUSH SS（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try push(UInt64(segments[2]), size: stackOperandSize(operandSize)); return
            case 0x17: // POP SS（64 ビットモードでは #UD。次の命令までは割り込みを受け付けない）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try loadSegmentRegister(2, UInt16(try pop(size: stackOperandSize(operandSize)) & 0xFFFF))
                interruptInhibit = 2
                return
            case 0x1E: // PUSH DS（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try push(UInt64(segments[3]), size: stackOperandSize(operandSize)); return
            case 0x1F: // POP DS（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                try loadSegmentRegister(3, UInt16(try pop(size: stackOperandSize(operandSize)) & 0xFFFF)); return
            case 0x27, 0x2F, 0x37, 0x3F: // BCD 補正（64 ビットモードでは #UD）
                guard !inLongMode else { throw opcodeFault(opcode, address: address) }
                executeBCDAdjust(opcode); return
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
            let index = Int(opcode - 0x40) | (decodeREX & 0x01 != 0 ? 8 : 0)
            let result = incrementWithFlags(registerValue(index, size: operandSize), size: operandSize, decrement: false)
            setRegisterValue(index, size: operandSize, result)
        case 0x48...0x4F: // DEC r
            let index = Int(opcode - 0x48) | (decodeREX & 0x01 != 0 ? 8 : 0)
            let result = incrementWithFlags(registerValue(index, size: operandSize), size: operandSize, decrement: true)
            setRegisterValue(index, size: operandSize, result)
        case 0x50...0x57: // PUSH r
            let index = Int(opcode - 0x50) | (decodeREX & 0x01 != 0 ? 8 : 0)
            let size = stackOperandSize(operandSize)
            try push(registerValue(index, size: size), size: size)
        case 0x58...0x5F: // POP r
            let index = Int(opcode - 0x58) | (decodeREX & 0x01 != 0 ? 8 : 0)
            let size = stackOperandSize(operandSize)
            setRegisterValue(index, size: size, try pop(size: size))
        case 0x63: // MOVSXD（IA-32e モード）/ ARPL（レガシー）
            if longModeActive {
                let modRM = try decodeModRM()
                let source = try readOperand(modRM, size: 4)
                setRegisterValue(modRM.reg, size: operandSize, UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(source & 0xFFFFFFFF)))))
            } else {
                let modRM = try decodeModRM()
                var destination = try readOperand(modRM, size: 2)
                let source = registerValue(modRM.reg, size: 2)
                if destination & 3 < source & 3 {
                    destination = (destination & ~3) | (source & 3)
                    try writeOperand(modRM, size: 2, destination)
                    setFlag(Self.flagZero, true)
                } else {
                    setFlag(Self.flagZero, false)
                }
            }
        case 0x60: // PUSHA / PUSHAD
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            if operandSize == 4 {
                let savedSP = registers[4]
                for index in [0, 1, 2, 3] { try push(registers[index], size: 4) }
                try push(savedSP, size: 4)
                for index in [5, 6, 7] { try push(registers[index], size: 4) }
            } else {
                let savedSP = register16(4)
                for index in [0, 1, 2, 3] { try push(UInt64(register16(index)), size: 2) }
                try push(UInt64(savedSP), size: 2)
                for index in [5, 6, 7] { try push(UInt64(register16(index)), size: 2) }
            }
        case 0x61: // POPA / POPAD
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            if operandSize == 4 {
                for index in [7, 6, 5] { registers[index] = try pop(size: 4) }
                _ = try pop(size: 4)
                for index in [3, 2, 1, 0] { registers[index] = try pop(size: 4) }
            } else {
                for index in [7, 6, 5] { setRegister16(index, UInt16(try pop(size: 2) & 0xFFFF)) }
                _ = try pop(size: 2)
                for index in [3, 2, 1, 0] { setRegister16(index, UInt16(try pop(size: 2) & 0xFFFF)) }
            }
        case 0x68: // PUSH imm（64 ビットモードでは imm32 を符号拡張）
            let raw = try fetchImmediate(operandSize == 8 ? 4 : operandSize)
            let value: UInt64 = operandSize == 2 ? (raw & 0xFFFF) : UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(raw & 0xFFFFFFFF))))
            try push(value, size: stackOperandSize(operandSize))
        case 0x6A: // PUSH imm8（符号拡張）
            let value = Int8(bitPattern: try fetch8())
            let size = stackOperandSize(operandSize)
            try push(UInt64(bitPattern: Int64(value)) & mask(forSize: size), size: size)
        case 0x69, 0x6B: // IMUL r, r/m, imm
            let modRM = try decodeModRM()
            let immediate = opcode == 0x69 ? try fetchSignExtendedImmediate(operandSize) : UInt64(bitPattern: Int64(Int8(bitPattern: try fetch8())))
            let source = try readOperand(modRM, size: operandSize)
            let result = multiplySigned(source, immediate, size: operandSize)
            setRegisterValue(modRM.reg, size: operandSize, UInt64(bitPattern: result))
        case 0x70...0x7F: // Jcc rel8
            let displacement = Int8(bitPattern: try fetch8())
            if condition(Int(opcode & 0x0F)) {
                instructionPointer = (instructionPointer &+ UInt64(bitPattern: Int64(displacement))) & ipMask
            }
        case 0x80, 0x81, 0x82, 0x83: // グループ1（ALU + 即値）
            let size = opcode == 0x80 || opcode == 0x82 ? 1 : operandSize
            let modRM = try decodeModRM()
            let immediate: UInt64
            if opcode == 0x83 {
                immediate = UInt64(bitPattern: Int64(Int8(bitPattern: try fetch8()))) & mask(forSize: size)
            } else {
                immediate = try fetchSignExtendedImmediate(size)
            }
            let operand = try readOperand(modRM, size: size)
            let result = alu(modRM.reg, operand, immediate, size: size)
            if modRM.reg != 7 { try writeOperand(modRM, size: size, result) }
        case 0x84, 0x85: // TEST
            let size = opcode == 0x84 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            _ = logicFlags(operand & registerValue(modRM.reg, size: size), size: size)
        case 0x86, 0x87: // XCHG
            let size = opcode == 0x86 ? 1 : operandSize
            let modRM = try decodeModRM()
            let operand = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, registerValue(modRM.reg, size: size))
            setRegisterValue(modRM.reg, size: size, operand)
        case 0x88, 0x89, 0x8A, 0x8B: // MOV
            let size = (opcode == 0x88 || opcode == 0x8A) ? 1 : operandSize
            let modRM = try decodeModRM()
            if opcode == 0x88 || opcode == 0x89 {
                try writeOperand(modRM, size: size, registerValue(modRM.reg, size: size))
            } else {
                let value = try readOperand(modRM, size: size)
                setRegisterValue(modRM.reg, size: size, value)
            }
        case 0x8C: // MOV セグメント → r/m
            let modRM = try decodeModRM()
            guard modRM.reg <= 5 else { throw CPUTrap.exception(vector: 6, errorCode: 0) }
            try writeOperand(modRM, size: 2, UInt64(segments[modRM.reg]))
        case 0x8D: // LEA
            let modRM = try decodeModRM()
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(opcode, address: address) }
            setRegisterValue(modRM.reg, size: operandSize, resolvedOffset(modRM))
        case 0x8E: // MOV r/m → セグメント
            let modRM = try decodeModRM()
            guard modRM.reg <= 5 else { throw CPUTrap.exception(vector: 6, errorCode: 0) }
            guard modRM.reg != 1 else { throw X86Fault.unimplementedOpcode(opcode, address: address) }
            let value = try readOperand(modRM, size: 2)
            try loadSegmentRegister(modRM.reg, UInt16(value & 0xFFFF))
            if modRM.reg == 2 { interruptInhibit = 2 } // MOV SS の割り込みシャドウ
        case 0x8F: // POP r/m
            let modRM = try decodeModRM()
            let size = stackOperandSize(operandSize)
            let value = try pop(size: size)
            try writeOperand(modRM, size: size, value)
        case 0x90...0x97: // NOP / XCHG AX, r
            let index = Int(opcode - 0x90) | (decodeREX & 0x01 != 0 ? 8 : 0)
            if opcode != 0x90 || index != 0 {
                let accumulator = registerValue(0, size: operandSize)
                let other = registerValue(index, size: operandSize)
                setRegisterValue(0, size: operandSize, other)
                setRegisterValue(index, size: operandSize, accumulator)
            }
        case 0x98: // CBW / CWDE / CDQE（半分の幅から符号拡張）
            let sourceSize = operandSize / 2
            setRegisterValue(0, size: operandSize, UInt64(bitPattern: signExtend(registerValue(0, size: sourceSize), size: sourceSize)))
        case 0x99: // CWD / CDQ / CQO
            setRegisterValue(2, size: operandSize, signExtend(registerValue(0, size: operandSize), size: operandSize) < 0 ? mask(forSize: operandSize) : 0)
        case 0x9A: // CALL far（64 ビットモードでは #UD）
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            let offset = try fetchImmediate(operandSize)
            let newSegment = try fetch16()
            if let tssSelector = try taskGateOrTSS(selector: newSegment) {
                try switchTask(toTSSSelector: tssSelector, kind: .nested, returnIP: instructionPointer)
                return
            }
            let size = stackOperandSize(operandSize)
            try push(UInt64(segments[1]), size: size)
            try push(instructionPointer, size: size)
            try loadCodeSegmentForTransfer(newSegment, isReturn: false)
            instructionPointer = offset & ipMask
        case 0x9C: // PUSHF
            let size = stackOperandSize(operandSize)
            try push(UInt64(flags), size: size)
        case 0x9D: // POPF（CPL > 0 では IOPL を、CPL > IOPL では IF を保持する）
            let size = stackOperandSize(operandSize)
            let value = try pop(size: size)
            flags = flagsAfterRestore(value, keepHighHalf: size == 2, cpl: currentPrivilegeLevel)
        case 0x9E: // SAHF
            flags = (flags & ~0xD5) | (UInt32(register8(4)) & 0xD5)
        case 0x9F: // LAHF
            setRegister8(4, UInt8((flags & 0xD5) | 0x02))
        case 0xA0, 0xA1, 0xA2, 0xA3: // MOV moffs
            let size = (opcode == 0xA0 || opcode == 0xA2) ? 1 : operandSize
            let offset = try fetchImmediate(decodeAddressSize)
            let segmentIndex = decodeSegmentOverride ?? 3
            if opcode == 0xA0 || opcode == 0xA1 {
                let value = try readGuest(segmentIndex: segmentIndex, offset: offset, size: size)
                setRegisterValue(0, size: size, value)
            } else {
                try writeGuest(segmentIndex: segmentIndex, offset: offset, size: size, registerValue(0, size: size))
            }
        case 0xA4...0xA7, 0xAA...0xAF, 0x6C...0x6F: // 文字列操作（INS / OUTS を含む）
            try executeStringOperation(opcode: opcode, operandSize: operandSize, repeatPrefix: repeatPrefix, startIP: startIP)
        case 0xA8, 0xA9: // TEST AL / eAX, imm（64 ビットモードでは imm32 符号拡張）
            let size = opcode == 0xA8 ? 1 : operandSize
            let immediate = try fetchSignExtendedImmediate(size)
            _ = logicFlags(registerValue(0, size: size) & immediate, size: size)
        case 0xB0...0xB7: // MOV r8, imm8
            setRegister8(Int(opcode - 0xB0) | (decodeREX & 0x01 != 0 ? 8 : 0), try fetch8())
        case 0xB8...0xBF: // MOV r, imm（REX.W では imm64 = MOVABS）
            let index = Int(opcode - 0xB8) | (decodeREX & 0x01 != 0 ? 8 : 0)
            let value = try fetchImmediate(operandSize)
            setRegisterValue(index, size: operandSize, value)
        case 0xC0, 0xC1: // シフト（imm8）
            let size = opcode == 0xC0 ? 1 : operandSize
            let modRM = try decodeModRM()
            let count = Int(try fetch8())
            let value = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, shift(modRM.reg, value, count, size: size))
        case 0xC2: // RET imm16
            let extra = try fetch16()
            instructionPointer = try pop(size: stackOperandSize(operandSize)) & ipMask
            setStackPointer(stackPointer &+ UInt64(extra))
        case 0xC3: // RET
            instructionPointer = try pop(size: stackOperandSize(operandSize)) & ipMask
        case 0xC6, 0xC7: // MOV r/m, imm
            let size = opcode == 0xC6 ? 1 : operandSize
            let modRM = try decodeModRM()
            let value = try fetchSignExtendedImmediate(size)
            try writeOperand(modRM, size: size, value)
        case 0xC8: // ENTER（64 ビットモードでは #UD）
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            let allocation = try fetch16()
            let level = Int(try fetch8() & 31)
            let size = stackOperandSize(operandSize)
            let baseValue = registerValue(5, size: size)
            try push(baseValue, size: size)
            let framePointer = stackPointer
            if level > 0 {
                var pointer = baseValue
                for _ in 1..<level {
                    pointer = pointer &- UInt64(size)
                    try push(try readGuest(segmentIndex: 2, offset: pointer, size: size), size: size)
                }
                try push(framePointer, size: size)
            }
            setRegisterValue(5, size: size, framePointer)
            setStackPointer(framePointer &- UInt64(allocation))
        case 0xC9: // LEAVE
            let size = stackOperandSize(operandSize)
            setStackPointer(registerValue(5, size: size))
            let value = try pop(size: size)
            setRegisterValue(5, size: size, value)
        case 0xCA: // RETF imm16
            let extra = try fetch16()
            let size = stackOperandSize(operandSize)
            let returnIP = try pop(size: size)
            let newSegment = UInt16(try pop(size: size) & 0xFFFF)
            var returnStack: UInt64?
            var returnSS: UInt16 = 0
            if let target = try? descriptorCache(selector: newSegment),
               !target.conforming, target.dpl > currentPrivilegeLevel {
                returnStack = try pop(size: size)
                returnSS = UInt16(try pop(size: size) & 0xFFFF)
            }
            try loadCodeSegmentForTransfer(newSegment, isReturn: true)
            instructionPointer = returnIP & ipMask
            if let returnStack {
                registers[4] = size == 2 ? (registers[4] & ~0xFFFF) | (returnStack & 0xFFFF) : returnStack & 0xFFFFFFFF
                segments[2] = returnSS
                if returnSS & 0xFFF8 != 0, let ssCache = try? descriptorCache(selector: returnSS) {
                    segmentCaches[2] = ssCache
                }
            }
            setStackPointer(stackPointer &+ UInt64(extra))
        case 0xCB: // RETF
            let size = stackOperandSize(operandSize)
            let returnIP = try pop(size: size)
            let newSegment = UInt16(try pop(size: size) & 0xFFFF)
            var returnStack: UInt64?
            var returnSS: UInt16 = 0
            if let target = try? descriptorCache(selector: newSegment),
               !target.conforming, target.dpl > currentPrivilegeLevel {
                returnStack = try pop(size: size)
                returnSS = UInt16(try pop(size: size) & 0xFFFF)
            }
            try loadCodeSegmentForTransfer(newSegment, isReturn: true)
            instructionPointer = returnIP & ipMask
            if let returnStack {
                registers[4] = size == 2 ? (registers[4] & ~0xFFFF) | (returnStack & 0xFFFF) : returnStack & 0xFFFFFFFF
                segments[2] = returnSS
                if returnSS & 0xFFF8 != 0, let ssCache = try? descriptorCache(selector: returnSS) {
                    segmentCaches[2] = ssCache
                }
            }
        case 0xCC: // INT 3
            try executeInterrupt(vector: 3, startIP: startIP)
        case 0xCD: // INT imm8
            let vector = try fetch8()
            try executeInterrupt(vector: vector, startIP: startIP)
        case 0xCE: // INTO
            if flag(Self.flagOverflow) { try executeInterrupt(vector: 4, startIP: startIP) }
        case 0xCF: // IRET / IRETQ
            if longModeActive {
                let cplBeforeReturn = currentPrivilegeLevel
                let returnIP = try pop(size: 8)
                let newSegment = UInt16(try pop(size: 8) & 0xFFFF)
                let newFlags = try pop(size: 8)
                let newStack = try pop(size: 8)
                let newSS = UInt16(try pop(size: 8) & 0xFFFF)
                try loadCodeSegmentForTransfer(newSegment, isReturn: true)
                if newSS & 0xFFF8 != 0 {
                    segmentCaches[2] = try descriptorCache(selector: newSS)
                }
                segments[2] = newSS
                registers[4] = newStack
                flags = flagsAfterRestore(newFlags, keepHighHalf: false, cpl: cplBeforeReturn)
                instructionPointer = returnIP
            } else {
                if flags & 0x4000 != 0 && tssPresent {
                    // NT セット時の IRET はバックリンク先のタスクへ戻る
                    let backLink = UInt16(try readMemoryValue(at: Int(tssBase), size: 2) & 0xFFFF)
                    try switchTask(toTSSSelector: backLink, kind: .iretReturn, returnIP: instructionPointer)
                    return
                }
                let size = stackOperandSize(operandSize)
                let cplBeforeReturn = currentPrivilegeLevel
                let returnIP = try pop(size: size)
                let newSegment = UInt16(try pop(size: size) & 0xFFFF)
                let value = try pop(size: size)
                // 外側の特権レベルへ戻る場合は ESP / SS もポップして切り替える
                var returnStack: UInt64?
                var returnSS: UInt16 = 0
                if let target = try? descriptorCache(selector: newSegment),
                   !target.conforming, target.dpl > currentPrivilegeLevel {
                    returnStack = try pop(size: size)
                    returnSS = UInt16(try pop(size: size) & 0xFFFF)
                }
                try loadCodeSegmentForTransfer(newSegment, isReturn: true)
                instructionPointer = returnIP & ipMask
                flags = flagsAfterRestore(value, keepHighHalf: size == 2, cpl: cplBeforeReturn)
                if let returnStack {
                    registers[4] = size == 2 ? (registers[4] & ~0xFFFF) | (returnStack & 0xFFFF) : returnStack & 0xFFFFFFFF
                    segments[2] = returnSS
                    if returnSS & 0xFFF8 != 0, let ssCache = try? descriptorCache(selector: returnSS) {
                        segmentCaches[2] = ssCache
                    }
                }
            }
        case 0xD0, 0xD1, 0xD2, 0xD3: // シフト（1 / CL）
            let size = (opcode == 0xD0 || opcode == 0xD2) ? 1 : operandSize
            let modRM = try decodeModRM()
            let count = (opcode == 0xD0 || opcode == 0xD1) ? 1 : Int(register8(1))
            let value = try readOperand(modRM, size: size)
            try writeOperand(modRM, size: size, shift(modRM.reg, value, count, size: size))
        case 0xD8...0xDF: // FPU エスケープ（最小限のスタブ: FNSTCW / FNSTSW のみ実データ）
            let modRM = try decodeModRM()
            if !modRM.isRegister {
                if opcode == 0xD9 && modRM.reg == 7 { // FNSTCW
                    try writeOperand(modRM, size: 2, 0x037F)
                } else if opcode == 0xDD && modRM.reg == 7 { // FNSTSW
                    try writeOperand(modRM, size: 2, 0)
                }
            }
        case 0xD4: // AAM（64 ビットモードでは #UD）
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            let base = UInt64(try fetch8())
            guard base != 0 else { throw divideFault(address: address) }
            let al = UInt64(register8(0))
            setRegister8(4, UInt8(al / base))
            setRegister8(0, UInt8(al % base))
            setSignZeroParity(UInt64(register8(0)), size: 1)
        case 0xD5: // AAD（64 ビットモードでは #UD）
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            let base = UInt64(try fetch8())
            let result = (UInt64(register8(4)) * base + UInt64(register8(0))) & 0xFF
            setRegister8(0, UInt8(result))
            setRegister8(4, 0)
            setSignZeroParity(result, size: 1)
        case 0xD7: // XLAT
            let base = registerValue(3, size: decodeAddressSize)
            let value = try readGuest(segmentIndex: decodeSegmentOverride ?? 3, offset: (base &+ UInt64(register8(0))) & decodeAddressMask, size: 1)
            setRegister8(0, UInt8(value & 0xFF))
        case 0xE0, 0xE1, 0xE2, 0xE3: // LOOP 系
            let displacement = Int8(bitPattern: try fetch8())
            let countMask: UInt64 = decodeAddressSize == 2 ? 0xFFFF : (decodeAddressSize == 4 ? 0xFFFFFFFF : UInt64.max)
            var take = false
            if opcode == 0xE3 {
                take = (registers[1] & countMask) == 0
            } else {
                let decremented = (registers[1] &- 1) & countMask
                registers[1] = (registers[1] & ~countMask) | decremented
                switch opcode {
                case 0xE0: take = decremented != 0 && !flag(Self.flagZero)
                case 0xE1: take = decremented != 0 && flag(Self.flagZero)
                default: take = decremented != 0
                }
            }
            if take { instructionPointer = (instructionPointer &+ UInt64(bitPattern: Int64(displacement))) & ipMask }
        case 0xE4, 0xE5: // IN AL / eAX, imm8（IOPL 検査）
            try requireIOPL()
            let port = UInt16(try fetch8())
            let size = opcode == 0xE4 ? 1 : operandSize
            setRegisterValue(0, size: size, UInt64(portIn(port, size: size)))
        case 0xE6, 0xE7: // OUT imm8, AL / eAX（IOPL 検査）
            try requireIOPL()
            let port = UInt16(try fetch8())
            let size = opcode == 0xE6 ? 1 : operandSize
            portOut(port, value: UInt32(registerValue(0, size: size) & 0xFFFFFFFF), size: size)
        case 0xE8: // CALL rel
            let displacement = operandSize == 2 ? Int64(Int16(bitPattern: try fetch16())) : Int64(Int32(bitPattern: try fetch32()))
            try push(instructionPointer, size: stackOperandSize(operandSize))
            instructionPointer = (instructionPointer &+ UInt64(bitPattern: displacement)) & ipMask
        case 0xE9: // JMP rel
            let displacement = operandSize == 2 ? Int64(Int16(bitPattern: try fetch16())) : Int64(Int32(bitPattern: try fetch32()))
            instructionPointer = (instructionPointer &+ UInt64(bitPattern: displacement)) & ipMask
        case 0xEA: // JMP far（64 ビットモードでは #UD）
            guard !inLongMode else { throw opcodeFault(opcode, address: address) }
            let offset = try fetchImmediate(operandSize)
            let newSegment = try fetch16()
            if let tssSelector = try taskGateOrTSS(selector: newSegment) {
                try switchTask(toTSSSelector: tssSelector, kind: .jump, returnIP: instructionPointer)
                return
            }
            try loadCodeSegmentForTransfer(newSegment, isReturn: false)
            instructionPointer = offset & ipMask
        case 0xEB: // JMP rel8
            let displacement = Int8(bitPattern: try fetch8())
            instructionPointer = (instructionPointer &+ UInt64(bitPattern: Int64(displacement))) & ipMask
        case 0xEC, 0xED: // IN AL / eAX, DX（IOPL 検査）
            try requireIOPL()
            let size = opcode == 0xEC ? 1 : operandSize
            setRegisterValue(0, size: size, UInt64(portIn(register16(2), size: size)))
        case 0xEE, 0xEF: // OUT DX, AL / eAX（IOPL 検査）
            try requireIOPL()
            let size = opcode == 0xEE ? 1 : operandSize
            portOut(register16(2), value: UInt32(registerValue(0, size: size) & 0xFFFFFFFF), size: size)
        case 0xF4: // HLT（特権命令。割り込み可能なら OS のアイドルとして待機する）
            try requireCPL0()
            if flag(Self.flagInterrupt) {
                waitingForInterrupt = true
            } else {
                halted = true
                exitCode = 0
            }
        case 0xF5: // CMC
            setFlag(Self.flagCarry, !flag(Self.flagCarry))
        case 0xF6, 0xF7: // グループ3
            try executeGroup3(opcode: opcode, operandSize: operandSize, address: address)
        case 0xF8: setFlag(Self.flagCarry, false)
        case 0xF9: setFlag(Self.flagCarry, true)
        case 0xFA: // CLI（IOPL 検査）
            try requireIOPL()
            setFlag(Self.flagInterrupt, false)
        case 0xFB: // STI（IOPL 検査。次の命令までは割り込みを受け付けない）
            try requireIOPL()
            setFlag(Self.flagInterrupt, true)
            interruptInhibit = 2
        case 0xFC: setFlag(Self.flagDirection, false)
        case 0xFD: setFlag(Self.flagDirection, true)
        case 0xFE: // グループ4（INC / DEC byte。それ以外は #UD）
            let modRM = try decodeModRM()
            guard modRM.reg <= 1 else { throw opcodeFault(opcode, address: address) }
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

    private func registerValue(_ index: Int, size: Int) -> UInt64 {
        switch size {
        case 1: return UInt64(register8(index))
        case 2: return UInt64(register16(index))
        case 4: return UInt64(register32(index))
        default: return registers[index]
        }
    }

    private func setRegisterValue(_ index: Int, size: Int, _ value: UInt64) {
        if size == 1 { setRegister8(index, UInt8(value & 0xFF)) }
        else if size == 2 { setRegister16(index, UInt16(value & 0xFFFF)) }
        else if size == 4 { setRegister32(index, UInt32(value & 0xFFFFFFFF)) }
        else { registers[index] = value }
    }

    private func signExtend(_ value: UInt64, size: Int) -> Int64 {
        switch size {
        case 1: return Int64(Int8(bitPattern: UInt8(value & 0xFF)))
        case 2: return Int64(Int16(bitPattern: UInt16(value & 0xFFFF)))
        case 4: return Int64(Int32(bitPattern: UInt32(value & 0xFFFFFFFF)))
        default: return Int64(bitPattern: value)
        }
    }

    /// 符号付き乗算。結果が size に収まらなければ CF / OF を立てる。
    /// 戻り値は積の下位 64 ビット。
    private func multiplySigned(_ a: UInt64, _ b: UInt64, size: Int) -> Int64 {
        if size == 8 {
            let x = Int64(bitPattern: a)
            let y = Int64(bitPattern: b)
            let full = x.multipliedFullWidth(by: y)
            let signExtension: Int64 = full.low >> 63 == 1 ? -1 : 0
            let overflow = full.high != signExtension
            setFlag(Self.flagCarry, overflow)
            setFlag(Self.flagOverflow, overflow)
            return Int64(bitPattern: full.low)
        }
        let full = signExtend(a, size: size) * signExtend(b, size: size)
        let truncated = signExtend(UInt64(bitPattern: full) & mask(forSize: size), size: size)
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
            let immediate = UInt64(try fetch8())
            let result = alu(operation, UInt64(register8(0)), immediate, size: 1)
            if operation != 7 { setRegister8(0, UInt8(result & 0xFF)) }
        default: // eAX, imm（64 ビットモードでも imm32 符号拡張。imm64 は MOVABS のみ）
            let immediate = try fetchSignExtendedImmediate(operandSize)
            let result = alu(operation, registerValue(0, size: operandSize), immediate, size: operandSize)
            if operation != 7 { setRegisterValue(0, size: operandSize, result) }
        }
    }

    /// 未実装命令に対するエラー（プロテクトモードでは #UD 例外にする）。
    private func opcodeFault(_ opcode: UInt8, address: UInt64) -> Error {
        if protectedMode {
            return CPUTrap.exception(vector: 6, errorCode: nil)
        }
        return X86Fault.unimplementedOpcode(opcode, address: address)
    }

    private func executeTwoByte(operandSize: Int, address: UInt64) throws {
        let opcode = try fetch8()
        switch opcode {
        case 0x00: // グループ6（SLDT / STR / LLDT / LTR）
            let modRM = try decodeModRM()
            switch modRM.reg {
            case 0: try writeOperand(modRM, size: 2, UInt64(ldtrSelector))
            case 1: try writeOperand(modRM, size: 2, UInt64(taskRegister))
            case 2:
                try requireCPL0()
                let selector = UInt16(try readOperand(modRM, size: 2) & 0xFFFF)
                ldtrSelector = selector
                if selector & 0xFFF8 != 0 {
                    ldtrCache = try descriptorCache(selector: selector)
                } else {
                    ldtrCache = SegmentCache()
                }
            case 3: // LTR（TSS キャッシュも読み込む）
                try requireCPL0()
                let selector = UInt16(try readOperand(modRM, size: 2) & 0xFFFF)
                taskRegister = selector
                if selector & 0xFFF8 != 0 {
                    // ディスクリプタ種別が TSS であることを検証し、ビジーを立てる
                    let ltrTableBase = selector & 0x0004 != 0 ? ldtrCache.base : gdtrBase
                    let ltrDescriptorAddress = Int(ltrTableBase + UInt64(selector & 0xFFF8))
                    let access = try readMemoryValue(at: ltrDescriptorAddress + 5, size: 1)
                    let descriptorType = access & 0xF
                    let validTypes: [UInt64] = longModeActive ? [0x9, 0xB] : [0x1, 0x3, 0x9, 0xB]
                    guard access & 0x10 == 0, validTypes.contains(descriptorType) else {
                        throw CPUTrap.exception(vector: 13, errorCode: UInt32(selector & 0xFFFC))
                    }
                    if descriptorType == 0x9 || descriptorType == 0x1 {
                        try writeMemoryValue(at: ltrDescriptorAddress + 5, size: 1, access | 0x2)
                    }
                    var cache = try descriptorCache(selector: selector)
                    if longModeActive {
                        // 64 ビット TSS は 16 バイトディスクリプタ（上位ベース）
                        let tableBase = selector & 0x0004 != 0 ? ldtrCache.base : gdtrBase
                        let descriptorAddress = Int(tableBase + UInt64(selector & 0xFFF8))
                        let baseHigh = try readMemoryValue(at: descriptorAddress + 8, size: 4)
                        cache.base |= baseHigh << 32
                    }
                    tssBase = cache.base
                    tssPresent = cache.present
                } else {
                    tssPresent = false
                }
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
                let offset = resolvedOffset(modRM)
                try writeGuest(segmentIndex: modRM.segmentIndex, offset: offset, size: 2, UInt64(limit))
                try writeGuest(segmentIndex: modRM.segmentIndex, offset: offset &+ 2, size: inLongMode ? 8 : 4, base)
            case 2, 3: // LGDT / LIDT
                try requireCPL0()
                guard !modRM.isRegister else { throw opcodeFault(opcode, address: address) }
                let offset = resolvedOffset(modRM)
                let limit = try readGuest(segmentIndex: modRM.segmentIndex, offset: offset, size: 2)
                let base = try readGuest(segmentIndex: modRM.segmentIndex, offset: offset &+ 2, size: (longModeActive || operandSize == 8) ? 8 : 4)
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
                try requireCPL0()
                let value = try readOperand(modRM, size: 2) & 0xF // LMSW が書けるのは下位 4 ビットのみ
                var newValue = (controlRegisters[0] & ~0xF) | value
                if controlRegisters[0] & 1 != 0 { newValue |= 1 } // PE は落とせない
                controlRegisters[0] = newValue
            case 7: // INVLPG（TLB は持たないため何もしない）/ SWAPGS（0F 01 F8）
                if modRM.isRegister {
                    guard modRM.registerIndex == 0 else { throw opcodeFault(opcode, address: address) }
                    try requireCPL0()
                    let currentGSBase = segmentCaches[5].base
                    segmentCaches[5].base = kernelGSBase
                    kernelGSBase = currentGSBase
                    break
                }
                try requireCPL0()
                break
            default:
                throw opcodeFault(opcode, address: address)
            }
        case 0x05: // SYSCALL
            guard longModeActive, efer & 0x1 != 0 else { throw opcodeFault(opcode, address: address) }
            registers[1] = instructionPointer // RCX = 復帰アドレス
            registers[11] = UInt64(flags) // R11 = RFLAGS
            flags = (flags & ~UInt32(sfmaskMSR & 0xFFFFFFFF)) | 0x0002
            let kernelSelector = UInt16((starMSR >> 32) & 0xFFFF) & 0xFFFC
            segments[1] = kernelSelector
            segmentCaches[1] = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: false, longMode: true, present: true, isCode: true, isExpandDown: false, permitsRead: true, permitsWrite: false, dpl: 0)
            segments[2] = (kernelSelector &+ 8) & 0xFFFC
            segmentCaches[2] = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: true, present: true, isCode: false, isExpandDown: false, permitsRead: true, permitsWrite: true, dpl: 0)
            instructionPointer = lstarMSR
        case 0x07: // SYSRET
            guard longModeActive, efer & 0x1 != 0 else { throw opcodeFault(opcode, address: address) }
            try requireCPL0()
            let userBase = UInt16((starMSR >> 48) & 0xFFFF)
            segments[2] = (userBase &+ 8) | 3
            segmentCaches[2] = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: true, present: true, isCode: false, isExpandDown: false, permitsRead: true, permitsWrite: true, dpl: 3)
            segments[1] = (userBase &+ 16) | 3
            segmentCaches[1] = SegmentCache(base: 0, limit: 0xFFFFFFFF, defaultSize32: operandSize != 8, longMode: operandSize == 8, present: true, isCode: true, isExpandDown: false, permitsRead: true, permitsWrite: false, dpl: 3)
            flags = (UInt32(registers[11] & 0xFFFFFFFF) & 0x3FD5) | 0x0002
            instructionPointer = operandSize == 8 ? registers[1] : (registers[1] & 0xFFFFFFFF)
        case 0x06: // CLTS
            try requireCPL0()
            break
        case 0x08, 0x09: // INVD / WBINVD（キャッシュを持たないため何もしない）
            break
        case 0x0B: // UD2
            throw opcodeFault(opcode, address: address)
        case 0x1F: // マルチバイト NOP
            _ = try decodeModRM()
        case 0x20, 0x21, 0x22, 0x23: // MOV CRn / DRn
            try requireCPL0()
            let modRM = try decodeModRM()
            let controlIndex = modRM.reg
            let size = inLongMode ? 8 : 4
            if opcode == 0x20 {
                let value = controlIndex == 8 ? UInt64(devices.lapic.tpr) : controlRegisters[controlIndex]
                try writeOperand(modRM, size: size, value)
            } else if opcode == 0x22 {
                let value = try readOperand(modRM, size: size)
                if controlIndex == 8 {
                    devices.lapic.tpr = UInt32(value & 0xFF)
                } else {
                    controlRegisters[controlIndex] = value
                }
            } else if opcode == 0x21 {
                try writeOperand(modRM, size: size, 0) // DR は未実装（読み出しは 0）
            }
            // 0x23: DR への書き込みは無視
        case 0x30: // WRMSR
            try requireCPL0()
            let msr = register32(1)
            let value = (registers[2] << 32) | (registers[0] & 0xFFFFFFFF)
            switch msr {
            case 0xC0000080: // EFER（LMA は読み取り専用）
                efer = value & 0x901 // SCE / LME / NXE
            case 0xC0000100: segmentCaches[4].base = value // FS.base
            case 0xC0000101: segmentCaches[5].base = value // GS.base
            case 0xC0000102: kernelGSBase = value
            case 0xC0000081: starMSR = value
            case 0xC0000082: lstarMSR = value
            case 0xC0000083: cstarMSR = value
            case 0xC0000084: sfmaskMSR = value
            default: break // その他の MSR は無視
            }
        case 0x32: // RDMSR
            try requireCPL0()
            let msr = register32(1)
            var value: UInt64 = 0
            switch msr {
            case 0xC0000080: // EFER（LMA = LME かつページング有効）
                value = efer | (longModeActive ? 0x400 : 0)
            case 0xC0000100: value = segmentCaches[4].base
            case 0xC0000101: value = segmentCaches[5].base
            case 0xC0000102: value = kernelGSBase
            case 0xC0000081: value = starMSR
            case 0xC0000082: value = lstarMSR
            case 0xC0000083: value = cstarMSR
            case 0xC0000084: value = sfmaskMSR
            default: value = 0
            }
            registers[0] = value & 0xFFFFFFFF
            registers[2] = value >> 32
        case 0x40...0x4F: // CMOVcc
            let modRM = try decodeModRM()
            if condition(Int(opcode & 0x0F)) {
                let value = try readOperand(modRM, size: operandSize)
                setRegisterValue(modRM.reg, size: operandSize, value)
            }
        case 0x80...0x8F: // Jcc near
            let displacement = operandSize == 2 ? Int64(Int16(bitPattern: try fetch16())) : Int64(Int32(bitPattern: try fetch32()))
            if condition(Int(opcode & 0x0F)) {
                instructionPointer = (instructionPointer &+ UInt64(bitPattern: displacement)) & ipMask
            }
        case 0x90...0x9F: // SETcc
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 1, condition(Int(opcode & 0x0F)) ? 1 : 0)
        case 0xA0: try push(UInt64(segments[4]), size: stackOperandSize(operandSize)) // PUSH FS
        case 0xA1: try loadSegmentRegister(4, UInt16(try pop(size: stackOperandSize(operandSize)) & 0xFFFF)) // POP FS
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
                registers[1] = 0 // ECX: SSE3 等は未実装のため広告しない
                registers[2] = 0x00000179 // FPU / PSE / TSC / MSR / PAE / CX8 / APIC
            case 0x80000000:
                registers[0] = 0x80000008
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            case 0x80000001:
                registers[0] = 0
                registers[3] = 0
                registers[1] = 0x00000001 // ECX: LAHF / SAHF（64 ビット）
                registers[2] = 0x20100000 // EDX: NX / ロングモード
            case 0x80000008:
                registers[0] = 0x00003030 // 物理 / リニアとも 48 ビット
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            default:
                registers[0] = 0
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            }
        case 0xA8: try push(UInt64(segments[5]), size: stackOperandSize(operandSize)) // PUSH GS
        case 0xA9: try loadSegmentRegister(5, UInt16(try pop(size: stackOperandSize(operandSize)) & 0xFFFF)) // POP GS
        case 0xB6, 0xB7: // MOVZX
            let modRM = try decodeModRM()
            let value = try readOperand(modRM, size: opcode == 0xB6 ? 1 : 2)
            setRegisterValue(modRM.reg, size: operandSize, value)
        case 0xBE, 0xBF: // MOVSX
            let sourceSize = opcode == 0xBE ? 1 : 2
            let modRM = try decodeModRM()
            let raw = try readOperand(modRM, size: sourceSize)
            setRegisterValue(modRM.reg, size: operandSize, UInt64(bitPattern: signExtend(raw, size: sourceSize)))
        case 0xC8...0xCF: // BSWAP
            let index = Int(opcode - 0xC8) | (decodeREX & 0x01 != 0 ? 8 : 0)
            if operandSize == 8 {
                registers[index] = registers[index].byteSwapped
            } else {
                setRegister32(index, register32(index).byteSwapped)
            }
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
            setSignZeroParity(UInt64(al & 0xFF), size: 1)
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
            setSignZeroParity(UInt64(al & 0xFF), size: 1)
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

    /// アドレッシング幅のマスク（2 = 16 ビット、4 = 32 ビット、8 = 64 ビット）。
    private var decodeAddressMask: UInt64 {
        decodeAddressSize == 2 ? 0xFFFF : (decodeAddressSize == 4 ? 0xFFFFFFFF : UInt64.max)
    }

    /// REP 付き文字列命令は 1 回の step で最大 8192 反復まで実行し、
    /// 残りは命令先頭から再実行して継続する（割り込みを受け付けるため）。
    private func executeStringOperation(opcode: UInt8, operandSize: Int, repeatPrefix: UInt8, startIP: UInt64) throws {
        if opcode >= 0x6C && opcode <= 0x6F { try requireIOPL() } // INS / OUTS
        let size = opcode & 1 == 0 ? 1 : operandSize
        let isRepeated = repeatPrefix == 0xF3 || repeatPrefix == 0xF2
        var iterations = 0
        while true {
            if isRepeated {
                if (registers[1] & decodeAddressMask) == 0 { return }
                registers[1] = (registers[1] & ~decodeAddressMask) | ((registers[1] &- 1) & decodeAddressMask)
            }
            try singleStringStep(opcode: opcode, size: size)
            if !isRepeated { return }
            iterations += 1
            if iterations >= 8192 {
                instructionPointer = startIP // 割り込み配送のため再実行させる
                return
            }
            if opcode == 0xA6 || opcode == 0xA7 || opcode == 0xAE || opcode == 0xAF {
                if repeatPrefix == 0xF3 && !flag(Self.flagZero) { return }
                if repeatPrefix == 0xF2 && flag(Self.flagZero) { return }
            }
        }
    }

    private func singleStringStep(opcode: UInt8, size: Int) throws {
        let stepDelta = Int64(size) * (flag(Self.flagDirection) ? -1 : 1)
        func pointer(_ index: Int) -> UInt64 { registers[index] & decodeAddressMask }
        func advance(_ index: Int) {
            let moved = (pointer(index) &+ UInt64(bitPattern: stepDelta)) & decodeAddressMask
            registers[index] = (registers[index] & ~decodeAddressMask) | moved
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
        case 0x6C, 0x6D: // INS（ポート DX → ES:DI）
            let value = portIn(UInt16(registers[2] & 0xFFFF), size: size)
            try writeGuest(segmentIndex: 0, offset: destinationOffset, size: size, UInt64(value))
            advance(7)
        case 0x6E, 0x6F: // OUTS（DS:SI → ポート DX）
            let value = try readGuest(segmentIndex: sourceSegment, offset: sourceOffset, size: size)
            portOut(UInt16(registers[2] & 0xFFFF), value: UInt32(value & 0xFFFFFFFF), size: size)
            advance(6)
        default:
            break
        }
    }

    private func executeGroup3(opcode: UInt8, operandSize: Int, address: UInt64) throws {
        let size = opcode == 0xF6 ? 1 : operandSize
        let modRM = try decodeModRM()
        switch modRM.reg {
        case 0: // TEST imm（RIP 相対の基準を合わせるため即値を先に読む）
            let immediate = try fetchSignExtendedImmediate(size)
            let operand = try readOperand(modRM, size: size)
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
                let full = UInt64(register8(0)) * (operand & 0xFF)
                setRegister16(0, UInt16(full & 0xFFFF))
                let overflow = (full >> 8) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            case 2:
                let full = UInt64(register16(0)) * (operand & 0xFFFF)
                setRegister16(0, UInt16(full & 0xFFFF))
                setRegister16(2, UInt16((full >> 16) & 0xFFFF))
                let overflow = (full >> 16) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            case 4:
                let full = UInt64(register32(0)) * (operand & 0xFFFFFFFF)
                setRegister32(0, UInt32(full & 0xFFFFFFFF))
                setRegister32(2, UInt32(full >> 32))
                let overflow = (full >> 32) != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            default: // 8: RDX:RAX = RAX × r/m
                let full = registers[0].multipliedFullWidth(by: operand)
                registers[0] = full.low
                registers[2] = full.high
                let overflow = full.high != 0
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
            }
        case 5: // IMUL（1 オペランド）
            let operand = try readOperand(modRM, size: size)
            if size == 8 {
                let full = Int64(bitPattern: registers[0]).multipliedFullWidth(by: Int64(bitPattern: operand))
                registers[0] = full.low
                registers[2] = UInt64(bitPattern: full.high)
                let signExtended: Int64 = full.low >> 63 != 0 ? -1 : 0
                let overflow = full.high != signExtended
                setFlag(Self.flagCarry, overflow); setFlag(Self.flagOverflow, overflow)
                return
            }
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
                    let dividend = UInt64(register16(0))
                    let quotient = dividend / divisor
                    guard quotient <= 0xFF else { throw divideFault(address: address) }
                    setRegister8(0, UInt8(quotient))
                    setRegister8(4, UInt8(dividend % divisor))
                }
            case 2:
                let dividendBits = (UInt64(register16(2)) << 16) | UInt64(register16(0))
                if signed {
                    let dividend = Int32(bitPattern: UInt32(dividendBits & 0xFFFFFFFF))
                    let d = Int32(Int16(bitPattern: UInt16(divisor & 0xFFFF)))
                    let quotient = Int64(dividend) / Int64(d) // Int64 で計算し Int32.min / -1 のトラップを避ける
                    guard quotient >= -32768 && quotient <= 32767 else { throw divideFault(address: address) }
                    setRegister16(0, UInt16(bitPattern: Int16(quotient)))
                    setRegister16(2, UInt16(bitPattern: Int16(Int64(dividend) % Int64(d))))
                } else {
                    let quotient = dividendBits / divisor
                    guard quotient <= 0xFFFF else { throw divideFault(address: address) }
                    setRegister16(0, UInt16(quotient))
                    setRegister16(2, UInt16(dividendBits % divisor))
                }
            case 4:
                let dividendBits = (UInt64(register32(2)) << 32) | UInt64(register32(0))
                if signed {
                    let dividend = Int64(bitPattern: dividendBits)
                    let d = Int64(Int32(bitPattern: UInt32(divisor & 0xFFFFFFFF)))
                    guard !(dividend == Int64.min && d == -1) else { throw divideFault(address: address) }
                    let quotient = dividend / d
                    guard quotient >= Int64(Int32.min) && quotient <= Int64(Int32.max) else { throw divideFault(address: address) }
                    setRegister32(0, UInt32(bitPattern: Int32(quotient)))
                    setRegister32(2, UInt32(bitPattern: Int32(dividend % d)))
                } else {
                    let quotient = dividendBits / divisor
                    guard quotient <= 0xFFFFFFFF else { throw divideFault(address: address) }
                    setRegister32(0, UInt32(quotient))
                    setRegister32(2, UInt32(dividendBits % divisor))
                }
            default: // 8: RDX:RAX ÷ r/m → RAX（商）, RDX（剰余）
                let high = registers[2]
                let low = registers[0]
                if signed {
                    let negativeDividend = high >> 63 != 0
                    var magnitudeHigh = high
                    var magnitudeLow = low
                    if negativeDividend {
                        magnitudeLow = ~low &+ 1
                        magnitudeHigh = ~high &+ (low == 0 ? 1 : 0)
                    }
                    let divisorSigned = Int64(bitPattern: divisor)
                    let divisorMagnitude = divisorSigned.magnitude // Int64.min でもトラップしない
                    guard magnitudeHigh < divisorMagnitude else { throw divideFault(address: address) }
                    let result = divisorMagnitude.dividingFullWidth((high: magnitudeHigh, low: magnitudeLow))
                    let negativeQuotient = negativeDividend != (divisorSigned < 0)
                    if negativeQuotient {
                        guard result.quotient <= 0x8000000000000000 else { throw divideFault(address: address) }
                    } else {
                        guard result.quotient <= 0x7FFFFFFFFFFFFFFF else { throw divideFault(address: address) }
                    }
                    registers[0] = negativeQuotient ? (0 &- result.quotient) : result.quotient
                    registers[2] = negativeDividend ? (0 &- result.remainder) : result.remainder
                } else {
                    guard high < divisor else { throw divideFault(address: address) }
                    let result = divisor.dividingFullWidth((high: high, low: low))
                    registers[0] = result.quotient
                    registers[2] = result.remainder
                }
            }
        default:
            throw X86Fault.unimplementedOpcode(opcode, address: address)
        }
    }

    /// 除算エラー（プロテクトモードでは #DE 例外にする）。
    private func divideFault(address: UInt64) -> Error {
        if protectedMode {
            return CPUTrap.exception(vector: 0, errorCode: nil)
        }
        return X86Fault.divideError(address: address)
    }

    private func executeGroup5(operandSize: Int, address: UInt64) throws {
        let modRM = try decodeModRM()
        switch modRM.reg {
        case 0:
            let value = try readOperand(modRM, size: operandSize)
            try writeOperand(modRM, size: operandSize, incrementWithFlags(value, size: operandSize, decrement: false))
        case 1:
            let value = try readOperand(modRM, size: operandSize)
            try writeOperand(modRM, size: operandSize, incrementWithFlags(value, size: operandSize, decrement: true))
        case 2: // CALL near indirect
            let target = try readOperand(modRM, size: inLongMode ? 8 : operandSize)
            try push(instructionPointer, size: stackOperandSize(operandSize))
            instructionPointer = target & ipMask
        case 3: // CALL far indirect
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(0xFF, address: address) }
            let pointerSize = inLongMode ? 8 : operandSize
            let base = resolvedOffset(modRM)
            let offset = try readGuest(segmentIndex: modRM.segmentIndex, offset: base, size: pointerSize)
            let newSegment = try readGuest(segmentIndex: modRM.segmentIndex, offset: base &+ UInt64(pointerSize), size: 2)
            if let tssSelector = try taskGateOrTSS(selector: UInt16(newSegment & 0xFFFF)) {
                try switchTask(toTSSSelector: tssSelector, kind: .nested, returnIP: instructionPointer)
                return
            }
            let size = stackOperandSize(operandSize)
            try push(UInt64(segments[1]), size: size)
            try push(instructionPointer, size: size)
            try loadCodeSegmentForTransfer(UInt16(newSegment & 0xFFFF), isReturn: false)
            instructionPointer = offset & ipMask
        case 4: // JMP near indirect
            let target = try readOperand(modRM, size: inLongMode ? 8 : operandSize)
            instructionPointer = target & ipMask
        case 5: // JMP far indirect
            guard !modRM.isRegister else { throw X86Fault.unimplementedOpcode(0xFF, address: address) }
            let pointerSize = inLongMode ? 8 : operandSize
            let base = resolvedOffset(modRM)
            let offset = try readGuest(segmentIndex: modRM.segmentIndex, offset: base, size: pointerSize)
            let newSegment = try readGuest(segmentIndex: modRM.segmentIndex, offset: base &+ UInt64(pointerSize), size: 2)
            if let tssSelector = try taskGateOrTSS(selector: UInt16(newSegment & 0xFFFF)) {
                try switchTask(toTSSSelector: tssSelector, kind: .jump, returnIP: instructionPointer)
                return
            }
            try loadCodeSegmentForTransfer(UInt16(newSegment & 0xFFFF), isReturn: false)
            instructionPointer = offset & ipMask
        case 6: // PUSH r/m
            let size = stackOperandSize(operandSize)
            try push(try readOperand(modRM, size: size), size: size)
        default:
            throw X86Fault.unimplementedOpcode(0xFF, address: address)
        }
    }

    private func executeInterrupt(vector: UInt8, startIP: UInt64) throws {
        if protectedMode {
            // ソフトウェア割り込みはゲート DPL の検査を受ける
            // （アクセスバイトは 64 ビット / レガシー両ゲートとも +5 の位置）
            if currentPrivilegeLevel > 0 {
                let entrySize = longModeActive ? 16 : 8
                let address = Int(idtrBase + UInt64(vector) * UInt64(entrySize))
                if let access = try? readMemory8(at: address + 5) {
                    if currentPrivilegeLevel > Int((access >> 5) & 0x3) {
                        throw CPUTrap.exception(vector: 13, errorCode: UInt32(vector) * 8 + 2)
                    }
                }
            }
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

    // MARK: - ポート I/O（デバイスバスへ委譲）

    private func portIn(_ port: UInt16, size: Int) -> UInt32 {
        devices.readPort(port, size: size)
    }

    private func portOut(_ port: UInt16, value: UInt32, size: Int) {
        devices.writePort(port, value: value, size: size)
    }
}
