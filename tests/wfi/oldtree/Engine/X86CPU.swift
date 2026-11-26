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
        if !isWrite && !cache.permitsRead { throw CPUTrap.exception(vector: 13, errorCode: errorCode) }   // 実行専用コードセグメントからのデータ読みも #GP
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
    /// 現在デコード中の命令の REP プレフィクス（0 / 0xF2 / 0xF3）と
    /// 0x66 プレフィクスの有無。SSE のバリアント判定に使う。
    private(set) var decodeRepeatPrefix: UInt8 = 0
    private(set) var decodePrefix66 = false

    // MARK: - x87 FPU / SSE 状態

    /// x87 レジスタスタック（物理レジスタ列、fpuTop が ST(0)）。
    var fpuRegisters = [Double](repeating: 0, count: 8)
    var fpuValid = [Bool](repeating: false, count: 8)
    var fpuTop = 0
    var fpuControlWord: UInt16 = 0x037F
    var fpuConditionCodes: (c0: Bool, c1: Bool, c2: Bool, c3: Bool) = (false, false, false, false)
    /// XMM レジスタ（16 本 × 16 バイト）と MXCSR。
    var xmmRegisters = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 16)
    var mxcsr: UInt32 = 0x1F80
    var mmRegisters = [UInt64](repeating: 0, count: 8) // MMX レジスタ（x87 とは別保持のサブセット実装）
    var xcr0: UInt64 = 1 // XCR0（bit0 = x87 は常時有効）
    var tscAux: UInt32 = 0 // IA32_TSC_AUX（RDTSCP 用）
    var fpuLastInstructionPointer: UInt64 = 0 // FLDENV / FNSTENV / FNSAVE 用
    var fpuLastDataPointer: UInt64 = 0
    var fpuLastOpcode: UInt16 = 0

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
        var has66 = false
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
            case 0x66:
                operandSize = operandSize == defaultOperand ? (defaultOperand == 2 ? 4 : 2) : defaultOperand
                has66 = true
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
                decodeRepeatPrefix = repeatPrefix
                decodePrefix66 = has66
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
            guard !modRM.isRegister else { throw opcodeFault(opcode, address: address) }   // レジスタ形式は #UD
            setRegisterValue(modRM.reg, size: operandSize, resolvedOffset(modRM))
        case 0x8E: // MOV r/m → セグメント
            let modRM = try decodeModRM()
            guard modRM.reg <= 5 else { throw CPUTrap.exception(vector: 6, errorCode: 0) }
            guard modRM.reg != 1 else { throw opcodeFault(opcode, address: address) }   // CS への MOV は #UD
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
        case 0xD8...0xDF: // x87 FPU
            try executeX87(opcode: opcode, operandSize: operandSize, address: startIP)
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
            if modRM.isRegister, modRM.reg == 2, modRM.registerIndex == 0 { // XGETBV（0F 01 D0）
                guard register32(1) == 0 else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
                registers[0] = xcr0 & 0xFFFFFFFF
                registers[2] = xcr0 >> 32
                break
            }
            if modRM.isRegister, modRM.reg == 2, modRM.registerIndex == 1 { // XSETBV（0F 01 D1）
                try requireCPL0()
                guard register32(1) == 0 else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
                let value = (registers[2] << 32) | (registers[0] & 0xFFFFFFFF)
                guard value & 1 != 0, value & ~0x3 == 0 else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
                xcr0 = value
                break
            }
            if modRM.isRegister, modRM.reg == 7, modRM.registerIndex == 1 { // RDTSCP（0F 01 F9）
                if controlRegisters[4] & 0x4 != 0, currentPrivilegeLevel != 0 { throw CPUTrap.exception(vector: 13, errorCode: 0) }
                registers[0] = instructionsExecuted & 0xFFFFFFFF
                registers[2] = instructionsExecuted >> 32
                registers[1] = UInt64(tscAux)
                break
            }
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
            controlRegisters[0] &= ~0x8 // CR0.TS をクリア
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
            case 0xC0000103: tscAux = UInt32(value & 0xFFFFFFFF)
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
            case 0xC0000103: value = UInt64(tscAux)
            case 0xC0000081: value = starMSR
            case 0xC0000082: value = lstarMSR
            case 0xC0000083: value = cstarMSR
            case 0xC0000084: value = sfmaskMSR
            default: value = 0
            }
            registers[0] = value & 0xFFFFFFFF
            registers[2] = value >> 32
        case 0x31: // RDTSC
            if controlRegisters[4] & 0x4 != 0, currentPrivilegeLevel != 0 { throw CPUTrap.exception(vector: 13, errorCode: 0) } // CR4.TSD
            registers[0] = instructionsExecuted & 0xFFFFFFFF
            registers[2] = instructionsExecuted >> 32
        case 0x38: // 3 バイトマップ（SSSE3 / SSE4.1 / MOVBE）
            try executeSSE38(operandSize: operandSize, address: address)
        case 0x3A: // 3 バイトマップ（SSE4.1 即値形式）
            try executeSSE3A(operandSize: operandSize, address: address)
        case 0x77: // EMMS（x87 タグをすべて空にする）
            if controlRegisters[0] & 0x4 != 0 || controlRegisters[0] & 0x8 != 0 { throw CPUTrap.exception(vector: 7, errorCode: nil) }
            for i in 0..<8 { fpuValid[i] = false }
        case 0xB8: // POPCNT（F3 プリフィクス必須）
            guard decodeRepeatPrefix == 0xF3 else { throw opcodeFault(opcode, address: address) }
            let modRM = try decodeModRM()
            let value = try readOperand(modRM, size: operandSize)
            let result = UInt64(value.nonzeroBitCount)
            setRegisterValue(modRM.reg, size: operandSize, result)
            flags = (flags & ~0x8D5) | (result == 0 ? 0x40 : 0) // CF/OF/SF/PF/AF = 0、ZF のみ結果依存
        case 0xC7: // グループ9（CMPXCHG8B / CMPXCHG16B は /1）
            let modRM = try decodeModRM()
            guard modRM.reg == 1, !modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            if operandSize == 8 { // CMPXCHG16B
                let low = try readOperand(modRM, size: 8)
                let offset = resolvedOffset(modRM)
                let high = try readGuest(segmentIndex: modRM.segmentIndex, offset: offset &+ 8, size: 8)
                if registers[0] == low, registers[2] == high {
                    try writeOperand(modRM, size: 8, registers[3])
                    try writeGuest(segmentIndex: modRM.segmentIndex, offset: offset &+ 8, size: 8, registers[1])
                    setFlag(Self.flagZero, true)
                } else {
                    registers[0] = low
                    registers[2] = high
                    setFlag(Self.flagZero, false)
                }
            } else { // CMPXCHG8B
                let value = try readOperand(modRM, size: 8)
                let accumulator = (registers[2] << 32) | (registers[0] & 0xFFFFFFFF)
                if accumulator == value {
                    try writeOperand(modRM, size: 8, (registers[1] << 32) | (registers[3] & 0xFFFFFFFF))
                    setFlag(Self.flagZero, true)
                } else {
                    registers[0] = value & 0xFFFFFFFF
                    registers[2] = value >> 32
                    setFlag(Self.flagZero, false)
                }
            }
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
                registers[0] = 7
                registers[3] = 0x756E6547 // EBX: "Genu"
                registers[2] = 0x49656E69 // EDX: "ineI"
                registers[1] = 0x6C65746E // ECX: "ntel"
            case 1:
                registers[0] = 0x000806EA // family 6 / model 142 (Coffee Lake) / stepping 10
                registers[3] = 0
                registers[1] = 0x0CC82201 // ECX: SSE3 / SSSE3 / CMPXCHG16B / SSE4.1 / MOVBE / POPCNT / XSAVE / OSXSAVE
                registers[2] = 0x07000379 // FPU / PSE / TSC / MSR / PAE / CX8 / APIC / FXSR / SSE / SSE2
            case 7:
                registers[0] = 0 // サブリーフ 0: 申告する機能なし
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            case 0x80000000:
                registers[0] = 0x80000008
                registers[3] = 0
                registers[1] = 0
                registers[2] = 0
            case 0x80000001:
                registers[0] = 0
                registers[3] = 0
                registers[1] = 0x00000001 // ECX: LAHF / SAHF（64 ビット）
                registers[2] = 0x28100000 // EDX: NX / RDTSCP / ロングモード
            case 0x80000002, 0x80000003, 0x80000004:
                // ブランド文字列（48 バイト、NUL パディング）
                let brandBytes = [UInt8]("Intel(R) Core(TM) i5-8259U CPU @ 2.30GHz".utf8)
                let leafIndex = Int(registers[0] - 0x80000002) * 16
                func brandWord(_ offset: Int) -> UInt64 {
                    var value: UInt64 = 0
                    for i in 0..<4 {
                        let index = leafIndex + offset + i
                        if index < brandBytes.count {
                            value |= UInt64(brandBytes[index]) << (8 * i)
                        }
                    }
                    return value
                }
                registers[0] = brandWord(0)
                registers[3] = brandWord(4)
                registers[1] = brandWord(8)
                registers[2] = brandWord(12)
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
        case 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x28, 0x29, 0x2A, 0x2C, 0x2D, 0x2E, 0x2F, 0x50,
             0x51, 0x52, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5C, 0x5D, 0x5E, 0x5F,
             0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
             0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x7C, 0x7D, 0x7E, 0x7F, 0xAE, 0xC2, 0xC4, 0xC5, 0xC6, 0xD0, 0xD1, 0xD2, 0xD3,
             0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6,
             0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
             0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE: // SSE / SSE2
            try executeSSE(opcode: opcode, operandSize: operandSize, address: address)
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

    // MARK: - バイト列オペランド

    /// メモリオペランドをバイト列として読む（m80 / m128 / FXSAVE 用）。
    private func readOperandBytes(_ operand: ModRM, count: Int) throws -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        var done = 0
        while done < count {
            let remaining = count - done
            let chunk = remaining >= 8 ? 8 : (remaining >= 4 ? 4 : (remaining >= 2 ? 2 : 1))
            let value = try readGuest(segmentIndex: operand.segmentIndex, offset: resolvedOffset(operand) &+ UInt64(done), size: chunk)
            for i in 0..<chunk { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
            done += chunk
        }
        return bytes
    }

    private func writeOperandBytes(_ operand: ModRM, _ bytes: [UInt8]) throws {
        var done = 0
        while done < bytes.count {
            let remaining = bytes.count - done
            let chunk = remaining >= 8 ? 8 : (remaining >= 4 ? 4 : (remaining >= 2 ? 2 : 1))
            var value: UInt64 = 0
            for i in 0..<chunk { value |= UInt64(bytes[done + i]) << (8 * i) }
            try writeGuest(segmentIndex: operand.segmentIndex, offset: resolvedOffset(operand) &+ UInt64(done), size: chunk, value)
            done += chunk
        }
    }

    private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(le32(bytes, offset)) | UInt64(le32(bytes, offset + 4)) << 32
    }

    private func putLE32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private func putLE64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        putLE32(&bytes, offset, UInt32(value & 0xFFFFFFFF))
        putLE32(&bytes, offset + 4, UInt32(value >> 32))
    }

    // MARK: - x87 FPU

    private func fpuST(_ index: Int) -> Double { fpuRegisters[(fpuTop + index) & 7] }

    private func fpuSetST(_ index: Int, _ value: Double) {
        let physical = (fpuTop + index) & 7
        fpuRegisters[physical] = value
        fpuValid[physical] = true
    }

    private func fpuPush(_ value: Double) {
        fpuTop = (fpuTop - 1) & 7
        fpuRegisters[fpuTop] = value
        fpuValid[fpuTop] = true
    }

    private func fpuPop() {
        fpuValid[fpuTop] = false
        fpuTop = (fpuTop + 1) & 7
    }

    private var fpuStatusWord: UInt16 {
        var word = UInt16(fpuTop & 7) << 11
        if fpuConditionCodes.c0 { word |= 0x0100 }
        if fpuConditionCodes.c1 { word |= 0x0200 }
        if fpuConditionCodes.c2 { word |= 0x0400 }
        if fpuConditionCodes.c3 { word |= 0x4000 }
        return word
    }

    private func fpuCompare(_ a: Double, _ b: Double) {
        if a.isNaN || b.isNaN { fpuConditionCodes = (true, false, true, true) }
        else if a > b { fpuConditionCodes = (false, false, false, false) }
        else if a < b { fpuConditionCodes = (true, false, false, false) }
        else { fpuConditionCodes = (false, false, false, true) }
    }

    /// FUCOMI / FCOMI 用に EFLAGS（ZF / PF / CF）へ比較結果を反映する。
    private func fpuCompareFlags(_ a: Double, _ b: Double) {
        if a.isNaN || b.isNaN {
            setFlag(Self.flagZero, true); setFlag(Self.flagParity, true); setFlag(Self.flagCarry, true)
        } else if a > b {
            setFlag(Self.flagZero, false); setFlag(Self.flagParity, false); setFlag(Self.flagCarry, false)
        } else if a < b {
            setFlag(Self.flagZero, false); setFlag(Self.flagParity, false); setFlag(Self.flagCarry, true)
        } else {
            setFlag(Self.flagZero, true); setFlag(Self.flagParity, false); setFlag(Self.flagCarry, false)
        }
    }

    private func fpuRoundedInteger(_ value: Double) -> Double {
        if value.isNaN || value.isInfinite { return value }
        switch (fpuControlWord >> 10) & 3 {
        case 1: return value.rounded(.down)
        case 2: return value.rounded(.up)
        case 3: return value.rounded(.towardZero)
        default: return value.rounded(.toNearestOrEven)
        }
    }

    private func fpuStoreInt(_ operand: ModRM, size: Int, popAfter: Bool, truncate: Bool = false) throws {
        let rounded = truncate ? fpuST(0).rounded(.towardZero) : fpuRoundedInteger(fpuST(0))
        let value: UInt64
        // 対象サイズに収まらない場合は切り捨てず整数不定値を格納する
        let outOfRange = rounded.isNaN || rounded >= 9.223372036854776e18 || rounded < -9.223372036854776e18
            || (size == 2 && (rounded > 32767 || rounded < -32768))
            || (size == 4 && (rounded > 2147483647 || rounded < -2147483648))
        if outOfRange {
            value = size == 8 ? 0x8000000000000000 : (size == 4 ? 0x80000000 : 0x8000) // 整数不定値
        } else {
            value = UInt64(bitPattern: Int64(rounded)) & mask(forSize: size)
        }
        try writeOperand(operand, size: size, value)
        if popAfter { fpuPop() }
    }

    /// FPU 環境（FLDENV / FNSTENV 用）。32 ビット形式は 28 バイト、16 ビット形式は 14 バイト。
    private func fpuEnvironment(size32: Bool) -> [UInt8] {
        var tagWord: UInt16 = 0
        for i in 0..<8 {
            let tag: UInt16
            if !fpuValid[i] {
                tag = 3
            } else if fpuRegisters[i] == 0 {
                tag = 1
            } else if fpuRegisters[i].isNaN || fpuRegisters[i].isInfinite || (fpuRegisters[i].exponentBitPattern == 0 && fpuRegisters[i].significandBitPattern != 0) {
                tag = 2
            } else {
                tag = 0
            }
            tagWord |= tag << (2 * i)
        }
        var bytes = [UInt8](repeating: 0, count: size32 ? 28 : 14)
        func put16(_ offset: Int, _ value: UInt16) { bytes[offset] = UInt8(value & 0xFF); bytes[offset + 1] = UInt8(value >> 8) }
        func put32(_ offset: Int, _ value: UInt32) { for k in 0..<4 { bytes[offset + k] = UInt8((value >> (8 * k)) & 0xFF) } }
        put16(0, fpuControlWord)
        if size32 {
            put16(4, fpuStatusWord)
            put16(8, tagWord)
            put32(12, UInt32(fpuLastInstructionPointer & 0xFFFFFFFF))
            put16(18, fpuLastOpcode)
            put32(20, UInt32(fpuLastDataPointer & 0xFFFFFFFF))
        } else {
            put16(2, fpuStatusWord)
            put16(4, tagWord)
            put16(6, UInt16(fpuLastInstructionPointer & 0xFFFF))
            put16(10, UInt16(fpuLastDataPointer & 0xFFFF))
        }
        return bytes
    }

    private func fpuLoadEnvironment(_ operand: ModRM, size32: Bool) throws {
        let bytes = try readOperandBytes(operand, count: size32 ? 28 : 14)
        func get16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func get32(_ offset: Int) -> UInt32 { UInt32(le32(bytes, offset)) }
        fpuControlWord = get16(0)
        let status = get16(size32 ? 4 : 2)
        fpuTop = Int((status >> 11) & 7)
        fpuConditionCodes = (status & 0x0100 != 0, status & 0x0200 != 0, status & 0x0400 != 0, status & 0x4000 != 0)
        let tagWord = get16(size32 ? 8 : 4)
        for i in 0..<8 { fpuValid[i] = (tagWord >> (2 * i)) & 3 != 3 }
        if size32 {
            fpuLastInstructionPointer = UInt64(get32(12))
            fpuLastOpcode = get16(18)
            fpuLastDataPointer = UInt64(get32(20))
        } else {
            fpuLastInstructionPointer = UInt64(get16(6))
            fpuLastDataPointer = UInt64(get16(10))
        }
    }

    /// FNSAVE: 環境 + スタックイメージ（物理レジスタ順）を書き、FPU を初期化する。
    private func fpuSaveState(_ operand: ModRM, size32: Bool) throws {
        var bytes = fpuEnvironment(size32: size32)
        for i in 0..<8 { bytes += storeExtended(fpuRegisters[i]) }
        try writeOperandBytes(operand, bytes)
        fpuControlWord = 0x037F
        fpuTop = 0
        fpuConditionCodes = (false, false, false, false)
        for i in 0..<8 { fpuValid[i] = false }
    }

    /// FRSTOR: 環境 + スタックイメージを復元する。
    private func fpuRestoreState(_ operand: ModRM, size32: Bool) throws {
        let total = (size32 ? 28 : 14) + 80
        let bytes = try readOperandBytes(operand, count: total)
        let envCount = size32 ? 28 : 14
        try fpuLoadEnvironmentBytes(Array(bytes[0..<envCount]), size32: size32)
        for i in 0..<8 {
            fpuRegisters[i] = loadExtended(Array(bytes[(envCount + i * 10)..<(envCount + i * 10 + 10)]))
        }
    }

    private func fpuLoadEnvironmentBytes(_ bytes: [UInt8], size32: Bool) throws {
        func get16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func get32(_ offset: Int) -> UInt32 { UInt32(le32(bytes, offset)) }
        fpuControlWord = get16(0)
        let status = get16(size32 ? 4 : 2)
        fpuTop = Int((status >> 11) & 7)
        fpuConditionCodes = (status & 0x0100 != 0, status & 0x0200 != 0, status & 0x0400 != 0, status & 0x4000 != 0)
        let tagWord = get16(size32 ? 8 : 4)
        for i in 0..<8 { fpuValid[i] = (tagWord >> (2 * i)) & 3 != 3 }
        if size32 {
            fpuLastInstructionPointer = UInt64(get32(12))
            fpuLastOpcode = get16(18)
            fpuLastDataPointer = UInt64(get32(20))
        } else {
            fpuLastInstructionPointer = UInt64(get16(6))
            fpuLastDataPointer = UInt64(get16(10))
        }
    }

    /// 二項演算（operation: 0 加算 / 1 乗算 / 2 比較 / 3 比較+ポップ /
    /// 4 減算 ST−v / 5 減算 v−ST / 6 除算 ST÷v / 7 除算 v÷ST）。
    private func fpuBinaryOp(_ operation: Int, operand value: Double) {
        switch operation {
        case 0: fpuSetST(0, fpuST(0) + value)
        case 1: fpuSetST(0, fpuST(0) * value)
        case 2: fpuCompare(fpuST(0), value)
        case 3: fpuCompare(fpuST(0), value); fpuPop()
        case 4: fpuSetST(0, fpuST(0) - value)
        case 5: fpuSetST(0, value - fpuST(0))
        case 6: fpuSetST(0, fpuST(0) / value)
        case 7: fpuSetST(0, value / fpuST(0))
        default: break
        }
    }

    /// DC 形式（ST(i) が宛先の逆向き形式）。
    private func fpuBinaryOpReversed(_ operation: Int, index: Int) {
        let st = fpuST(0), sti = fpuST(index)
        switch operation {
        case 0: fpuSetST(index, sti + st)
        case 1: fpuSetST(index, sti * st)
        case 2: fpuCompare(st, sti)
        case 3: fpuCompare(st, sti); fpuPop()
        case 4: fpuSetST(index, st - sti) // FSUBR ST(i), ST
        case 5: fpuSetST(index, sti - st) // FSUB ST(i), ST
        case 6: fpuSetST(index, st / sti) // FDIVR ST(i), ST
        case 7: fpuSetST(index, sti / st) // FDIV ST(i), ST
        default: break
        }
    }

    /// DE 形式（結果を ST(i) に入れてポップする形式）。
    private func fpuBinaryOpPop(_ operation: Int, index: Int) {
        let st = fpuST(0), sti = fpuST(index)
        switch operation {
        case 0: fpuSetST(index, sti + st)
        case 1: fpuSetST(index, sti * st)
        case 4: fpuSetST(index, st - sti) // FSUBRP
        case 5: fpuSetST(index, sti - st) // FSUBP
        case 6: fpuSetST(index, st / sti) // FDIVRP
        case 7: fpuSetST(index, sti / st) // FDIVP
        default: break
        }
        fpuPop()
    }

    /// 80 ビット拡張倍精度を Double へ変換する。
    private func loadExtended(_ bytes: [UInt8]) -> Double {
        let mantissa = le64(bytes, 0)
        // 指数部は 15 ビット: UInt8 のまま << 8 すると 0 になるため UInt16 で合成する
        let field = UInt16(bytes[8]) | UInt16(bytes[9] & 0x7F) << 8
        let exponentField = Int(field)
        let negative = bytes[9] & 0x80 != 0
        if exponentField == 0 { return negative ? -0.0 : 0.0 }
        if exponentField == 0x7FFF {
            return mantissa == 0x8000000000000000 ? (negative ? -.infinity : .infinity) : .nan
        }
        let significand = Double(mantissa) / 9223372036854775808.0 // 2^63
        return Double(sign: negative ? .minus : .plus, exponent: exponentField - 16383, significand: significand)
    }

    /// Double を 80 ビット拡張倍精度へ変換する（精度は Double の範囲）。
    private func storeExtended(_ value: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        if value.isNaN {
            putLE64(&bytes, 0, 0xC000000000000000)
            bytes[8] = 0xFF; bytes[9] = 0xFF
            return bytes
        }
        let negative = value.sign == .minus
        let magnitude = abs(value)
        if magnitude.isInfinite {
            putLE64(&bytes, 0, 0x8000000000000000)
            bytes[8] = 0xFF; bytes[9] = negative ? 0xFF : 0x7F
            return bytes
        }
        if magnitude == 0 { return bytes }
        let scaled = (magnitude.significand * 9223372036854775808.0).rounded()
        let mantissa = scaled >= 18446744073709551616.0 ? UInt64.max : UInt64(scaled)
        let exponentField = magnitude.exponent + 16383
        putLE64(&bytes, 0, mantissa)
        bytes[8] = UInt8(exponentField & 0xFF)
        bytes[9] = UInt8((exponentField >> 8) & 0x7F) | (negative ? 0x80 : 0)
        return bytes
    }

    private func executeX87(opcode: UInt8, operandSize: Int, address: UInt64) throws {
        if controlRegisters[0] & 0x4 != 0 { // CR0.EM → #NM
            throw CPUTrap.exception(vector: 7, errorCode: nil)
        }
        if controlRegisters[0] & 0x8 != 0 { // CR0.TS → #NM
            throw CPUTrap.exception(vector: 7, errorCode: nil)
        }
        let modRM = try decodeModRM()
        // 制御系以外の命令では FIP / FDP / FOP を更新する（FNSTENV / FNSAVE 用）
        let isControl = (opcode == 0xD9 && (modRM.reg == 4 || modRM.reg == 5 || modRM.reg == 6 || modRM.reg == 7))
            || (opcode == 0xDD && (modRM.reg == 4 || modRM.reg == 6 || modRM.reg == 7))
        if !isControl {
            fpuLastInstructionPointer = address
            fpuLastOpcode = (UInt16(opcode & 7) << 8) | (UInt16(modRM.reg & 7) << 3) | UInt16(modRM.registerIndex & 7)
            if !modRM.isRegister {
                fpuLastDataPointer = segmentCaches[modRM.segmentIndex].base &+ resolvedOffset(modRM)
            }
        }
        let reg = modRM.reg & 7
        let rm = modRM.registerIndex & 7
        if modRM.isRegister {
            try executeX87Register(opcode: opcode, reg: reg, rm: rm, address: address)
            return
        }
        switch opcode {
        case 0xD8:
            fpuBinaryOp(reg, operand: Double(Float(bitPattern: UInt32(try readOperand(modRM, size: 4)))))
        case 0xD9:
            switch reg {
            case 0: fpuPush(Double(Float(bitPattern: UInt32(try readOperand(modRM, size: 4)))))
            case 2: try writeOperand(modRM, size: 4, UInt64(Float(fpuST(0)).bitPattern))
            case 3: try writeOperand(modRM, size: 4, UInt64(Float(fpuST(0)).bitPattern)); fpuPop()
            case 4: try fpuLoadEnvironment(modRM, size32: operandSize != 2) // FLDENV
            case 5: fpuControlWord = UInt16(try readOperand(modRM, size: 2) & 0xFFFF) // FLDCW
            case 6: try writeOperandBytes(modRM, fpuEnvironment(size32: operandSize != 2)) // FNSTENV
            case 7: try writeOperand(modRM, size: 2, UInt64(fpuControlWord)) // FNSTCW
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDA:
            fpuBinaryOp(reg, operand: Double(Int32(bitPattern: UInt32(try readOperand(modRM, size: 4)))))
        case 0xDB:
            switch reg {
            case 0: fpuPush(Double(Int32(bitPattern: UInt32(try readOperand(modRM, size: 4)))))
            case 1: try fpuStoreInt(modRM, size: 4, popAfter: true, truncate: true) // FISTTP
            case 2: try fpuStoreInt(modRM, size: 4, popAfter: false)
            case 3: try fpuStoreInt(modRM, size: 4, popAfter: true)
            case 5: fpuPush(loadExtended(try readOperandBytes(modRM, count: 10)))
            case 7: try writeOperandBytes(modRM, storeExtended(fpuST(0))); fpuPop()
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDC:
            fpuBinaryOp(reg, operand: Double(bitPattern: try readOperand(modRM, size: 8)))
        case 0xDD:
            switch reg {
            case 0: fpuPush(Double(bitPattern: try readOperand(modRM, size: 8)))
            case 1: try fpuStoreInt(modRM, size: 8, popAfter: true, truncate: true) // FISTTP
            case 2: try writeOperand(modRM, size: 8, fpuST(0).bitPattern)
            case 3: try writeOperand(modRM, size: 8, fpuST(0).bitPattern); fpuPop()
            case 4: try fpuRestoreState(modRM, size32: operandSize != 2) // FRSTOR
            case 5: fpuCompare(fpuST(0), Double(bitPattern: try readOperand(modRM, size: 8))) // FUCOM m64
            case 6: try fpuSaveState(modRM, size32: operandSize != 2) // FNSAVE
            case 7: try writeOperand(modRM, size: 2, UInt64(fpuStatusWord)) // FNSTSW m16
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDE:
            fpuBinaryOp(reg, operand: Double(Int16(bitPattern: UInt16(try readOperand(modRM, size: 2)))))
        case 0xDF:
            switch reg {
            case 0: fpuPush(Double(Int16(bitPattern: UInt16(try readOperand(modRM, size: 2)))))
            case 1: try fpuStoreInt(modRM, size: 2, popAfter: true, truncate: true) // FISTTP
            case 2: try fpuStoreInt(modRM, size: 2, popAfter: false)
            case 3: try fpuStoreInt(modRM, size: 2, popAfter: true)
            case 5: fpuPush(Double(Int64(bitPattern: try readOperand(modRM, size: 8))))
            case 7: try fpuStoreInt(modRM, size: 8, popAfter: true)
            default: throw opcodeFault(opcode, address: address)
            }
        default: throw opcodeFault(opcode, address: address)
        }
    }

    private func executeX87Register(opcode: UInt8, reg: Int, rm: Int, address: UInt64) throws {
        switch opcode {
        case 0xD8: fpuBinaryOp(reg, operand: fpuST(rm))
        case 0xD9:
            switch reg {
            case 0: fpuPush(fpuST(rm)) // FLD ST(i)
            case 1: // FXCH ST(i)
                let a = fpuST(0), b = fpuST(rm)
                fpuSetST(0, b); fpuSetST(rm, a)
            case 2:
                guard rm == 0 else { throw opcodeFault(opcode, address: address) } // FNOP
            case 4:
                switch rm {
                case 0: fpuSetST(0, -fpuST(0)) // FCHS
                case 1: fpuSetST(0, abs(fpuST(0))) // FABS
                case 4: fpuCompare(fpuST(0), 0) // FTST
                case 5: // FXAM（大まかな分類のみ）
                    let value = fpuST(0)
                    if value.isNaN { fpuConditionCodes = (true, false, false, false) }
                    else if value.isInfinite { fpuConditionCodes = (true, true, false, false) }
                    else if value == 0 { fpuConditionCodes = (false, false, false, true) }
                    else { fpuConditionCodes = (false, true, false, false) }
                default: throw opcodeFault(opcode, address: address)
                }
            case 6:
                switch rm {
                case 1: fpuSetST(1, fpuST(1) * log2(fpuST(0))); fpuPop() // FYL2X
                case 2: fpuSetST(0, tan(fpuST(0))); fpuPush(1.0) // FPTAN
                case 3: fpuSetST(1, atan2(fpuST(1), fpuST(0))); fpuPop() // FPATAN
                case 4: // FXTRACT: ST(0) を指数に置き換え、仮数をプッシュ
                    let value = fpuST(0)
                    if value == 0 {
                        fpuSetST(0, 0); fpuPush(0)
                    } else {
                        let significand = value.significand * (value < 0 ? -1 : 1)
                        fpuSetST(0, Double(value.exponent))
                        fpuPush(significand)
                    }
                case 5: // FPREM1
                    let divisor = fpuST(1)
                    if divisor != 0 {
                        let quotient = (fpuST(0) / divisor).rounded(.toNearestOrEven)
                        fpuSetST(0, fpuST(0) - quotient * divisor)
                    }
                case 6: fpuTop = (fpuTop - 1) & 7 // FDECSTP
                case 7: fpuTop = (fpuTop + 1) & 7 // FINCSTP
                default: throw opcodeFault(opcode, address: address)
                }
            case 7:
                switch rm {
                case 0: // FPREM
                    let divisor = fpuST(1)
                    if divisor != 0 {
                        let quotient = (fpuST(0) / divisor).rounded(.towardZero)
                        fpuSetST(0, fpuST(0) - quotient * divisor)
                    }
                case 1: fpuSetST(1, fpuST(1) * log2(fpuST(0) + 1)); fpuPop() // FYL2XP1
                case 2: fpuSetST(0, sqrt(fpuST(0))) // FSQRT
                case 3: // FSINCOS
                    let value = fpuST(0)
                    fpuSetST(0, sin(value)); fpuPush(cos(value))
                case 4: fpuSetST(0, fpuRoundedInteger(fpuST(0))) // FRNDINT
                case 5: fpuSetST(0, fpuST(0) * pow(2.0, fpuST(1).rounded(.towardZero))) // FSCALE
                case 6: fpuSetST(0, sin(fpuST(0))) // FSIN
                case 7: fpuSetST(0, cos(fpuST(0))) // FCOS
                default: throw opcodeFault(opcode, address: address)
                }
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDA:
            switch reg {
            case 0: if flag(Self.flagCarry) { fpuSetST(0, fpuST(rm)) } // FCMOVB
            case 1: if flag(Self.flagZero) { fpuSetST(0, fpuST(rm)) } // FCMOVE
            case 2: if flag(Self.flagCarry) || flag(Self.flagZero) { fpuSetST(0, fpuST(rm)) } // FCMOVBE
            case 3: if flag(Self.flagParity) { fpuSetST(0, fpuST(rm)) } // FCMOVU
            case 5:
                guard rm == 1 else { throw opcodeFault(opcode, address: address) } // FUCOMPP
                fpuCompare(fpuST(0), fpuST(1)); fpuPop(); fpuPop()
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDB:
            switch reg {
            case 0: if !flag(Self.flagCarry) { fpuSetST(0, fpuST(rm)) } // FCMOVNB
            case 1: if !flag(Self.flagZero) { fpuSetST(0, fpuST(rm)) } // FCMOVNE
            case 2: if !flag(Self.flagCarry) && !flag(Self.flagZero) { fpuSetST(0, fpuST(rm)) } // FCMOVNBE
            case 3: if !flag(Self.flagParity) { fpuSetST(0, fpuST(rm)) } // FCMOVNU
            case 4:
                switch rm {
                case 2: fpuConditionCodes = (false, false, false, false) // FNCLEX
                case 3: // FNINIT
                    fpuTop = 0
                    fpuValid = [Bool](repeating: false, count: 8)
                    fpuControlWord = 0x037F
                    fpuConditionCodes = (false, false, false, false)
                default: break // FNENI / FNDISI / FNSETPM は NOP
                }
            case 5: fpuCompareFlags(fpuST(0), fpuST(rm)) // FUCOMI
            case 6: fpuCompareFlags(fpuST(0), fpuST(rm)) // FCOMI
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDC: fpuBinaryOpReversed(reg, index: rm)
        case 0xDD:
            switch reg {
            case 0: fpuValid[(fpuTop + rm) & 7] = false // FFREE
            case 2: fpuSetST(rm, fpuST(0)) // FST ST(i)
            case 3: fpuSetST(rm, fpuST(0)); fpuPop() // FSTP ST(i)
            case 4: fpuCompare(fpuST(0), fpuST(rm)) // FUCOM
            case 5: fpuCompare(fpuST(0), fpuST(rm)); fpuPop() // FUCOMP
            default: throw opcodeFault(opcode, address: address)
            }
        case 0xDE:
            if reg == 3 {
                guard rm == 1 else { throw opcodeFault(opcode, address: address) } // FCOMPP
                fpuCompare(fpuST(0), fpuST(1)); fpuPop(); fpuPop()
            } else if reg == 2 {
                throw opcodeFault(opcode, address: address)
            } else {
                fpuBinaryOpPop(reg, index: rm)
            }
        case 0xDF:
            switch reg {
            case 0: fpuValid[(fpuTop + rm) & 7] = false; fpuPop() // FFREEP
            case 4:
                guard rm == 0 else { throw opcodeFault(opcode, address: address) } // FNSTSW AX
                registers[0] = (registers[0] & ~0xFFFF) | UInt64(fpuStatusWord)
            case 5: fpuCompareFlags(fpuST(0), fpuST(rm)); fpuPop() // FUCOMIP
            case 6: fpuCompareFlags(fpuST(0), fpuST(rm)); fpuPop() // FCOMIP
            default: throw opcodeFault(opcode, address: address)
            }
        default: throw opcodeFault(opcode, address: address)
        }
    }

    // MARK: - SSE / SSE2

    private enum SSEVariant { case ps, pd, ss, sd }

    private var sseVariant: SSEVariant {
        if decodeRepeatPrefix == 0xF3 { return .ss }
        if decodeRepeatPrefix == 0xF2 { return .sd }
        return decodePrefix66 ? .pd : .ps
    }

    private func readXMMOperand(_ operand: ModRM) throws -> [UInt8] {
        if operand.isRegister { return xmmRegisters[operand.registerIndex & 15] }
        return try readOperandBytes(operand, count: 16)
    }

    private func writeXMMOperand(_ operand: ModRM, _ bytes: [UInt8]) throws {
        if operand.isRegister { xmmRegisters[operand.registerIndex & 15] = bytes }
        else { try writeOperandBytes(operand, bytes) }
    }

    private func executeSSE(opcode: UInt8, operandSize: Int, address: UInt64) throws {
        if controlRegisters[0] & 0x4 != 0 { throw CPUTrap.exception(vector: 7, errorCode: nil) } // CR0.EM → #NM
        if controlRegisters[0] & 0x8 != 0, opcode != 0xAE { throw CPUTrap.exception(vector: 7, errorCode: nil) } // CR0.TS → #NM
        if controlRegisters[4] & 0x200 == 0 { throw opcodeFault(opcode, address: address) } // CR4.OSFXSR なし → #UD
        let variant = sseVariant
        let p66 = decodePrefix66
        switch opcode {
        case 0xAE:
            try executeSSEGroupAE(address: address)
        case 0x71, 0x72, 0x73: // シフト（即値）
            let modRM = try decodeModRM()
            guard modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            let count = Int(try fetch8())
            if p66 {
                let index = modRM.registerIndex & 15
                xmmRegisters[index] = sseShiftImmediate(opcode: opcode, subOperation: modRM.reg & 7, bytes: xmmRegisters[index], count: count)
            } else { // MMX 形式
                let index = modRM.registerIndex & 7
                mmRegisters[index] = try mmxShiftImmediate(opcode: opcode, subOperation: modRM.reg & 7, value: mmRegisters[index], count: count, address: address)
            }
        case 0xC2: // CMPPS / CMPPD / CMPSS / CMPSD
            let modRM = try decodeModRM()
            let predicate = Int(try fetch8()) & 7
            let src = try readXMMOperand(modRM)
            sseCompare(variant: variant, dest: modRM.reg & 15, src: src, predicate: predicate)
        case 0xC6: // SHUFPS / SHUFPD
            let modRM = try decodeModRM()
            let selector = try fetch8()
            let src = try readXMMOperand(modRM)
            let dest = xmmRegisters[modRM.reg & 15]
            var result = [UInt8](repeating: 0, count: 16)
            if variant == .pd {
                putLE64(&result, 0, le64(dest, Int(selector & 1) * 8))
                putLE64(&result, 8, le64(src, Int((selector >> 1) & 1) * 8))
            } else if variant == .ps {
                putLE32(&result, 0, le32(dest, Int(selector & 3) * 4))
                putLE32(&result, 4, le32(dest, Int((selector >> 2) & 3) * 4))
                putLE32(&result, 8, le32(src, Int((selector >> 4) & 3) * 4))
                putLE32(&result, 12, le32(src, Int((selector >> 6) & 3) * 4))
            } else { throw opcodeFault(opcode, address: address) }
            xmmRegisters[modRM.reg & 15] = result
        case 0x70: // PSHUFD / PSHUFHW / PSHUFLW
            let modRM = try decodeModRM()
            let selector = try fetch8()
            let src = try readXMMOperand(modRM)
            var result = src
            if variant == .pd {
                for i in 0..<4 { putLE32(&result, i * 4, le32(src, Int((selector >> (2 * i)) & 3) * 4)) }
            } else if variant == .ss {
                for i in 0..<4 {
                    let selected = Int((selector >> (2 * i)) & 3)
                    result[8 + i * 2] = src[8 + selected * 2]
                    result[8 + i * 2 + 1] = src[8 + selected * 2 + 1]
                }
            } else if variant == .sd {
                for i in 0..<4 {
                    let selected = Int((selector >> (2 * i)) & 3)
                    result[i * 2] = src[selected * 2]
                    result[i * 2 + 1] = src[selected * 2 + 1]
                }
            } else { throw opcodeFault(opcode, address: address) }
            xmmRegisters[modRM.reg & 15] = result
        case 0xC4: // PINSRW
            let modRM = try decodeModRM()
            let lane = Int(try fetch8()) & (p66 ? 7 : 3)
            let value = try readOperand(modRM, size: 2)
            if p66 {
                var dest = xmmRegisters[modRM.reg & 15]
                dest[lane * 2] = UInt8(value & 0xFF)
                dest[lane * 2 + 1] = UInt8((value >> 8) & 0xFF)
                xmmRegisters[modRM.reg & 15] = dest
            } else {
                var dest = mmRegisters[modRM.reg & 7]
                dest = (dest & ~(UInt64(0xFFFF) << (lane * 16))) | ((value & 0xFFFF) << (lane * 16))
                mmRegisters[modRM.reg & 7] = dest
            }
        case 0xC5: // PEXTRW
            let modRM = try decodeModRM()
            let lane = Int(try fetch8()) & (p66 ? 7 : 3)
            guard modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            if p66 {
                let src = xmmRegisters[modRM.registerIndex & 15]
                setRegisterValue(modRM.reg, size: 4, UInt64(src[lane * 2]) | UInt64(src[lane * 2 + 1]) << 8)
            } else {
                let src = mmRegisters[modRM.registerIndex & 7]
                setRegisterValue(modRM.reg, size: 4, (src >> (lane * 16)) & 0xFFFF)
            }
        case 0x28: // MOVAPS / MOVAPD（読み込み）
            let modRM = try decodeModRM()
            xmmRegisters[modRM.reg & 15] = try readXMMOperand(modRM)
        case 0x29: // MOVAPS / MOVAPD（書き込み）
            let modRM = try decodeModRM()
            try writeXMMOperand(modRM, xmmRegisters[modRM.reg & 15])
        case 0x10: // MOVUPS / MOVUPD / MOVSS / MOVSD（読み込み）
            let modRM = try decodeModRM()
            switch variant {
            case .ps, .pd:
                xmmRegisters[modRM.reg & 15] = try readXMMOperand(modRM)
            case .ss:
                if modRM.isRegister {
                    var dest = xmmRegisters[modRM.reg & 15]
                    putLE32(&dest, 0, le32(xmmRegisters[modRM.registerIndex & 15], 0))
                    xmmRegisters[modRM.reg & 15] = dest
                } else {
                    var dest = [UInt8](repeating: 0, count: 16)
                    putLE32(&dest, 0, UInt32(try readOperand(modRM, size: 4)))
                    xmmRegisters[modRM.reg & 15] = dest
                }
            case .sd:
                if modRM.isRegister {
                    var dest = xmmRegisters[modRM.reg & 15]
                    putLE64(&dest, 0, le64(xmmRegisters[modRM.registerIndex & 15], 0))
                    xmmRegisters[modRM.reg & 15] = dest
                } else {
                    var dest = [UInt8](repeating: 0, count: 16)
                    putLE64(&dest, 0, try readOperand(modRM, size: 8))
                    xmmRegisters[modRM.reg & 15] = dest
                }
            }
        case 0x11: // MOVUPS / MOVUPD / MOVSS / MOVSD（書き込み）
            let modRM = try decodeModRM()
            let src = xmmRegisters[modRM.reg & 15]
            switch variant {
            case .ps, .pd:
                try writeXMMOperand(modRM, src)
            case .ss:
                if modRM.isRegister {
                    var dest = xmmRegisters[modRM.registerIndex & 15]
                    putLE32(&dest, 0, le32(src, 0))
                    xmmRegisters[modRM.registerIndex & 15] = dest
                } else {
                    try writeOperand(modRM, size: 4, UInt64(le32(src, 0)))
                }
            case .sd:
                if modRM.isRegister {
                    var dest = xmmRegisters[modRM.registerIndex & 15]
                    putLE64(&dest, 0, le64(src, 0))
                    xmmRegisters[modRM.registerIndex & 15] = dest
                } else {
                    try writeOperand(modRM, size: 8, le64(src, 0))
                }
            }
        case 0x12: // MOVLPS / MOVLPD（読み込み）/ MOVHLPS / MOVDDUP（F2）/ MOVSLDUP（F3）
            let modRM = try decodeModRM()
            if decodeRepeatPrefix == 0xF2 { // MOVDDUP
                let low = modRM.isRegister ? le64(xmmRegisters[modRM.registerIndex & 15], 0) : try readOperand(modRM, size: 8)
                var dest = [UInt8](repeating: 0, count: 16)
                putLE64(&dest, 0, low)
                putLE64(&dest, 8, low)
                xmmRegisters[modRM.reg & 15] = dest
                break
            }
            if decodeRepeatPrefix == 0xF3 { // MOVSLDUP
                let src = try readXMMOperand(modRM)
                var dest = [UInt8](repeating: 0, count: 16)
                for lane in 0..<2 {
                    putLE32(&dest, lane * 8, le32(src, lane * 8))
                    putLE32(&dest, lane * 8 + 4, le32(src, lane * 8))
                }
                xmmRegisters[modRM.reg & 15] = dest
                break
            }
            if modRM.isRegister {
                var dest = xmmRegisters[modRM.reg & 15]
                let src = xmmRegisters[modRM.registerIndex & 15]
                for i in 0..<8 { dest[i] = src[i + 8] }
                xmmRegisters[modRM.reg & 15] = dest
            } else {
                var dest = xmmRegisters[modRM.reg & 15]
                putLE64(&dest, 0, try readOperand(modRM, size: 8))
                xmmRegisters[modRM.reg & 15] = dest
            }
        case 0x13: // MOVLPS / MOVLPD（書き込み）
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 8, le64(xmmRegisters[modRM.reg & 15], 0))
        case 0x16: // MOVHPS / MOVHPD（読み込み）/ MOVLHPS / MOVSHDUP（F3）
            let modRM = try decodeModRM()
            if decodeRepeatPrefix == 0xF3 { // MOVSHDUP
                let src = try readXMMOperand(modRM)
                var dest = [UInt8](repeating: 0, count: 16)
                for lane in 0..<2 {
                    putLE32(&dest, lane * 8, le32(src, lane * 8 + 4))
                    putLE32(&dest, lane * 8 + 4, le32(src, lane * 8 + 4))
                }
                xmmRegisters[modRM.reg & 15] = dest
                break
            }
            if modRM.isRegister {
                var dest = xmmRegisters[modRM.reg & 15]
                let src = xmmRegisters[modRM.registerIndex & 15]
                for i in 0..<8 { dest[i + 8] = src[i] }
                xmmRegisters[modRM.reg & 15] = dest
            } else {
                var dest = xmmRegisters[modRM.reg & 15]
                putLE64(&dest, 8, try readOperand(modRM, size: 8))
                xmmRegisters[modRM.reg & 15] = dest
            }
        case 0x17: // MOVHPS / MOVHPD（書き込み）
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 8, le64(xmmRegisters[modRM.reg & 15], 8))
        case 0x14, 0x15: // UNPCKLPS / UNPCKHPS / UNPCKLPD / UNPCKHPD
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            let dest = xmmRegisters[modRM.reg & 15]
            var result = [UInt8](repeating: 0, count: 16)
            if variant == .pd {
                let lane = opcode == 0x15 ? 1 : 0
                putLE64(&result, 0, le64(dest, lane * 8))
                putLE64(&result, 8, le64(src, lane * 8))
            } else {
                let base = opcode == 0x15 ? 2 : 0
                for i in 0..<2 {
                    putLE32(&result, i * 8, le32(dest, (base + i) * 4))
                    putLE32(&result, i * 8 + 4, le32(src, (base + i) * 4))
                }
            }
            xmmRegisters[modRM.reg & 15] = result
        case 0x6F: // MOVDQA / MOVDQU（読み込み）/ MOVQ mm（プリフィクスなし）
            let modRM = try decodeModRM()
            if p66 || decodeRepeatPrefix == 0xF3 {
                xmmRegisters[modRM.reg & 15] = try readXMMOperand(modRM)
            } else {
                mmRegisters[modRM.reg & 7] = modRM.isRegister ? mmRegisters[modRM.registerIndex & 7] : try readOperand(modRM, size: 8)
            }
        case 0x7F, 0xE7: // MOVDQA / MOVDQU / MOVNTDQ（書き込み）/ MOVQ mm, m64（プリフィクスなし）
            let modRM = try decodeModRM()
            if p66 || decodeRepeatPrefix == 0xF3 {
                try writeXMMOperand(modRM, xmmRegisters[modRM.reg & 15])
            } else if modRM.isRegister {
                mmRegisters[modRM.registerIndex & 7] = mmRegisters[modRM.reg & 7]
            } else {
                try writeOperand(modRM, size: 8, mmRegisters[modRM.reg & 7])
            }
        case 0x6E: // MOVD / MOVQ（GPR・メモリ → XMM）/ MOVD mm（プリフィクスなし）
            let modRM = try decodeModRM()
            if !p66 {
                mmRegisters[modRM.reg & 7] = try readOperand(modRM, size: 4) & 0xFFFFFFFF
                break
            }
            var dest = [UInt8](repeating: 0, count: 16)
            if operandSize == 8 {
                putLE64(&dest, 0, try readOperand(modRM, size: 8))
            } else {
                putLE32(&dest, 0, UInt32(try readOperand(modRM, size: 4)))
            }
            xmmRegisters[modRM.reg & 15] = dest
        case 0x7E: // MOVD（XMM → GPR・メモリ）/ MOVQ（読み込み）
            let modRM = try decodeModRM()
            if variant == .ss { // MOVQ xmm, r/m64（読み込み）
                var dest = [UInt8](repeating: 0, count: 16)
                if modRM.isRegister {
                    putLE64(&dest, 0, le64(xmmRegisters[modRM.registerIndex & 15], 0))
                } else {
                    putLE64(&dest, 0, try readOperand(modRM, size: 8))
                }
                xmmRegisters[modRM.reg & 15] = dest
            } else if p66 { // MOVD r/m, xmm
                let src = xmmRegisters[modRM.reg & 15]
                if operandSize == 8 {
                    try writeOperand(modRM, size: 8, le64(src, 0))
                } else {
                    try writeOperand(modRM, size: 4, UInt64(le32(src, 0)))
                }
            } else if decodeRepeatPrefix == 0 { // MOVD r/m32, mm
                try writeOperand(modRM, size: 4, mmRegisters[modRM.reg & 7] & 0xFFFFFFFF)
            } else { throw opcodeFault(opcode, address: address) }
        case 0xD6: // MOVQ（書き込み）
            guard p66 else { throw opcodeFault(opcode, address: address) }
            let modRM = try decodeModRM()
            try writeOperand(modRM, size: 8, le64(xmmRegisters[modRM.reg & 15], 0))
        case 0x51, 0x52, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F: // 浮動小数点演算
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            sseFloatArithmetic(opcode: opcode, variant: variant, dest: modRM.reg & 15, src: src)
        case 0x2E, 0x2F: // UCOMISS / COMISS / UCOMISD / COMISD
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            let dest = xmmRegisters[modRM.reg & 15]
            if variant == .pd {
                fpuCompareFlags(Double(bitPattern: le64(dest, 0)), Double(bitPattern: le64(src, 0)))
            } else {
                fpuCompareFlags(Double(Float(bitPattern: le32(dest, 0))), Double(Float(bitPattern: le32(src, 0))))
            }
        case 0x50: // MOVMSKPS / MOVMSKPD
            let modRM = try decodeModRM()
            guard modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            let src = xmmRegisters[modRM.registerIndex & 15]
            var maskValue: UInt64 = 0
            if variant == .pd {
                for lane in 0..<2 where src[lane * 8 + 7] & 0x80 != 0 { maskValue |= UInt64(1 << lane) }
            } else if variant == .ps {
                for lane in 0..<4 where src[lane * 4 + 3] & 0x80 != 0 { maskValue |= UInt64(1 << lane) }
            } else { throw opcodeFault(opcode, address: address) }
            setRegisterValue(modRM.reg, size: 4, maskValue)
        case 0x2A: // CVTSI2SS / CVTSI2SD（宛先の上位ビットは保持される）
            let modRM = try decodeModRM()
            let raw = try readOperand(modRM, size: operandSize == 8 ? 8 : 4)
            var result = xmmRegisters[modRM.reg & 15]
            if variant == .ss {
                let value = operandSize == 8 ? Float(Int64(bitPattern: raw)) : Float(Int32(bitPattern: UInt32(raw)))
                putLE32(&result, 0, value.bitPattern)
            } else if variant == .sd {
                let value = operandSize == 8 ? Double(Int64(bitPattern: raw)) : Double(Int32(bitPattern: UInt32(raw)))
                putLE64(&result, 0, value.bitPattern)
            } else { throw opcodeFault(opcode, address: address) }
            xmmRegisters[modRM.reg & 15] = result
        case 0x2C, 0x2D: // CVTTSS2SI / CVTSS2SI / CVTTSD2SI / CVTSD2SI
            let modRM = try decodeModRM()
            let destSize = operandSize == 8 ? 8 : 4
            let converted: UInt64
            if variant == .ss {
                let value: Float
                if modRM.isRegister { value = Float(bitPattern: le32(xmmRegisters[modRM.registerIndex & 15], 0)) }
                else { value = Float(bitPattern: UInt32(try readOperand(modRM, size: 4))) }
                converted = convertToInteger(Double(value), truncate: opcode == 0x2C, size: destSize)
            } else if variant == .sd {
                let value: Double
                if modRM.isRegister { value = Double(bitPattern: le64(xmmRegisters[modRM.registerIndex & 15], 0)) }
                else { value = Double(bitPattern: try readOperand(modRM, size: 8)) }
                converted = convertToInteger(value, truncate: opcode == 0x2C, size: destSize)
            } else { throw opcodeFault(opcode, address: address) }
            setRegisterValue(modRM.reg, size: destSize, converted)
        case 0x5A: // CVTPS2PD / CVTPD2PS / CVTSS2SD / CVTSD2SS
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            var result = [UInt8](repeating: 0, count: 16)
            switch variant {
            case .ps:
                for lane in 0..<2 { putLE64(&result, lane * 8, Double(Float(bitPattern: le32(src, lane * 4))).bitPattern) }
            case .pd:
                for lane in 0..<2 { putLE32(&result, lane * 4, Float(Double(bitPattern: le64(src, lane * 8))).bitPattern) }
            case .ss:   // CVTSS2SD: 宛先の上位 64 ビットは保持
                result = xmmRegisters[modRM.reg & 15]
                putLE64(&result, 0, Double(Float(bitPattern: le32(src, 0))).bitPattern)
            case .sd:   // CVTSD2SS: 宛先の上位 96 ビットは保持
                result = xmmRegisters[modRM.reg & 15]
                putLE32(&result, 0, Float(Double(bitPattern: le64(src, 0))).bitPattern)
            }
            xmmRegisters[modRM.reg & 15] = result
        case 0xE6: // CVTPD2DQ / CVTTPD2DQ / CVTDQ2PD
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            var result = [UInt8](repeating: 0, count: 16)
            switch variant {
            case .pd:
                for lane in 0..<2 { putLE32(&result, lane * 4, convertToDword(Double(bitPattern: le64(src, lane * 8)), truncate: false)) }
            case .sd:
                for lane in 0..<2 { putLE32(&result, lane * 4, convertToDword(Double(bitPattern: le64(src, lane * 8)), truncate: true)) }
            case .ss:
                for lane in 0..<2 { putLE64(&result, lane * 8, Double(Int32(bitPattern: le32(src, lane * 4))).bitPattern) }
            default: throw opcodeFault(opcode, address: address)
            }
            xmmRegisters[modRM.reg & 15] = result
        case 0x60...0x6D, 0x74, 0x75, 0x76, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF,
             0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF,
             0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE: // 整数演算（SSE2 / MMX）
            let modRM = try decodeModRM()
            if p66 {
                let src = try readXMMOperand(modRM)
                try sseInteger(opcode: opcode, dest: modRM.reg & 15, src: src, address: address)
            } else { // MMX 形式（66 プリフィクスなし）
                let src = modRM.isRegister ? mmRegisters[modRM.registerIndex & 7] : try readOperand(modRM, size: 8)
                mmRegisters[modRM.reg & 7] = try mmxInteger(opcode: opcode, dest: mmRegisters[modRM.reg & 7], src: src, address: address)
            }
        case 0xD7: // PMOVMSKB
            let modRM = try decodeModRM()
            guard modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            var mask: UInt64 = 0
            if p66 {
                let src = xmmRegisters[modRM.registerIndex & 15]
                for i in 0..<16 where src[i] & 0x80 != 0 { mask |= UInt64(1 << i) }
            } else {
                let src = mmRegisters[modRM.registerIndex & 7]
                for i in 0..<8 where (src >> (i * 8 + 7)) & 1 != 0 { mask |= UInt64(1 << i) }
            }
            setRegisterValue(modRM.reg, size: 4, mask)
        case 0xD0: // ADDSUBPS（F2）/ ADDSUBPD（66）
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            let dest = modRM.reg & 15
            var result = xmmRegisters[dest]
            if decodeRepeatPrefix == 0xF2 {
                for lane in 0..<4 {
                    let a = Float(bitPattern: le32(result, lane * 4))
                    let b = Float(bitPattern: le32(src, lane * 4))
                    putLE32(&result, lane * 4, (lane % 2 == 0 ? a - b : a + b).bitPattern)
                }
            } else if p66 {
                for lane in 0..<2 {
                    let a = Double(bitPattern: le64(result, lane * 8))
                    let b = Double(bitPattern: le64(src, lane * 8))
                    putLE64(&result, lane * 8, (lane % 2 == 0 ? a - b : a + b).bitPattern)
                }
            } else { throw opcodeFault(opcode, address: address) }
            xmmRegisters[dest] = result
        case 0x7C, 0x7D: // HADDPS / HADDPD（F2 / 66）、HSUBPS / HSUBPD
            let modRM = try decodeModRM()
            let src = try readXMMOperand(modRM)
            let dest = modRM.reg & 15
            let destBytes = xmmRegisters[dest]
            var result = [UInt8](repeating: 0, count: 16)
            let subtract = opcode == 0x7D
            if decodeRepeatPrefix == 0xF2 {
                let lanes: [Float] = (0..<4).map { Float(bitPattern: le32(destBytes, $0 * 4)) }
                let other: [Float] = (0..<4).map { Float(bitPattern: le32(src, $0 * 4)) }
                let pairs: [Float] = [subtract ? lanes[0] - lanes[1] : lanes[0] + lanes[1],
                                      subtract ? lanes[2] - lanes[3] : lanes[2] + lanes[3],
                                      subtract ? other[0] - other[1] : other[0] + other[1],
                                      subtract ? other[2] - other[3] : other[2] + other[3]]
                for i in 0..<4 { putLE32(&result, i * 4, pairs[i].bitPattern) }
            } else if p66 {
                let a0 = Double(bitPattern: le64(destBytes, 0)), a1 = Double(bitPattern: le64(destBytes, 8))
                let b0 = Double(bitPattern: le64(src, 0)), b1 = Double(bitPattern: le64(src, 8))
                putLE64(&result, 0, (subtract ? a0 - a1 : a0 + a1).bitPattern)
                putLE64(&result, 8, (subtract ? b0 - b1 : b0 + b1).bitPattern)
            } else { throw opcodeFault(opcode, address: address) }
            xmmRegisters[dest] = result
        case 0xF0: // LDDQU（F2）
            guard decodeRepeatPrefix == 0xF2 else { throw opcodeFault(opcode, address: address) }
            let modRM = try decodeModRM()
            xmmRegisters[modRM.reg & 15] = try readXMMOperand(modRM)
        default:
            throw opcodeFault(opcode, address: address)
        }
    }


    // MARK: - MMX

    /// MMX 整数演算（64 ビット幅）。PACK / PUNPCK 系は専用実装、それ以外は
    /// 128 ビット版カーネルを下位 64 ビットに限定して再利用する。
    private func mmxInteger(opcode: UInt8, dest: UInt64, src: UInt64, address: UInt64) throws -> UInt64 {
        func byte(_ value: UInt64, _ index: Int) -> UInt8 { UInt8((value >> (index * 8)) & 0xFF) }
        func word(_ value: UInt64, _ index: Int) -> UInt16 { UInt16((value >> (index * 16)) & 0xFFFF) }
        func dword(_ value: UInt64, _ index: Int) -> UInt32 { UInt32((value >> (index * 32)) & 0xFFFFFFFF) }
        switch opcode {
        case 0x6C, 0x6D: // PUNPCKLQDQ / PUNPCKHQDQ は MMX 形式なし
            throw opcodeFault(opcode, address: address)
        case 0x60, 0x61, 0x62, 0x68, 0x69, 0x6A: // PUNPCK L/H（BW / WD / DQ）
            let size = (opcode == 0x60 || opcode == 0x68) ? 1 : ((opcode == 0x61 || opcode == 0x69) ? 2 : 4)
            let base = opcode >= 0x68 ? 4 / size : 0
            var result: UInt64 = 0
            for i in 0..<(4 / size) {
                let shift = (2 * i) * size * 8
                switch size {
                case 1:
                    result |= UInt64(byte(dest, base + i)) << shift
                    result |= UInt64(byte(src, base + i)) << (shift + 8)
                case 2:
                    result |= UInt64(word(dest, base + i)) << shift
                    result |= UInt64(word(src, base + i)) << (shift + 16)
                default:
                    result |= UInt64(dword(dest, base + i)) << shift
                    result |= UInt64(dword(src, base + i)) << (shift + 32)
                }
            }
            return result
        case 0x63, 0x67: // PACKSSWB / PACKUSWB
            var result: UInt64 = 0
            for i in 0..<4 {
                for (offset, value) in [(0, dest), (4, src)] {
                    let raw = Int16(bitPattern: word(value, i))
                    let packed: UInt8
                    if opcode == 0x63 {
                        packed = UInt8(bitPattern: Int8(max(-128, min(127, Int(raw)))))
                    } else {
                        packed = UInt8(max(0, min(255, Int(raw))))
                    }
                    result |= UInt64(packed) << ((offset + i) * 8)
                }
            }
            return result
        case 0x6B: // PACKSSDW
            var result: UInt64 = 0
            for i in 0..<2 {
                for (offset, value) in [(0, dest), (2, src)] {
                    let raw = Int32(bitPattern: dword(value, i))
                    let packed = UInt16(bitPattern: Int16(max(-32768, min(32767, Int(raw)))))
                    result |= UInt64(packed) << ((offset + i) * 16)
                }
            }
            return result
        default:
            // 下位 64 ビットにゼロ拡張して 128 ビット版カーネルを流用する
            let saved = xmmRegisters[0]
            var destBytes = [UInt8](repeating: 0, count: 16)
            var srcBytes = [UInt8](repeating: 0, count: 16)
            putLE64(&destBytes, 0, dest)
            putLE64(&srcBytes, 0, src)
            xmmRegisters[0] = destBytes
            try sseInteger(opcode: opcode, dest: 0, src: srcBytes, address: address)
            let result = le64(xmmRegisters[0], 0)
            xmmRegisters[0] = saved
            return result
        }
    }

    private func mmxShiftImmediate(opcode: UInt8, subOperation: Int, value: UInt64, count: Int, address: UInt64) throws -> UInt64 {
        func lanes(_ size: Int, _ body: (UInt64) -> UInt64) -> UInt64 {
            var result: UInt64 = 0
            let mask: UInt64 = size == 8 ? UInt64.max : (UInt64(1) << (size * 8)) - 1
            for i in 0..<(8 / size) {
                let lane = (value >> (i * size * 8)) & mask
                result |= (body(lane) & mask) << (i * size * 8)
            }
            return result
        }
        switch (opcode, subOperation) {
        case (0x71, 2): return lanes(2) { count > 15 ? 0 : $0 >> count }
        case (0x71, 4): return lanes(2) { count > 15 ? (Int16(bitPattern: UInt16($0)) < 0 ? 0xFFFF : 0) : UInt64(bitPattern: Int64(Int16(bitPattern: UInt16($0)) >> count)) }
        case (0x71, 6): return lanes(2) { count > 15 ? 0 : $0 << count }
        case (0x72, 2): return lanes(4) { count > 31 ? 0 : $0 >> count }
        case (0x72, 4): return lanes(4) { count > 31 ? (Int32(bitPattern: UInt32($0)) < 0 ? 0xFFFFFFFF : 0) : UInt64(bitPattern: Int64(Int32(bitPattern: UInt32($0)) >> count)) }
        case (0x72, 6): return lanes(4) { count > 31 ? 0 : $0 << count }
        case (0x73, 2): return count > 63 ? 0 : value >> count
        case (0x73, 6): return count > 63 ? 0 : value << count
        default: throw opcodeFault(opcode, address: address)
        }
    }

    // MARK: - SSSE3 / SSE4（0F 38 / 0F 3A マップ）

    private func checkSSEAvailable(_ opcode: UInt8, address: UInt64) throws {
        if controlRegisters[0] & 0x4 != 0 || controlRegisters[0] & 0x8 != 0 { throw CPUTrap.exception(vector: 7, errorCode: nil) }
        if controlRegisters[4] & 0x200 == 0 { throw opcodeFault(opcode, address: address) }
    }

    private func executeSSE38(operandSize: Int, address: UInt64) throws {
        let opcode = try fetch8()
        if opcode == 0xF0 || opcode == 0xF1 { // MOVBE
            let modRM = try decodeModRM()
            guard !modRM.isRegister else { throw opcodeFault(opcode, address: address) }
            if opcode == 0xF0 {
                let raw = try readOperand(modRM, size: operandSize)
                setRegisterValue(modRM.reg, size: operandSize, operandSize == 8 ? raw.byteSwapped : (operandSize == 4 ? UInt64(UInt32(raw).byteSwapped) : UInt64(UInt16(raw).byteSwapped)))
            } else {
                let raw = registerValue(modRM.reg, size: operandSize)
                let swapped = operandSize == 8 ? raw.byteSwapped : (operandSize == 4 ? UInt64(UInt32(raw).byteSwapped) : UInt64(UInt16(raw).byteSwapped))
                try writeOperand(modRM, size: operandSize, swapped)
            }
            return
        }
        try checkSSEAvailable(opcode, address: address)
        let modRM = try decodeModRM()
        let p66 = decodePrefix66
        let isSSSE3 = (0x00...0x0B).contains(opcode) || (0x1C...0x1E).contains(opcode)
        if !p66 {
            guard isSSSE3 else { throw opcodeFault(opcode, address: address) }
            let src = modRM.isRegister ? mmRegisters[modRM.registerIndex & 7] : try readOperand(modRM, size: 8)
            var srcBytes = [UInt8](repeating: 0, count: 8)
            var destBytes = [UInt8](repeating: 0, count: 8)
            putLE64(&srcBytes, 0, src)
            putLE64(&destBytes, 0, mmRegisters[modRM.reg & 7])
            mmRegisters[modRM.reg & 7] = le64(try ssse3Kernel(opcode: opcode, dest: destBytes, src: srcBytes, address: address), 0)
            return
        }
        let dest = modRM.reg & 15
        switch opcode {
        case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35: // PMOVSX / PMOVZX
            let sign = opcode < 0x28
            let kind = Int(opcode & 0xF)
            let srcCount = [8, 4, 2, 8, 4, 8][kind]
            let laneSize = [2, 4, 8, 4, 8, 8][kind]
            var srcBytes = [UInt8](repeating: 0, count: 16)
            if modRM.isRegister {
                srcBytes = xmmRegisters[modRM.registerIndex & 15]
            } else {
                let raw = try readOperandBytes(modRM, count: srcCount)
                for i in 0..<srcCount { srcBytes[i] = raw[i] }
            }
            var result = [UInt8](repeating: 0, count: 16)
            let elementSize = [1, 1, 1, 2, 2, 4][kind]
            let elements = 16 / laneSize
            for i in 0..<elements {
                var raw: UInt64 = 0
                for k in 0..<elementSize { raw |= UInt64(srcBytes[i * elementSize + k]) << (8 * k) }
                let extended: UInt64
                if sign {
                    switch elementSize {
                    case 1: extended = UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(raw))))
                    case 2: extended = UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(raw))))
                    default: extended = UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(raw))))
                    }
                } else { extended = raw }
                for k in 0..<laneSize { result[i * laneSize + k] = UInt8((extended >> (8 * k)) & 0xFF) }
            }
            xmmRegisters[dest] = result
        case 0x29: // PCMPEQQ
            let src = try readXMMOperand(modRM)
            var result = xmmRegisters[dest]
            for lane in 0..<2 {
                putLE64(&result, lane * 8, le64(result, lane * 8) == le64(src, lane * 8) ? UInt64.max : 0)
            }
            xmmRegisters[dest] = result
        case 0x40: // PMULLD
            let src = try readXMMOperand(modRM)
            var result = xmmRegisters[dest]
            for lane in 0..<4 {
                putLE32(&result, lane * 4, le32(result, lane * 4) &* le32(src, lane * 4))
            }
            xmmRegisters[dest] = result
        case 0x28: // PMULDQ
            let src = try readXMMOperand(modRM)
            var result = xmmRegisters[dest]
            for lane in 0..<2 {
                let a = Int64(Int32(bitPattern: le32(result, lane * 8)))
                let b = Int64(Int32(bitPattern: le32(src, lane * 8)))
                putLE64(&result, lane * 8, UInt64(bitPattern: a * b))
            }
            xmmRegisters[dest] = result
        default:
            guard isSSSE3 else { throw opcodeFault(opcode, address: address) }
            let src = try readXMMOperand(modRM)
            xmmRegisters[dest] = try ssse3Kernel(opcode: opcode, dest: xmmRegisters[dest], src: src, address: address)
        }
    }

    /// SSSE3 カーネル（幅 8 = MMX / 幅 16 = XMM 共通）。
    private func ssse3Kernel(opcode: UInt8, dest: [UInt8], src: [UInt8], address: UInt64) throws -> [UInt8] {
        let width = dest.count
        var result = dest
        func lane(_ bytes: [UInt8], _ size: Int, _ index: Int) -> UInt64 {
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(bytes[index * size + k]) << (8 * k) }
            return value
        }
        func setLane(_ size: Int, _ index: Int, _ value: UInt64) {
            for k in 0..<size { result[index * size + k] = UInt8((value >> (8 * k)) & 0xFF) }
        }
        func signed(_ bytes: [UInt8], _ size: Int, _ index: Int) -> Int64 {
            let raw = lane(bytes, size, index)
            switch size {
            case 1: return Int64(Int8(bitPattern: UInt8(raw)))
            case 2: return Int64(Int16(bitPattern: UInt16(raw)))
            default: return Int64(Int32(bitPattern: UInt32(raw)))
            }
        }
        switch opcode {
        case 0x00: // PSHUFB
            for i in 0..<width {
                result[i] = src[i] & 0x80 != 0 ? 0 : dest[Int(src[i]) & (width - 1)]
            }
        case 0x01, 0x02, 0x05, 0x06: // PHADDW / PHADDD / PHSUBW / PHSUBD
            let size = (opcode == 0x01 || opcode == 0x05) ? 2 : 4
            let subtract = opcode >= 0x05
            // 水平演算はレジスタ全幅に対して dest のペアをすべて並べ、
            // 続けて src のペアを並べる（64 ビット単位で混ぜてはいけない）
            var out = [UInt8](repeating: 0, count: width)
            var produced = 0
            for source in [dest, src] {
                var index = 0
                while index < width / size {
                    let a = signed(source, size, index)
                    let b = signed(source, size, index + 1)
                    let value = subtract ? a - b : a + b
                    for k in 0..<size { out[produced * size + k] = UInt8((UInt64(bitPattern: value) >> (8 * k)) & 0xFF) }
                    produced += 1
                    index += 2
                }
            }
            result = out
        case 0x03: // PHADDSW（飽和水平加算）
            var out = [UInt8](repeating: 0, count: width)
            var produced = 0
            for source in [dest, src] {
                var index = 0
                while index < width / 2 {
                    let value = max(-32768, min(32767, Int(signed(source, 2, index) + signed(source, 2, index + 1))))
                    out[produced * 2] = UInt8(value & 0xFF)
                    out[produced * 2 + 1] = UInt8((value >> 8) & 0xFF)
                    produced += 1
                    index += 2
                }
            }
            result = out
        case 0x04: // PMADDUBSW
            for chunkStart in stride(from: 0, to: width, by: 8) {
                for j in 0..<4 {
                    let i0 = chunkStart + j * 2
                    let product = Int(dest[i0]) * Int(Int8(bitPattern: src[i0])) + Int(dest[i0 + 1]) * Int(Int8(bitPattern: src[i0 + 1]))
                    let clamped = max(-32768, min(32767, product))
                    result[i0] = UInt8(clamped & 0xFF)
                    result[i0 + 1] = UInt8((clamped >> 8) & 0xFF)
                }
            }
        case 0x07: // PHSUBSW
            var out = [UInt8](repeating: 0, count: width)
            var produced = 0
            for source in [dest, src] {
                var index = 0
                while index < width / 2 {
                    let value = max(-32768, min(32767, Int(signed(source, 2, index) - signed(source, 2, index + 1))))
                    out[produced * 2] = UInt8(value & 0xFF)
                    out[produced * 2 + 1] = UInt8((value >> 8) & 0xFF)
                    produced += 1
                    index += 2
                }
            }
            result = out
        case 0x0B: // PMULHRSW
            for i in 0..<(width / 2) {
                let product = signed(dest, 2, i) * signed(src, 2, i)
                setLane(2, i, UInt64(bitPattern: (product + 0x4000) >> 15))
            }
        case 0x08, 0x09, 0x0A: // PSIGNB / PSIGNW / PSIGND
            let size = opcode == 0x08 ? 1 : (opcode == 0x09 ? 2 : 4)
            for i in 0..<(width / size) {
                let condition = signed(src, size, i)
                let value = signed(dest, size, i)
                setLane(size, i, UInt64(bitPattern: condition < 0 ? -value : (condition == 0 ? 0 : value)))
            }
        case 0x1C, 0x1D, 0x1E: // PABSB / PABSW / PABSD
            let size = opcode == 0x1C ? 1 : (opcode == 0x1D ? 2 : 4)
            for i in 0..<(width / size) {
                setLane(size, i, UInt64(bitPattern: abs(signed(dest, size, i))))
            }
        default:
            throw opcodeFault(opcode, address: address)
        }
        return result
    }

    private func executeSSE3A(operandSize: Int, address: UInt64) throws {
        let opcode = try fetch8()
        try checkSSEAvailable(opcode, address: address)
        guard decodePrefix66 else { throw opcodeFault(opcode, address: address) }
        let modRM = try decodeModRM()
        let immediate = try fetch8()
        let dest = modRM.reg & 15
        func roundingMode() -> FloatingPointRoundingRule {
            switch (immediate & 4 != 0 ? Int((mxcsr >> 13) & 3) : Int(immediate & 3)) {
            case 1: return .down
            case 2: return .up
            case 3: return .towardZero
            default: return .toNearestOrEven
            }
        }
        switch opcode {
        case 0x08, 0x09: // ROUNDPS / ROUNDPD
            let src = try readXMMOperand(modRM)
            var result = [UInt8](repeating: 0, count: 16)
            if opcode == 0x08 {
                for lane in 0..<4 { putLE32(&result, lane * 4, Float(bitPattern: le32(src, lane * 4)).rounded(roundingMode()).bitPattern) }
            } else {
                for lane in 0..<2 { putLE64(&result, lane * 8, Double(bitPattern: le64(src, lane * 8)).rounded(roundingMode()).bitPattern) }
            }
            xmmRegisters[dest] = result
        case 0x0A, 0x0B: // ROUNDSS / ROUNDSD（上位はデスティネーションを保持）
            var result = xmmRegisters[dest]
            if opcode == 0x0A {
                let value = modRM.isRegister ? Float(bitPattern: le32(xmmRegisters[modRM.registerIndex & 15], 0)) : Float(bitPattern: UInt32(try readOperand(modRM, size: 4)))
                putLE32(&result, 0, value.rounded(roundingMode()).bitPattern)
            } else {
                let value = modRM.isRegister ? Double(bitPattern: le64(xmmRegisters[modRM.registerIndex & 15], 0)) : Double(bitPattern: try readOperand(modRM, size: 8))
                putLE64(&result, 0, value.rounded(roundingMode()).bitPattern)
            }
            xmmRegisters[dest] = result
        case 0x0C, 0x0D, 0x0E: // BLENDPS / BLENDPD / PBLENDW
            let src = try readXMMOperand(modRM)
            var result = xmmRegisters[dest]
            let size = opcode == 0x0C ? 4 : (opcode == 0x0D ? 8 : 2)
            for lane in 0..<(16 / size) where immediate & UInt8(1 << lane) != 0 {
                for k in 0..<size { result[lane * size + k] = src[lane * size + k] }
            }
            xmmRegisters[dest] = result
        case 0x14: // PEXTRB（宛先は r/m8）
            let value = xmmRegisters[dest][Int(immediate & 15)]
            try writeOperand(modRM, size: 1, UInt64(value))
        case 0x16: // PEXTRD / PEXTRQ（宛先は r/m）
            if operandSize == 8 {
                try writeOperand(modRM, size: 8, le64(xmmRegisters[dest], Int(immediate & 1) * 8))
            } else {
                try writeOperand(modRM, size: 4, UInt64(le32(xmmRegisters[dest], Int(immediate & 3) * 4)))
            }
        case 0x17: // EXTRACTPS（宛先は r/m32）
            try writeOperand(modRM, size: 4, UInt64(le32(xmmRegisters[dest], Int(immediate & 3) * 4)))
        case 0x20: // PINSRB
            let value = try readOperand(modRM, size: 1)
            xmmRegisters[dest][Int(immediate & 15)] = UInt8(value & 0xFF)
        case 0x21: // INSERTPS
            var result = xmmRegisters[dest]
            let sourceLane: UInt32
            if modRM.isRegister {
                sourceLane = le32(xmmRegisters[modRM.registerIndex & 15], Int((immediate >> 6) & 3) * 4)
            } else {
                sourceLane = UInt32(try readOperand(modRM, size: 4))
            }
            putLE32(&result, Int((immediate >> 4) & 3) * 4, sourceLane)
            for lane in 0..<4 where immediate & UInt8(1 << lane) != 0 { putLE32(&result, lane * 4, 0) }
            xmmRegisters[dest] = result
        case 0x22: // PINSRD / PINSRQ
            if operandSize == 8 {
                let value = try readOperand(modRM, size: 8)
                putLE64(&xmmRegisters[dest], Int(immediate & 1) * 8, value)
            } else {
                let value = try readOperand(modRM, size: 4)
                putLE32(&xmmRegisters[dest], Int(immediate & 3) * 4, UInt32(value))
            }
        case 0x40: // DPPS
            let src = try readXMMOperand(modRM)
            let destBytes = xmmRegisters[dest]
            var sum: Float = 0
            for lane in 0..<4 where immediate & UInt8(0x10 << lane) != 0 {
                sum += Float(bitPattern: le32(destBytes, lane * 4)) * Float(bitPattern: le32(src, lane * 4))
            }
            var result = [UInt8](repeating: 0, count: 16)
            for lane in 0..<4 where immediate & UInt8(1 << lane) != 0 { putLE32(&result, lane * 4, sum.bitPattern) }
            xmmRegisters[dest] = result
        case 0x41: // DPPD
            let src = try readXMMOperand(modRM)
            let destBytes = xmmRegisters[dest]
            var sum: Double = 0
            for lane in 0..<2 where immediate & UInt8(0x10 << lane) != 0 {
                sum += Double(bitPattern: le64(destBytes, lane * 8)) * Double(bitPattern: le64(src, lane * 8))
            }
            var result = [UInt8](repeating: 0, count: 16)
            for lane in 0..<2 where immediate & UInt8(1 << lane) != 0 { putLE64(&result, lane * 8, sum.bitPattern) }
            xmmRegisters[dest] = result
        case 0x42: // MPSADBW
            let src = try readXMMOperand(modRM)
            let destBytes = xmmRegisters[dest]
            var result = [UInt8](repeating: 0, count: 16)
            let destBase = Int(immediate & 1) * 4
            let srcBase = Int((immediate >> 2) & 1) * 4
            for i in 0..<8 {
                var sum = 0
                for k in 0..<4 { sum += abs(Int(destBytes[destBase + i + k]) - Int(src[srcBase + k])) }
                result[i * 2] = UInt8(sum & 0xFF)
                result[i * 2 + 1] = UInt8((sum >> 8) & 0xFF)
            }
            xmmRegisters[dest] = result
        default:
            throw opcodeFault(opcode, address: address)
        }
    }

    private func convertToInteger(_ value: Double, truncate: Bool, size: Int) -> UInt64 {
        let rounded = truncate ? value.rounded(.towardZero) : value.rounded(.toNearestOrEven)
        if size == 8 {
            if rounded.isNaN || rounded >= 9.223372036854776e18 || rounded < -9.223372036854776e18 { return 0x8000000000000000 }
            return UInt64(bitPattern: Int64(rounded))
        }
        if rounded.isNaN || rounded >= 2147483648.0 || rounded < -2147483648.0 { return 0x80000000 }
        return UInt64(UInt32(bitPattern: Int32(rounded)))
    }

    private func convertToDword(_ value: Double, truncate: Bool) -> UInt32 {
        let rounded = truncate ? value.rounded(.towardZero) : value.rounded(.toNearestOrEven)
        if rounded.isNaN || rounded >= 2147483648.0 || rounded < -2147483648.0 { return 0x80000000 }
        return UInt32(bitPattern: Int32(rounded))
    }

    private func ssePredicate(_ predicate: Int, _ a: Double, _ b: Double) -> Bool {
        switch predicate {
        case 0: return a == b
        case 1: return a < b
        case 2: return a <= b
        case 3: return a.isNaN || b.isNaN
        case 4: return a.isNaN || b.isNaN || a != b
        case 5: return a.isNaN || b.isNaN || a >= b
        case 6: return a.isNaN || b.isNaN || a > b
        case 7: return !a.isNaN && !b.isNaN
        default: return false
        }
    }

    private func sseCompare(variant: SSEVariant, dest: Int, src: [UInt8], predicate: Int) {
        let destBytes = xmmRegisters[dest]
        var result = destBytes
        switch variant {
        case .ps:
            for lane in 0..<4 {
                let a = Double(Float(bitPattern: le32(destBytes, lane * 4)))
                let b = Double(Float(bitPattern: le32(src, lane * 4)))
                putLE32(&result, lane * 4, ssePredicate(predicate, a, b) ? 0xFFFFFFFF : 0)
            }
        case .pd:
            for lane in 0..<2 {
                let a = Double(bitPattern: le64(destBytes, lane * 8))
                let b = Double(bitPattern: le64(src, lane * 8))
                putLE64(&result, lane * 8, ssePredicate(predicate, a, b) ? UInt64.max : 0)
            }
        case .ss:
            let a = Double(Float(bitPattern: le32(destBytes, 0)))
            let b = Double(Float(bitPattern: le32(src, 0)))
            putLE32(&result, 0, ssePredicate(predicate, a, b) ? 0xFFFFFFFF : 0)
        case .sd:
            let a = Double(bitPattern: le64(destBytes, 0))
            let b = Double(bitPattern: le64(src, 0))
            putLE64(&result, 0, ssePredicate(predicate, a, b) ? UInt64.max : 0)
        }
        xmmRegisters[dest] = result
    }

    private func sseFloatArithmetic(opcode: UInt8, variant: SSEVariant, dest: Int, src: [UInt8]) {
        let destBytes = xmmRegisters[dest]
        var result = destBytes
        if opcode >= 0x54 && opcode <= 0x57 { // AND / ANDN / OR / XOR（ビット演算）
            for i in 0..<16 {
                switch opcode {
                case 0x54: result[i] = destBytes[i] & src[i]
                case 0x55: result[i] = ~destBytes[i] & src[i]
                case 0x56: result[i] = destBytes[i] | src[i]
                default: result[i] = destBytes[i] ^ src[i]
                }
            }
            xmmRegisters[dest] = result
            return
        }
        func floatOp(_ a: Float, _ b: Float) -> Float {
            switch opcode {
            case 0x51: return sqrt(b)
            case 0x52: return 1 / sqrt(b)
            case 0x58: return a + b
            case 0x59: return a * b
            case 0x5C: return a - b
            case 0x5D: return (a < b || b.isNaN) ? (b.isNaN ? b : a) : b // MIN（第2オペランド優先の仕様に寄せる）
            case 0x5E: return a / b
            case 0x5F: return (a > b || b.isNaN) ? (b.isNaN ? b : a) : b // MAX
            default: return b
            }
        }
        func doubleOp(_ a: Double, _ b: Double) -> Double {
            switch opcode {
            case 0x51: return sqrt(b)
            case 0x58: return a + b
            case 0x59: return a * b
            case 0x5C: return a - b
            case 0x5D: return (a < b || b.isNaN) ? (b.isNaN ? b : a) : b
            case 0x5E: return a / b
            case 0x5F: return (a > b || b.isNaN) ? (b.isNaN ? b : a) : b
            default: return b
            }
        }
        switch variant {
        case .ps:
            for lane in 0..<4 {
                let a = Float(bitPattern: le32(destBytes, lane * 4))
                let b = Float(bitPattern: le32(src, lane * 4))
                putLE32(&result, lane * 4, floatOp(a, b).bitPattern)
            }
        case .ss:
            let a = Float(bitPattern: le32(destBytes, 0))
            let b = Float(bitPattern: le32(src, 0))
            putLE32(&result, 0, floatOp(a, b).bitPattern)
        case .pd:
            for lane in 0..<2 {
                let a = Double(bitPattern: le64(destBytes, lane * 8))
                let b = Double(bitPattern: le64(src, lane * 8))
                putLE64(&result, lane * 8, doubleOp(a, b).bitPattern)
            }
        case .sd:
            if opcode == 0x52 {   // RSQRTSS（F2 0F 52）: 単精度として計算する
                let b = Float(bitPattern: le32(src, 0))
                putLE32(&result, 0, (1 / sqrt(b)).bitPattern)
            } else {
                let a = Double(bitPattern: le64(destBytes, 0))
                let b = Double(bitPattern: le64(src, 0))
                putLE64(&result, 0, doubleOp(a, b).bitPattern)
            }
        }
        xmmRegisters[dest] = result
    }

    /// レーン単位のシフト（論理 / 算術、左右）。
    private func sseShiftLanes(_ bytes: [UInt8], laneSize: Int, count: Int, arithmetic: Bool, left: Bool) -> [UInt8] {
        var result = bytes
        let bits = laneSize * 8
        for i in 0..<(16 / laneSize) {
            var value: UInt64 = 0
            for k in 0..<laneSize { value |= UInt64(bytes[i * laneSize + k]) << (8 * k) }
            var shifted: UInt64
            if left {
                shifted = count >= bits ? 0 : value << count
            } else if arithmetic {
                let signed: Int64
                switch laneSize {
                case 2: signed = Int64(Int16(bitPattern: UInt16(value)))
                case 4: signed = Int64(Int32(bitPattern: UInt32(value)))
                default: signed = Int64(bitPattern: value)
                }
                shifted = count >= bits ? (signed < 0 ? UInt64.max : 0) : UInt64(bitPattern: signed >> count)
            } else {
                shifted = count >= bits ? 0 : value >> count
            }
            let laneMask: UInt64 = laneSize == 8 ? UInt64.max : (UInt64(1) << bits) - 1
            shifted &= laneMask
            for k in 0..<laneSize { result[i * laneSize + k] = UInt8((shifted >> (8 * k)) & 0xFF) }
        }
        return result
    }

    private func sseShiftImmediate(opcode: UInt8, subOperation: Int, bytes: [UInt8], count: Int) -> [UInt8] {
        switch opcode {
        case 0x71: // ワード
            switch subOperation {
            case 2: return sseShiftLanes(bytes, laneSize: 2, count: count, arithmetic: false, left: false)
            case 4: return sseShiftLanes(bytes, laneSize: 2, count: count, arithmetic: true, left: false)
            case 6: return sseShiftLanes(bytes, laneSize: 2, count: count, arithmetic: false, left: true)
            default: return bytes
            }
        case 0x72: // ダブルワード
            switch subOperation {
            case 2: return sseShiftLanes(bytes, laneSize: 4, count: count, arithmetic: false, left: false)
            case 4: return sseShiftLanes(bytes, laneSize: 4, count: count, arithmetic: true, left: false)
            case 6: return sseShiftLanes(bytes, laneSize: 4, count: count, arithmetic: false, left: true)
            default: return bytes
            }
        default: // 0x73: クワッドワード / レジスタ全体のバイトシフト
            switch subOperation {
            case 2: return sseShiftLanes(bytes, laneSize: 8, count: count, arithmetic: false, left: false)
            case 6: return sseShiftLanes(bytes, laneSize: 8, count: count, arithmetic: false, left: true)
            case 3: // PSRLDQ
                if count >= 16 { return [UInt8](repeating: 0, count: 16) }
                var result = [UInt8](repeating: 0, count: 16)
                for i in 0..<(16 - count) { result[i] = bytes[i + count] }
                return result
            case 7: // PSLLDQ
                if count >= 16 { return [UInt8](repeating: 0, count: 16) }
                var result = [UInt8](repeating: 0, count: 16)
                for i in count..<16 { result[i] = bytes[i - count] }
                return result
            default: return bytes
            }
        }
    }

    private func sseInteger(opcode: UInt8, dest: Int, src: [UInt8], address: UInt64) throws {
        var result = xmmRegisters[dest]
        let destBytes = xmmRegisters[dest]
        func lane(_ bytes: [UInt8], _ size: Int, _ index: Int) -> UInt64 {
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(bytes[index * size + k]) << (8 * k) }
            return value
        }
        func setLane(_ size: Int, _ index: Int, _ value: UInt64) {
            for k in 0..<size { result[index * size + k] = UInt8((value >> (8 * k)) & 0xFF) }
        }
        func signedLane(_ bytes: [UInt8], _ size: Int, _ index: Int) -> Int64 {
            let raw = lane(bytes, size, index)
            switch size {
            case 1: return Int64(Int8(bitPattern: UInt8(raw)))
            case 2: return Int64(Int16(bitPattern: UInt16(raw)))
            case 4: return Int64(Int32(bitPattern: UInt32(raw)))
            default: return Int64(bitPattern: raw)
            }
        }
        func addSub(size: Int, subtract: Bool, saturate: Int) {
            // saturate: 0 なし / 1 符号付き / 2 符号なし
            let bits = size * 8
            let signedMin = -(Int64(1) << (bits - 1))
            let signedMax = (Int64(1) << (bits - 1)) - 1
            let unsignedMax = size == 8 ? UInt64.max : (UInt64(1) << bits) - 1
            for i in 0..<(16 / size) {
                if saturate == 1 {
                    var value = signedLane(destBytes, size, i)
                    let other = signedLane(src, size, i)
                    value = subtract ? value - other : value + other
                    value = max(signedMin, min(signedMax, value))
                    setLane(size, i, UInt64(bitPattern: value))
                } else if saturate == 2 {
                    var value = Int64(lane(destBytes, size, i))
                    let other = Int64(lane(src, size, i))
                    value = subtract ? value - other : value + other
                    value = max(0, min(Int64(unsignedMax), value))
                    setLane(size, i, UInt64(value))
                } else if subtract {
                    setLane(size, i, lane(destBytes, size, i) &- lane(src, size, i))
                } else {
                    setLane(size, i, lane(destBytes, size, i) &+ lane(src, size, i))
                }
            }
        }
        switch opcode {
        case 0xFC: addSub(size: 1, subtract: false, saturate: 0)
        case 0xFD: addSub(size: 2, subtract: false, saturate: 0)
        case 0xFE: addSub(size: 4, subtract: false, saturate: 0)
        case 0xD4: addSub(size: 8, subtract: false, saturate: 0)
        case 0xF8: addSub(size: 1, subtract: true, saturate: 0)
        case 0xF9: addSub(size: 2, subtract: true, saturate: 0)
        case 0xFA: addSub(size: 4, subtract: true, saturate: 0)
        case 0xFB: addSub(size: 8, subtract: true, saturate: 0)
        case 0xEC: addSub(size: 1, subtract: false, saturate: 1)
        case 0xED: addSub(size: 2, subtract: false, saturate: 1)
        case 0xDC: addSub(size: 1, subtract: false, saturate: 2)
        case 0xDD: addSub(size: 2, subtract: false, saturate: 2)
        case 0xE8: addSub(size: 1, subtract: true, saturate: 1)
        case 0xE9: addSub(size: 2, subtract: true, saturate: 1)
        case 0xD8: addSub(size: 1, subtract: true, saturate: 2)
        case 0xD9: addSub(size: 2, subtract: true, saturate: 2)
        case 0x74, 0x75, 0x76: // PCMPEQ B / W / D
            let size = opcode == 0x74 ? 1 : (opcode == 0x75 ? 2 : 4)
            for i in 0..<(16 / size) {
                setLane(size, i, lane(destBytes, size, i) == lane(src, size, i) ? UInt64.max : 0)
            }
        case 0x64, 0x65, 0x66: // PCMPGT B / W / D
            let size = opcode == 0x64 ? 1 : (opcode == 0x65 ? 2 : 4)
            for i in 0..<(16 / size) {
                setLane(size, i, signedLane(destBytes, size, i) > signedLane(src, size, i) ? UInt64.max : 0)
            }
        case 0xDA: // PMINUB
            for i in 0..<16 { result[i] = min(destBytes[i], src[i]) }
        case 0xDE: // PMAXUB
            for i in 0..<16 { result[i] = max(destBytes[i], src[i]) }
        case 0xEA: // PMINSW
            for i in 0..<8 { setLane(2, i, UInt64(bitPattern: min(signedLane(destBytes, 2, i), signedLane(src, 2, i)))) }
        case 0xEE: // PMAXSW
            for i in 0..<8 { setLane(2, i, UInt64(bitPattern: max(signedLane(destBytes, 2, i), signedLane(src, 2, i)))) }
        case 0xE0: // PAVGB
            for i in 0..<16 { result[i] = UInt8((Int(destBytes[i]) + Int(src[i]) + 1) >> 1) }
        case 0xE3: // PAVGW
            for i in 0..<8 { setLane(2, i, UInt64((lane(destBytes, 2, i) + lane(src, 2, i) + 1) >> 1)) }
        case 0xD5: // PMULLW
            for i in 0..<8 { setLane(2, i, lane(destBytes, 2, i) &* lane(src, 2, i)) }
        case 0xE5: // PMULHW
            for i in 0..<8 { setLane(2, i, UInt64(bitPattern: (signedLane(destBytes, 2, i) * signedLane(src, 2, i)) >> 16)) }
        case 0xE4: // PMULHUW
            for i in 0..<8 { setLane(2, i, (lane(destBytes, 2, i) * lane(src, 2, i)) >> 16) }
        case 0xF4: // PMULUDQ
            for i in 0..<2 {
                let a = lane(destBytes, 4, i * 2), b = lane(src, 4, i * 2)
                setLane(8, i, a &* b)
            }
        case 0xF5: // PMADDWD
            for i in 0..<4 {
                let value = signedLane(destBytes, 2, i * 2) * signedLane(src, 2, i * 2)
                    + signedLane(destBytes, 2, i * 2 + 1) * signedLane(src, 2, i * 2 + 1)
                setLane(4, i, UInt64(bitPattern: value))
            }
        case 0xF6: // PSADBW
            for half in 0..<2 {
                var sum: UInt64 = 0
                for i in 0..<8 {
                    let a = Int(destBytes[half * 8 + i]), b = Int(src[half * 8 + i])
                    sum += UInt64(abs(a - b))
                }
                setLane(8, half, sum)
            }
        case 0xDB: for i in 0..<16 { result[i] = destBytes[i] & src[i] } // PAND
        case 0xDF: for i in 0..<16 { result[i] = ~destBytes[i] & src[i] } // PANDN
        case 0xEB: for i in 0..<16 { result[i] = destBytes[i] | src[i] } // POR
        case 0xEF: for i in 0..<16 { result[i] = destBytes[i] ^ src[i] } // PXOR
        case 0x63: // PACKSSWB
            for i in 0..<8 {
                let a = max(Int64(-128), min(Int64(127), signedLane(destBytes, 2, i)))
                let b = max(Int64(-128), min(Int64(127), signedLane(src, 2, i)))
                result[i] = UInt8(bitPattern: Int8(a))
                result[8 + i] = UInt8(bitPattern: Int8(b))
            }
        case 0x6B: // PACKSSDW
            for i in 0..<4 {
                let a = max(Int64(-32768), min(Int64(32767), signedLane(destBytes, 4, i)))
                let b = max(Int64(-32768), min(Int64(32767), signedLane(src, 4, i)))
                setLane(2, i, UInt64(bitPattern: a))
                setLane(2, 4 + i, UInt64(bitPattern: b))
            }
        case 0x67: // PACKUSWB
            for i in 0..<8 {
                let a = max(Int64(0), min(Int64(255), signedLane(destBytes, 2, i)))
                let b = max(Int64(0), min(Int64(255), signedLane(src, 2, i)))
                result[i] = UInt8(a)
                result[8 + i] = UInt8(b)
            }
        case 0x60, 0x61, 0x62, 0x68, 0x69, 0x6A: // PUNPCKL / H BW・WD・DQ
            let size = opcode == 0x60 || opcode == 0x68 ? 1 : (opcode == 0x61 || opcode == 0x69 ? 2 : 4)
            let high = opcode >= 0x68
            let count = 16 / size
            let start = high ? count / 2 : 0
            for i in 0..<(count / 2) {
                setLane(size, i * 2, lane(destBytes, size, start + i))
                setLane(size, i * 2 + 1, lane(src, size, start + i))
            }
        case 0x6C: // PUNPCKLQDQ
            setLane(8, 0, lane(destBytes, 8, 0)); setLane(8, 1, lane(src, 8, 0))
        case 0x6D: // PUNPCKHQDQ
            setLane(8, 0, lane(destBytes, 8, 1)); setLane(8, 1, lane(src, 8, 1))
        case 0xD1, 0xD2, 0xD3, 0xE1, 0xE2, 0xF1, 0xF2, 0xF3: // シフト（レジスタ指定）
            let count = Int(lane(src, 8, 0))
            switch opcode {
            case 0xD1: result = sseShiftLanes(destBytes, laneSize: 2, count: count, arithmetic: false, left: false)
            case 0xD2: result = sseShiftLanes(destBytes, laneSize: 4, count: count, arithmetic: false, left: false)
            case 0xD3: result = sseShiftLanes(destBytes, laneSize: 8, count: count, arithmetic: false, left: false)
            case 0xE1: result = sseShiftLanes(destBytes, laneSize: 2, count: count, arithmetic: true, left: false)
            case 0xE2: result = sseShiftLanes(destBytes, laneSize: 4, count: count, arithmetic: true, left: false)
            case 0xF1: result = sseShiftLanes(destBytes, laneSize: 2, count: count, arithmetic: false, left: true)
            case 0xF2: result = sseShiftLanes(destBytes, laneSize: 4, count: count, arithmetic: false, left: true)
            default: result = sseShiftLanes(destBytes, laneSize: 8, count: count, arithmetic: false, left: true)
            }
        default:
            throw opcodeFault(opcode, address: address)
        }
        xmmRegisters[dest] = result
    }

    private func executeSSEGroupAE(address: UInt64) throws {
        let modRM = try decodeModRM()
        switch modRM.reg {
        case 0:
            guard !modRM.isRegister else { throw opcodeFault(0xAE, address: address) }
            try checkTSForFPU(opcode: 0xAE, address: address)
            try fxsave(modRM)
        case 1:
            guard !modRM.isRegister else { throw opcodeFault(0xAE, address: address) }
            try checkTSForFPU(opcode: 0xAE, address: address)
            try fxrstor(modRM)
        case 2:
            try checkTSForFPU(opcode: 0xAE, address: address)
            mxcsr = UInt32(try readOperand(modRM, size: 4)) // LDMXCSR
        case 3:
            try checkTSForFPU(opcode: 0xAE, address: address)
            try writeOperand(modRM, size: 4, UInt64(mxcsr)) // STMXCSR
        case 4 where !modRM.isRegister: // XSAVE
            try checkTSForFPU(opcode: 0xAE, address: address)
            try xsave(modRM)
        case 5 where !modRM.isRegister: // XRSTOR
            try checkTSForFPU(opcode: 0xAE, address: address)
            try xrstor(modRM)
        case 6 where !modRM.isRegister: // XSAVEOPT（XSAVE と同じ扱い）
            try checkTSForFPU(opcode: 0xAE, address: address)
            try xsave(modRM)
        case 7 where !modRM.isRegister: break // CLFLUSH（NOP 扱い）
        case 5, 6, 7: break // LFENCE / MFENCE / SFENCE（NOP 扱い）
        default: throw opcodeFault(0xAE, address: address)
        }
    }

    private func checkTSForFPU(opcode: UInt8, address: UInt64) throws {
        if controlRegisters[0] & 0x8 != 0 { throw CPUTrap.exception(vector: 7, errorCode: nil) } // CR0.TS → #NM
    }

    private func xsave(_ operand: ModRM) throws {
        let requested = (registers[2] << 32) | (registers[0] & 0xFFFFFFFF)
        var area = fxsaveArea()
        area += [UInt8](repeating: 0, count: 64)
        putLE64(&area, 512, requested & xcr0 & 0x3) // XSTATE_BV（x87 / SSE のみ対応）
        try writeOperandBytes(operand, area)
    }

    private func xrstor(_ operand: ModRM) throws {
        let area = try readOperandBytes(operand, count: 576)
        let stateBits = le64(area, 512)
        guard stateBits & ~xcr0 == 0 else { throw CPUTrap.exception(vector: 13, errorCode: 0) }
        fxrstorArea(Array(area[0..<512]), loadX87: stateBits & 1 != 0, loadSSE: stateBits & 2 != 0)
    }

    private func fxsave(_ operand: ModRM) throws {
        try writeOperandBytes(operand, fxsaveArea())
    }

    private func fxsaveArea() -> [UInt8] {
        var area = [UInt8](repeating: 0, count: 512)
        area[0] = UInt8(fpuControlWord & 0xFF)
        area[1] = UInt8(fpuControlWord >> 8)
        area[2] = UInt8(fpuStatusWord & 0xFF)
        area[3] = UInt8(fpuStatusWord >> 8)
        var tag: UInt8 = 0
        for i in 0..<8 where fpuValid[i] { tag |= UInt8(1 << i) }
        area[4] = tag
        putLE32(&area, 24, mxcsr)
        putLE32(&area, 28, 0x0000FFFF)
        for i in 0..<8 {
            let extended = storeExtended(fpuRegisters[i])
            for k in 0..<10 { area[32 + i * 16 + k] = extended[k] }
        }
        for i in 0..<16 {
            for k in 0..<16 { area[160 + i * 16 + k] = xmmRegisters[i][k] }
        }
        return area
    }

    private func fxrstor(_ operand: ModRM) throws {
        let area = try readOperandBytes(operand, count: 512)
        fxrstorArea(area, loadX87: true, loadSSE: true)
    }

    private func fxrstorArea(_ area: [UInt8], loadX87: Bool, loadSSE: Bool) {
        if loadX87 {
            fpuControlWord = UInt16(area[0]) | UInt16(area[1]) << 8
            let status = UInt16(area[2]) | UInt16(area[3]) << 8
            fpuTop = Int((status >> 11) & 7)
            fpuConditionCodes = (status & 0x0100 != 0, status & 0x0200 != 0, status & 0x0400 != 0, status & 0x4000 != 0)
            let tag = area[4]
            for i in 0..<8 {
                fpuValid[i] = tag & UInt8(1 << i) != 0
                fpuRegisters[i] = loadExtended(Array(area[(32 + i * 16)..<(32 + i * 16 + 10)]))
            }
        }
        if loadSSE {
            mxcsr = le32(area, 24)
            for i in 0..<16 {
                xmmRegisters[i] = Array(area[(160 + i * 16)..<(160 + i * 16 + 16)])
            }
        }
    }

    /// VGA モード 13h（チェーン 4）のフレームを BGRA バイト列で返す。
    /// BIOS でモード 13h が設定されたか、レジスタ状態からチェーン 4
    /// グラフィックスと判断できる場合のみ非 nil。
    func vgaMode13hFrame() -> (width: Int, height: Int, bgra: [UInt8])? {
        guard devices.biosVideoMode == 0x13 || devices.vgaChain4Graphics else { return nil }
        let palette = devices.vgaPalette
        var bgra = [UInt8](repeating: 0, count: 320 * 200 * 4)
        for pixel in 0..<(320 * 200) {
            let index = Int((try? readMemory8(at: 0xA0000 + pixel)) ?? 0)
            let red = palette[index * 3], green = palette[index * 3 + 1], blue = palette[index * 3 + 2]
            bgra[pixel * 4] = (blue << 2) | (blue >> 4)
            bgra[pixel * 4 + 1] = (green << 2) | (green >> 4)
            bgra[pixel * 4 + 2] = (red << 2) | (red >> 4)
            bgra[pixel * 4 + 3] = 0xFF
        }
        return (320, 200, bgra)
    }

    // MARK: - ポート I/O（デバイスバスへ委譲）

    private func portIn(_ port: UInt16, size: Int) -> UInt32 {
        devices.readPort(port, size: size)
    }

    private func portOut(_ port: UInt16, value: UInt32, size: Int) {
        devices.writePort(port, value: value, size: size)
    }
}
