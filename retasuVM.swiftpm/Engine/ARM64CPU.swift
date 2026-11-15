import Foundation

enum ARM64Fault: Error, CustomStringConvertible, LocalizedError {
    case memoryOutOfBounds(address: UInt64)
    case invalidELF(String)

    var description: String {
        switch self {
        case .memoryOutOfBounds(let address):
            return String(format: "ARM64: メモリ範囲外アクセス（アドレス 0x%llX）", address)
        case .invalidELF(let detail):
            return "ARM64: ELF64 の読み込みに失敗しました（\(detail)）"
        }
    }
    var errorDescription: String? { description }
}

/// AArch64（ARM64）ソフトウェア CPU。
///
/// Henge（iPhone / iPad で macOS を動かすエミュレータ）と同じく、
/// Apple Silicon Mac をソフトウェアで再現する方向の基盤として実装した
/// インタプリタ型コア。EL0 / EL1、ステージ 1 MMU（4 KB グラニュール、
/// TTBR0 / TTBR1）、例外ベクタ（VBAR_EL1）、ARM ジェネリックタイマと
/// 簡易割り込みコントローラ（GIC ライト）、PL011 風 UART を備える。
///
/// プラットフォーム（retasuVM ARM64 マシン）:
/// - RAM: 0x4000_0000 から `memorySize` バイト
/// - UART (PL011 ライト): 0x0900_0000
/// - 割り込みコントローラ (GIC ライト): 配布側 0x0800_0000 / CPU 側 0x0801_0000
/// - 制御レジスタ: 0x0A00_0000（書き込みで終了コード付き停止）
///
/// SVC は retasuVM 共通のコンソールサービス（1=putchar, 2=print int,
/// 3=print string, 4=getchar, 5=clear, 6=random, 10=exit）として扱い、
/// それ以外の SVC は EL1 への同期例外として配送する。
/// SIMD / FP、CRC、ポインタ認証（HINT 形式は NOP として処理）は未実装。
final class ARM64CPU {
    // MARK: - プラットフォーム定数

    static let ramBase: UInt64 = 0x4000_0000
    static let uartBase: UInt64 = 0x0900_0000
    static let gicDistBase: UInt64 = 0x0800_0000
    static let gicCPUBase: UInt64 = 0x0801_0000
    static let controlBase: UInt64 = 0x0A00_0000
    static let aicBase: UInt64 = 0x0B00_0000
    static let nvmeBase: UInt64 = 0x0C00_0000
    static let timerINTID: UInt64 = 30
    static let uartINTID: UInt64 = 33
    /// Apple Silicon プラットフォームでの AIC 割り込み番号（自プラットフォームの ADT で定義）
    static let aicUARTIRQ = 1
    static let aicNVMeIRQ = 2

    /// 割り込み配送方式。gic = デモプラットフォーム（GIC ライト + IRQ）、
    /// appleSilicon = Mac プラットフォーム（AIC + タイマを FIQ で配送）。
    enum Platform {
        case gic
        case appleSilicon
    }
    var platform: Platform = .gic

    // MARK: - 状態

    var registers = [UInt64](repeating: 0, count: 31)   // X0...X30
    private(set) var pc: UInt64 = 0
    var spEL0: UInt64 = 0
    var spEL1: UInt64 = 0
    /// PSTATE（SPSR 形式: NZCV[31:28] / DAIF[9:6] / EL[3:2] / SPSel[0]）
    var pstate: UInt32 = 0x3C5                            // EL1h, 全割り込みマスク
    private(set) var halted = false
    private(set) var exitCode: Int32 = 0
    private(set) var waitingForInput = false
    /// WFI でアイドル中（割り込み待ち）
    private(set) var idle = false

    var memory: [UInt8]
    let memorySize: Int

    // システムレジスタ（EL1）
    var sctlrEL1: UInt64 = 0
    var tcrEL1: UInt64 = 0
    var ttbr0EL1: UInt64 = 0
    var ttbr1EL1: UInt64 = 0
    var mairEL1: UInt64 = 0
    var vbarEL1: UInt64 = 0
    var elrEL1: UInt64 = 0
    var spsrEL1: UInt32 = 0
    var esrEL1: UInt64 = 0
    var farEL1: UInt64 = 0

    // ジェネリックタイマ（物理カウンタ）
    private let timerFrequency: UInt64 = 62_500_000
    private var timerEpoch = Date()
    private var cntpCval: UInt64 = UInt64.max
    private var cntpCtl: UInt64 = 0                       // bit0 ENABLE, bit1 IMASK

    // 割り込みコントローラ（GIC ライト）
    private var gicDistEnabled = false
    private var gicEnabledINTIDs: UInt64 = 0              // INTID 0...63 の有効ビット
    private var gicCPUEnabled = false
    private var gicPriorityMask: UInt64 = 0xFF
    private var timerAcked = false                        // IAR で応答済み（EOI まで再通知しない）

    // Apple Interrupt Controller（AIC v1 ライト、Mac プラットフォーム用）
    static let aicIRQCount = 256
    private var aicMask = [Bool](repeating: true, count: aicIRQCount)     // true = マスク中
    private var aicTarget = [UInt32](repeating: 0, count: aicIRQCount)    // 対象 CPU ビットマップ
    private var aicSW = [Bool](repeating: false, count: aicIRQCount)      // ソフトウェア生成状態
    private var aicIPIotherPending = false
    private var aicIPIselfPending = false
    private var aicIPIotherMasked = true
    private var aicIPIselfMasked = true
    private var nvmeIRQLine = false                                       // NVMe 完了割り込みライン（AIC IRQ 2）

    /// NVMe コントローラ（Mac プラットフォーム用）。RAM アクセスは初回アクセス時に結線する。
    let nvme = ARM64NVMe()
    private var nvmeWired = false

    // 入力キューと排他モニタ
    private var inputQueue: [UInt8] = []
    private let inputLock = NSLock()
    private var exclusiveAddress: UInt64? = nil

    private var randomState: UInt32 = 0x12345678

    var onChar: ((UInt8) -> Void)?
    var onClearScreen: (() -> Void)?

    init(memorySize: Int = 64 * 1024 * 1024) {
        self.memorySize = memorySize
        self.memory = [UInt8](repeating: 0, count: memorySize)
    }

    // MARK: - PSTATE ヘルパ

    var currentEL: Int { Int((pstate >> 2) & 0x3) }
    private var spSel: Bool { pstate & 0x1 != 0 }
    private var irqMasked: Bool { pstate & (1 << 7) != 0 }
    private var fiqMasked: Bool { pstate & (1 << 6) != 0 }

    private var flagN: Bool { pstate & (1 << 31) != 0 }
    private var flagZ: Bool { pstate & (1 << 30) != 0 }
    private var flagC: Bool { pstate & (1 << 29) != 0 }
    private var flagV: Bool { pstate & (1 << 28) != 0 }

    private func setNZCV(n: Bool, z: Bool, c: Bool, v: Bool) {
        var value = pstate & 0x0FFF_FFFF
        if n { value |= 1 << 31 }
        if z { value |= 1 << 30 }
        if c { value |= 1 << 29 }
        if v { value |= 1 << 28 }
        pstate = value
    }

    private func applyFlags(_ r: (result: UInt64, n: Bool, z: Bool, c: Bool, v: Bool)) {
        setNZCV(n: r.n, z: r.z, c: r.c, v: r.v)
    }

    /// 現在のスタックポインタ（EL と SPSel で選択）。
    var currentSP: UInt64 {
        get {
            if currentEL == 0 { return spEL0 }
            return spSel ? spEL1 : spEL0
        }
        set {
            if currentEL == 0 { spEL0 = newValue }
            else if spSel { spEL1 = newValue } else { spEL0 = newValue }
        }
    }

    // MARK: - レジスタアクセス

    private func readReg(_ index: Int, sp: Bool = false) -> UInt64 {
        if index == 31 { return sp ? currentSP : 0 }
        return registers[index]
    }

    private func writeReg(_ index: Int, _ value: UInt64, sp: Bool = false, width64: Bool = true) {
        if index == 31 {
            if sp { currentSP = value }
            return
        }
        registers[index] = width64 ? value : (value & 0xFFFF_FFFF)
    }

    // MARK: - ロード / 実行

    /// フラットバイナリを RAM へ読み込み、実行開始アドレスを設定する。
    func loadProgram(_ bytes: [UInt8], at address: UInt64) {
        let offset = Int(address - Self.ramBase)
        guard offset >= 0, offset + bytes.count <= memory.count else { return }
        memory.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        pc = address
        spEL1 = Self.ramBase + UInt64(memorySize) - 0x1000
        spEL0 = spEL1 - 0x10000
    }

    /// ELF64（AArch64）を読み込み、エントリポイントを返す。
    @discardableResult
    func loadELF64(_ data: [UInt8]) throws -> UInt64 {
        guard data.count >= 64, data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 else {
            throw ARM64Fault.invalidELF("ELF マジックがありません")
        }
        guard data[4] == 2, data[5] == 1 else { throw ARM64Fault.invalidELF("64 ビット / リトルエンディアンではありません") }
        func u16(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 }
        func u32(_ off: Int) -> UInt64 { UInt64(data[off]) | UInt64(data[off + 1]) << 8 | UInt64(data[off + 2]) << 16 | UInt64(data[off + 3]) << 24 }
        func u64(_ off: Int) -> UInt64 { u32(off) | u32(off + 4) << 32 }
        guard u16(18) == 183 else { throw ARM64Fault.invalidELF("AArch64 ではありません") }
        let entry = u64(24)
        let phoff = Int(u64(32))
        let phentsize = u16(54)
        let phnum = u16(56)
        for i in 0..<phnum {
            let base = phoff + i * phentsize
            guard base + 56 <= data.count else { throw ARM64Fault.invalidELF("プログラムヘッダが範囲外です") }
            guard u32(base) == 1 else { continue }        // PT_LOAD
            let fileOff = Int(u64(base + 8))
            let vaddr = u64(base + 16)
            let fileSize = Int(u64(base + 32))
            let memSize = Int(u64(base + 40))
            let dest = Int(vaddr - Self.ramBase)
            guard dest >= 0, dest + memSize <= memory.count, fileOff + fileSize <= data.count else {
                throw ARM64Fault.invalidELF("セグメントが RAM の範囲外です")
            }
            for j in 0..<memSize {
                memory[dest + j] = j < fileSize ? data[fileOff + j] : 0
            }
        }
        pc = entry
        spEL1 = Self.ramBase + UInt64(memorySize) - 0x1000
        spEL0 = spEL1 - 0x10000
        return entry
    }

    /// ブート時の X0 を設定する（Mac ブートでは ADT のアドレスを渡す）。
    /// PC とスタックは loadProgram / loadELF64 が設定済みの前提。
    func setBootArgument(_ value: UInt64) {
        registers[0] = value
    }

    /// NVMe ディスクイメージを取り付ける（512 バイトセクタ単位に切り捨て）。
    func attachNVMeDisk(_ data: [UInt8]) {
        nvme.attachDisk(data)
    }

    func setRandomSeed(_ seed: UInt32) {
        randomState = seed == 0 ? 0x12345678 : seed
    }

    func enqueueInput(_ text: String) {
        inputLock.lock()
        inputQueue.append(contentsOf: text.utf8)
        inputLock.unlock()
        waitingForInput = false
        idle = false
    }

    // MARK: - 実行ループ

    func run(maxInstructions: Int) throws {
        var count = 0
        while !halted && !waitingForInput && count < maxInstructions {
            if idle {
                // WFI 中: 割り込みが来たら復帰し、来ていなければ呼び出しを返す
                if platform == .appleSilicon {
                    if fiqPending && !fiqMasked { idle = false } else { break }
                } else if interruptPending && !irqMasked { idle = false } else { break }
            }
            try step()
            count += 1
        }
    }

    /// 割り込みの保留状態（タイマ期限切れ / UART 受信）。
    private var interruptPending: Bool {
        if timerExpired && (cntpCtl & 0x2) == 0 && !timerAcked { return true }
        if !inputQueueEmpty && gicEnabled(Self.uartINTID) { return true }
        return false
    }

    private var inputQueueEmpty: Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        return inputQueue.isEmpty
    }

    private var timerExpired: Bool {
        (cntpCtl & 0x1) != 0 && counterValue() >= cntpCval
    }

    private func counterValue() -> UInt64 {
        let elapsed = Date().timeIntervalSince(timerEpoch)
        return UInt64(elapsed * Double(timerFrequency))
    }

    private func gicEnabled(_ intid: UInt64) -> Bool {
        gicDistEnabled && gicCPUEnabled && (gicEnabledINTIDs >> intid) & 1 == 1 && gicPriorityMask != 0
    }

    // MARK: - ステップ実行

    private func step() throws {
        // 割り込みは命令境界で受け付ける（ELR は次に実行する命令を指す）
        if platform == .appleSilicon {
            if fiqPending && !fiqMasked {
                enterException(vectorOffset: fiqVectorOffset(), elr: pc, esr: 0)
            }
        } else if interruptPending && !irqMasked {
            enterException(vectorOffset: irqVectorOffset(), elr: pc, esr: 0)
        }
        let instructionPC = pc
        do {
            let insn = try fetch32(at: instructionPC)
            pc = instructionPC &+ 4
            try execute(insn, at: instructionPC)
        } catch let abort as AbortSignal {
            // データ / 命令アボートは例外として配送する（セッションは継続）
            farEL1 = abort.address
            let fromLower = currentEL == 0
            let ec: UInt64 = abort.isInstruction ? (fromLower ? 0x20 : 0x21) : (fromLower ? 0x24 : 0x25)
            esrEL1 = (ec << 26) | abort.fsc
            elrEL1 = abort.isInstruction ? instructionPC : instructionPC
            spsrEL1 = pstate
            enterEL1(vectorOffset: syncVectorOffset())
        }
    }

    /// 命令アボート / データアボートの内部シグナル。
    private struct AbortSignal: Error {
        var address: UInt64
        var isInstruction: Bool
        var fsc: UInt64    // フォルトステータスコード（レベル含む下位 6 ビット）
    }

    private func syncVectorOffset() -> UInt64 {
        if currentEL == 0 { return 0x400 }
        return spSel ? 0x200 : 0x000
    }

    private func irqVectorOffset() -> UInt64 {
        if currentEL == 0 { return 0x480 }
        return spSel ? 0x280 : 0x080
    }

    private func fiqVectorOffset() -> UInt64 {
        if currentEL == 0 { return 0x500 }
        return spSel ? 0x300 : 0x100
    }

    // MARK: - Apple Silicon プラットフォーム（AIC / FIQ）

    /// FIQ 保留: ジェネリックタイマ期限切れ（IMASK でマスク可）または AIC イベント。
    private var fiqPending: Bool {
        if timerExpired && (cntpCtl & 0x2) == 0 { return true }
        return aicEventPending
    }

    /// AIC に CPU0 向けの未配送イベントがあるか。
    private var aicEventPending: Bool {
        if !aicIPIselfMasked && aicIPIselfPending { return true }
        if !aicIPIotherMasked && aicIPIotherPending { return true }
        for irq in 0..<Self.aicIRQCount {
            if !aicMask[irq] && (aicTarget[irq] & 1) != 0 && aicIRQAsserted(irq) { return true }
        }
        return false
    }

    /// ハードウェア割り込みライン（またはソフトウェア生成）の状態。
    private func aicIRQAsserted(_ irq: Int) -> Bool {
        if aicSW[irq] { return true }
        switch irq {
        case Self.aicUARTIRQ: return !inputQueueEmpty
        case Self.aicNVMeIRQ: return nvmeIRQLine
        default: return false
        }
    }

    /// AIC_EVENT の読み取り: 最優先イベントを返し、その IRQ を自動マスクする。
    /// ハードウェア割り込み（タイプ 1）を IPI（タイプ 4）より先に配送する。
    private func aicReadEvent() -> UInt64 {
        for irq in 0..<Self.aicIRQCount {
            if !aicMask[irq] && (aicTarget[irq] & 1) != 0 && aicIRQAsserted(irq) {
                aicMask[irq] = true            // 配送時の自動マスク（実機と同じ）
                aicSW[irq] = false
                if irq == Self.aicNVMeIRQ { nvmeIRQLine = false }
                return (1 << 16) | UInt64(irq)
            }
        }
        if !aicIPIotherMasked && aicIPIotherPending { return (4 << 16) | 1 }
        if !aicIPIselfMasked && aicIPIselfPending { return (4 << 16) | 2 }
        return 0
    }

    private func aicRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x0004: return UInt64(Self.aicIRQCount)              // INFO: NR_IRQ
        case 0x2000: return 0                                     // WHOAMI: CPU 0
        case 0x2004: return aicReadEvent()                        // EVENT
        case 0x2024, 0x2028:                                      // IPI マスク状態
            return (aicIPIotherMasked ? UInt64(1) : 0) | (aicIPIselfMasked ? UInt64(1) << 31 : 0)
        default:
            if offset >= 0x3000 && offset < 0x3000 + UInt64(Self.aicIRQCount) * 4 {
                return UInt64(aicTarget[Int((offset - 0x3000) / 4)])
            }
            if offset >= 0x4000 && offset < 0x4280 {
                // バンク領域: 0=SW_SET 1=SW_CLR 2=MASK_SET 3=MASK_CLR 4=HW_STATE（128 バイトごと）
                let region = (offset - 0x4000) >> 7
                let bank = Int((offset & 0x7F) / 4)
                var bits: UInt32 = 0
                for i in 0..<32 {
                    let irq = bank * 32 + i
                    if irq >= Self.aicIRQCount { break }
                    let on: Bool
                    switch region {
                    case 0, 1: on = aicSW[irq]
                    case 2, 3: on = aicMask[irq]
                    case 4: on = aicIRQAsserted(irq)
                    default: on = false
                    }
                    if on { bits |= UInt32(1) << i }
                }
                return UInt64(bits)
            }
            return 0
        }
    }

    private func aicWrite(offset: UInt64, value: UInt64) {
        let v = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x2008:  // IPI_SEND: bit31 = 自分宛て、その他ビット = 対象 CPU（0 のみ存在）
            if v & (1 << 31) != 0 { aicIPIselfPending = true }
            if v & 1 != 0 { aicIPIotherPending = true }
        case 0x200C:  // IPI_ACK
            if v & 1 != 0 { aicIPIotherPending = false }
            if v & (1 << 31) != 0 { aicIPIselfPending = false }
        case 0x2024:  // IPI_MASK_SET
            if v & 1 != 0 { aicIPIotherMasked = true }
            if v & (1 << 31) != 0 { aicIPIselfMasked = true }
        case 0x2028:  // IPI_MASK_CLR
            if v & 1 != 0 { aicIPIotherMasked = false }
            if v & (1 << 31) != 0 { aicIPIselfMasked = false }
        default:
            if offset >= 0x3000 && offset < 0x3000 + UInt64(Self.aicIRQCount) * 4 {
                aicTarget[Int((offset - 0x3000) / 4)] = v
                return
            }
            if offset >= 0x4000 && offset < 0x4280 {
                // バンク領域: 0=SW_SET 1=SW_CLR 2=MASK_SET 3=MASK_CLR 4=HW_STATE（書込無効）
                let region = (offset - 0x4000) >> 7
                let bank = Int((offset & 0x7F) / 4)
                for i in 0..<32 {
                    let irq = bank * 32 + i
                    if irq >= Self.aicIRQCount { break }
                    if v & (UInt32(1) << i) == 0 { continue }
                    switch region {
                    case 0: aicSW[irq] = true
                    case 1: aicSW[irq] = false
                    case 2: aicMask[irq] = true
                    case 3: aicMask[irq] = false
                    default: break
                    }
                }
            }
        }
    }

    /// 例外を EL1 へ配送する（ELR / ESR を設定し、SPSR へ現在の PSTATE を退避）。
    private func enterException(vectorOffset: UInt64, elr: UInt64, esr: UInt64) {
        esrEL1 = esr
        elrEL1 = elr
        spsrEL1 = pstate
        enterEL1(vectorOffset: vectorOffset)
    }

    /// 同期例外（SVC / 未定義命令など）。ELR は呼び出し側で決める。
    private func raiseSync(ec: UInt64, iss: UInt64, elr: UInt64) {
        enterException(vectorOffset: syncVectorOffset(), elr: elr, esr: (ec << 26) | (iss & 0x1FF_FFFF))
    }

    private func enterEL1(vectorOffset: UInt64) {
        // 例外突入: EL1 / SP_EL1 を使い、割り込みをマスクする
        var newState = pstate
        newState = (newState & 0xFFFF_FF00) | 0x3C0 | 0x05   // DAIF=1111, EL=1, SPSel=1
        pstate = newState
        pc = (vbarEL1 & ~0x7FF) &+ vectorOffset
    }

    private func eret() {
        pc = elrEL1
        pstate = spsrEL1
    }

    // MARK: - メモリアクセス（MMU + 物理）

    private func fetch32(at address: UInt64) throws -> UInt32 {
        let physical = try translate(address: address, isWrite: false, isFetch: true)
        return try readPhysical32(physical)
    }

    /// ステージ 1 変換（4 KB グラニュール、TTBR0 / TTBR1）。
    /// MMU 無効時は恒等変換。失敗時は AbortSignal を投げる。
    private func translate(address: UInt64, isWrite: Bool, isFetch: Bool) throws -> UInt64 {
        guard sctlrEL1 & 0x1 != 0 else { return address }
        let t0sz = Int(tcrEL1 & 0x3F)
        let t1sz = Int((tcrEL1 >> 16) & 0x3F)
        // TTBR1 領域: VA の上位ビットが（TTBR1 の VA サイズより上が）すべて 1
        var useTTBR1 = false
        if t1sz > 0 {
            let vaBits1 = 64 - t1sz
            if vaBits1 < 64 && (address >> vaBits1) == (UInt64.max >> vaBits1) {
                useTTBR1 = true
            }
        }
        let vaBits = 64 - (useTTBR1 ? t1sz : t0sz)
        guard vaBits >= 25, vaBits <= 48 else {
            throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b000100)
        }
        // VA の範囲検査（TTBR0 側は上位ビットが 0、TTBR1 側は 1 でなければならない）
        if useTTBR1 {
            guard address >> vaBits == (UInt64.max >> vaBits) else {
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b000100)
            }
        } else {
            guard address >> vaBits == 0 else {
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b000100)
            }
        }
        var tableBase = (useTTBR1 ? ttbr1EL1 : ttbr0EL1) & 0x0000_FFFF_FFFF_F000
        let levels = (vaBits - 12 + 8) / 9          // 4 KB グラニュールでの段数
        var level = 4 - levels
        var pa: UInt64 = 0
        walk: while true {
            let indexShift = 12 + (3 - level) * 9
            let index = Int((address >> indexShift) & 0x1FF)
            let descAddress = tableBase &+ UInt64(index * 8)
            let desc = try readTableEntry(descAddress)
            let kind = desc & 0x3
            if kind == 0 || kind == 2 {
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b000100 | UInt64(level))
            }
            if kind == 1 {
                // ブロック記述子（レベル 1 / 2 のみ）
                guard level == 1 || level == 2 else {
                    throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b000100 | UInt64(level))
                }
                try checkPermissions(desc: desc, isWrite: isWrite, isFetch: isFetch, level: level, address: address)
                let blockBits = (3 - level) * 9
                pa = (desc & 0x0000_FFFF_FFFF_F000 & ~((UInt64(1) << (12 + blockBits)) - 1)) | (address & ((UInt64(1) << (12 + blockBits)) - 1))
                break walk
            }
            // テーブル記述子 or ページ記述子
            if level == 3 {
                try checkPermissions(desc: desc, isWrite: isWrite, isFetch: isFetch, level: level, address: address)
                pa = (desc & 0x0000_FFFF_FFFF_F000) | (address & 0xFFF)
                break walk
            }
            tableBase = desc & 0x0000_FFFF_FFFF_F000
            level += 1
        }
        return pa
    }

    private func checkPermissions(desc: UInt64, isWrite: Bool, isFetch: Bool, level: Int, address: UInt64) throws {
        // アクセスフラグ（bit 10）が立っていなければアクセスフラグフォールト
        if desc & (1 << 10) == 0 {
            throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b001000 | UInt64(level))
        }
        let el0Access = desc & (1 << 6) != 0          // AP[1]
        let readOnly = desc & (1 << 7) != 0           // AP[2]
        if currentEL == 0 {
            if !el0Access {
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b001100 | UInt64(level))
            }
            if isWrite && readOnly {
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b001100 | UInt64(level))
            }
            if isFetch && desc & (1 << 54) != 0 {     // UXN
                throw AbortSignal(address: address, isInstruction: true, fsc: 0b001100 | UInt64(level))
            }
        } else {
            if isWrite && readOnly {
                // EL1 からの書き込み: AP[2] = 1（AP 0b10 / 0b11）は読み取り専用
                throw AbortSignal(address: address, isInstruction: isFetch, fsc: 0b001100 | UInt64(level))
            }
            if isFetch && desc & (1 << 53) != 0 {     // PXN
                throw AbortSignal(address: address, isInstruction: true, fsc: 0b001100 | UInt64(level))
            }
        }
    }

    private func readTableEntry(_ address: UInt64) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(try readPhysicalByte(address &+ UInt64(i))) << (8 * i)
        }
        return value
    }

    // MARK: 物理メモリ / MMIO

    private func readPhysicalByte(_ pa: UInt64) throws -> UInt8 {
        if pa >= Self.ramBase && pa < Self.ramBase + UInt64(memorySize) {
            return memory[Int(pa - Self.ramBase)]
        }
        return UInt8(try readMMIO(pa, size: 1) & 0xFF)
    }

    private func readPhysical32(_ pa: UInt64) throws -> UInt32 {
        if pa >= Self.ramBase && pa + 4 <= Self.ramBase + UInt64(memorySize) {
            let o = Int(pa - Self.ramBase)
            return UInt32(memory[o]) | UInt32(memory[o + 1]) << 8 | UInt32(memory[o + 2]) << 16 | UInt32(memory[o + 3]) << 24
        }
        return UInt32(try readMMIO(pa, size: 4) & 0xFFFF_FFFF)
    }

    private func readPhysical(_ pa: UInt64, size: Int) throws -> UInt64 {
        if pa >= Self.ramBase && pa + UInt64(size) <= Self.ramBase + UInt64(memorySize) {
            var value: UInt64 = 0
            let o = Int(pa - Self.ramBase)
            for i in 0..<size { value |= UInt64(memory[o + i]) << (8 * i) }
            return value
        }
        return try readMMIO(pa, size: size)
    }

    private func writePhysical(_ pa: UInt64, size: Int, _ value: UInt64) throws {
        if pa >= Self.ramBase && pa + UInt64(size) <= Self.ramBase + UInt64(memorySize) {
            let o = Int(pa - Self.ramBase)
            for i in 0..<size { memory[o + i] = UInt8((value >> (8 * i)) & 0xFF) }
            return
        }
        try writeMMIO(pa, size: size, value)
    }

    private func readMMIO(_ pa: UInt64, size: Int) throws -> UInt64 {
        if pa >= Self.uartBase && pa < Self.uartBase + 0x1000 {
            return uartRead(offset: pa - Self.uartBase)
        }
        if pa >= Self.gicDistBase && pa < Self.gicDistBase + 0x10000 {
            return gicDistRead(offset: pa - Self.gicDistBase)
        }
        if pa >= Self.gicCPUBase && pa < Self.gicCPUBase + 0x10000 {
            return gicCPURead(offset: pa - Self.gicCPUBase)
        }
        if pa >= Self.controlBase && pa < Self.controlBase + 0x1000 {
            return 0xAE64
        }
        if pa >= Self.aicBase && pa < Self.aicBase + 0x8000 {
            return aicRead(offset: pa - Self.aicBase)
        }
        if pa >= Self.nvmeBase && pa < Self.nvmeBase + 0x10000 {
            ensureNVMeWiring()
            return nvme.readRegister(offset: pa - Self.nvmeBase)
        }
        throw ARM64Fault.memoryOutOfBounds(address: pa)
    }

    private func writeMMIO(_ pa: UInt64, size: Int, _ value: UInt64) throws {
        if pa >= Self.uartBase && pa < Self.uartBase + 0x1000 {
            uartWrite(offset: pa - Self.uartBase, value: value)
            return
        }
        if pa >= Self.gicDistBase && pa < Self.gicDistBase + 0x10000 {
            gicDistWrite(offset: pa - Self.gicDistBase, value: value)
            return
        }
        if pa >= Self.gicCPUBase && pa < Self.gicCPUBase + 0x10000 {
            gicCPUWrite(offset: pa - Self.gicCPUBase, value: value)
            return
        }
        if pa >= Self.controlBase && pa < Self.controlBase + 0x1000 {
            halted = true
            exitCode = Int32(truncatingIfNeeded: value)
            return
        }
        if pa >= Self.aicBase && pa < Self.aicBase + 0x8000 {
            aicWrite(offset: pa - Self.aicBase, value: value)
            return
        }
        if pa >= Self.nvmeBase && pa < Self.nvmeBase + 0x10000 {
            ensureNVMeWiring()
            nvme.writeRegister(offset: pa - Self.nvmeBase, value: value, size: size)
            return
        }
        throw ARM64Fault.memoryOutOfBounds(address: pa)
    }

    /// NVMe コントローラへ RAM アクセスと割り込みラインを結線する（初回アクセス時）。
    private func ensureNVMeWiring() {
        if nvmeWired { return }
        nvmeWired = true
        nvme.readRAM = { [weak self] address, count in
            guard let self, address >= Self.ramBase else { return [UInt8](repeating: 0, count: count) }
            let start = Int(address - Self.ramBase)
            guard start >= 0, start < self.memory.count else { return [UInt8](repeating: 0, count: count) }
            let end = min(start + count, self.memory.count)
            var bytes = [UInt8](self.memory[start..<end])
            if bytes.count < count { bytes += [UInt8](repeating: 0, count: count - bytes.count) }
            return bytes
        }
        nvme.writeRAM = { [weak self] address, bytes in
            guard let self, address >= Self.ramBase else { return }
            let start = Int(address - Self.ramBase)
            guard start >= 0, start < self.memory.count else { return }
            let end = min(start + bytes.count, self.memory.count)
            self.memory.replaceSubrange(start..<end, with: bytes[..<(end - start)])
        }
        nvme.onIRQ = { [weak self] in
            self?.nvmeIRQLine = true
        }
    }

    // MARK: UART（PL011 ライト）

    private func uartRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x00:  // DR: 受信データ
            inputLock.lock()
            defer { inputLock.unlock() }
            if let byte = inputQueue.first {
                inputQueue.removeFirst()
                return UInt64(byte)
            }
            return 0
        case 0x18:  // FR: bit4 = RXFE（受信 FIFO 空）, bit7 = TXFE（送信空）
            return (inputQueueEmpty ? UInt64(1 << 4) : 0) | (1 << 7)
        default:
            return 0
        }
    }

    private func uartWrite(offset: UInt64, value: UInt64) {
        if offset == 0x00 {
            onChar?(UInt8(value & 0xFF))
        }
    }

    // MARK: 割り込みコントローラ（GIC ライト）

    private func gicDistRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x000: return gicDistEnabled ? 1 : 0
        case 0x004: return 0x0000_0019      // TYPER: ITLinesNumber=0 (INTID 0...31+SPI), CPUNumber=0
        case 0x100: return UInt64(UInt32(truncatingIfNeeded: gicEnabledINTIDs))
        case 0x104: return UInt64(UInt32(truncatingIfNeeded: gicEnabledINTIDs >> 32))
        case 0x200, 0x204:                  // ISPENDR: 保留中の割り込み
            var pending: UInt64 = 0
            if timerExpired && (cntpCtl & 0x2) == 0 && !timerAcked { pending |= 1 << Self.timerINTID }
            if !inputQueueEmpty { pending |= 1 << Self.uartINTID }
            return offset == 0x200 ? UInt64(UInt32(truncatingIfNeeded: pending)) : UInt64(UInt32(truncatingIfNeeded: pending >> 32))
        default: return 0
        }
    }

    private func gicDistWrite(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x000: gicDistEnabled = value & 1 != 0
        case 0x100: gicEnabledINTIDs |= UInt64(UInt32(truncatingIfNeeded: value))
        case 0x104: gicEnabledINTIDs |= UInt64(UInt32(truncatingIfNeeded: value)) << 32
        case 0x180: gicEnabledINTIDs &= ~UInt64(UInt32(truncatingIfNeeded: value))
        case 0x184: gicEnabledINTIDs &= ~(UInt64(UInt32(truncatingIfNeeded: value)) << 32)
        default: break
        }
    }

    private func gicCPURead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x00: return gicCPUEnabled ? 1 : 0
        case 0x04: return gicPriorityMask
        case 0x0C:  // IAR: 保留中の最優先 INTID を応答する
            if timerExpired && (cntpCtl & 0x2) == 0 && gicEnabled(Self.timerINTID) {
                timerAcked = true
                return Self.timerINTID
            }
            if !inputQueueEmpty && gicEnabled(Self.uartINTID) {
                return Self.uartINTID
            }
            return 1023   // スプリアス
        default: return 0
        }
    }

    private func gicCPUWrite(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x00: gicCPUEnabled = value & 1 != 0
        case 0x04: gicPriorityMask = value & 0xFF
        case 0x10:  // EOIR
            if value == Self.timerINTID { timerAcked = false }
        default: break
        }
    }

    // MARK: - ゲストデータアクセス（変換付き）

    private func loadValue(address: UInt64, size: Int, signExtendTo64: Bool = false, signBit: Int = 0) throws -> UInt64 {
        let pa = try translate(address: address, isWrite: false, isFetch: false)
        var value = try readPhysical(pa, size: size)
        if signExtendTo64 {
            let shift = 64 - signBit
            value = UInt64(bitPattern: (Int64(bitPattern: value << shift)) >> shift)
        }
        return value
    }

    private func storeValue(address: UInt64, size: Int, _ value: UInt64) throws {
        let pa = try translate(address: address, isWrite: true, isFetch: false)
        try writePhysical(pa, size: size, value)
    }

    // MARK: - 命令デコード補助

    private func signExtend(_ value: UInt64, bits: Int) -> UInt64 {
        let shift = 64 - bits
        return UInt64(bitPattern: (Int64(bitPattern: value << shift)) >> shift)
    }

    private func shiftValue(_ value: UInt64, type: UInt32, amount: Int, is64: Bool) -> UInt64 {
        let width: UInt64 = is64 ? UInt64.max : 0xFFFF_FFFF
        let v = value & width
        let amt = is64 ? (amount & 63) : (amount & 31)
        switch type {
        case 0: return (v << amt) & width                       // LSL
        case 1: return v >> amt                                 // LSR
        case 2:                                                  // ASR
            if is64 { return UInt64(bitPattern: Int64(bitPattern: v) >> amt) }
            return UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(v))) >> amt) & width
        default:                                                 // ROR
            if amt == 0 { return v }
            if is64 { return (v >> amt) | (v << (64 - amt)) }
            let v32 = UInt32(v)
            return UInt64((v32 >> amt) | (v32 << (32 - amt)))
        }
    }

    /// ビットマスク即値（DecodeBitMasks）の復号。失敗時は nil。
    private func decodeBitMasks(n: Int, imms: Int, immr: Int, is64: Bool) -> UInt64? {
        if !is64 && n == 1 { return nil }
        let combined = (n << 6) | (~imms & 0x3F)
        var len = 0
        for i in (0..<7).reversed() {
            if (combined >> i) & 1 == 1 { len = i; break }
        }
        if len < 1 || len > 6 { return nil }
        let esize = 1 << len
        let levels = esize - 1
        let s = imms & levels
        let r = immr & levels
        if s == levels { return nil }
        let element = (UInt64(1) << (s + 1)) - 1
        let rotated: UInt64
        if r == 0 { rotated = element }
        else { rotated = (element >> r) | (element << (esize - r)) }
        var result: UInt64 = 0
        var pos = 0
        while pos < 64 {
            result |= rotated << pos
            pos += esize
        }
        return is64 ? result : (result & 0xFFFF_FFFF)
    }

    private func addWithCarry(_ a: UInt64, _ b: UInt64, carry: Bool, is64: Bool) -> (result: UInt64, n: Bool, z: Bool, c: Bool, v: Bool) {
        let mask: UInt64 = is64 ? UInt64.max : 0xFFFF_FFFF
        let x = a & mask, y = b & mask
        let sum = x &+ y &+ (carry ? 1 : 0)
        let result = sum & mask
        let signBit: UInt64 = is64 ? (1 << 63) : (1 << 31)
        let n = result & signBit != 0
        let z = result == 0
        let c = is64 ? (sum < x || (carry && sum == x)) : (sum > mask)
        let v = (x & signBit) == (y & signBit) && (result & signBit) != (x & signBit)
        return (result, n, z, c, v)
    }

    private func conditionHolds(_ cond: Int) -> Bool {
        switch cond {
        case 0x0: return flagZ                       // EQ
        case 0x1: return !flagZ                      // NE
        case 0x2: return flagC                       // CS
        case 0x3: return !flagC                      // CC
        case 0x4: return flagN                       // MI
        case 0x5: return !flagN                      // PL
        case 0x6: return flagV                       // VS
        case 0x7: return !flagV                      // VC
        case 0x8: return flagC && !flagZ             // HI
        case 0x9: return !flagC || flagZ             // LS
        case 0xA: return flagN == flagV              // GE
        case 0xB: return flagN != flagV              // LT
        case 0xC: return !flagZ && (flagN == flagV)  // GT
        case 0xD: return flagZ || (flagN != flagV)   // LE
        default: return true                         // AL / NV
        }
    }

    // MARK: - 命令実行

    private func execute(_ insn: UInt32, at instructionPC: UInt64) throws {
        let rd = Int(insn & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rm = Int((insn >> 16) & 0x1F)

        // --- 例外生成 / システム ---
        if (insn & 0xFFFF_FFE0) == 0xD69F_03E0 { eret(); return }       // ERET
        if (insn & 0xFFE0_001F) == 0xD400_0001 {                        // SVC
            try executeSVC(imm: Int((insn >> 5) & 0xFFFF), at: instructionPC)
            return
        }
        if (insn & 0xFFE0_001F) == 0xD420_0000 {                        // BRK
            raiseSync(ec: 0x3C, iss: UInt64((insn >> 5) & 0xFFFF), elr: instructionPC)
            return
        }
        if (insn & 0xFFFF_0000) == 0xD503_0000 && ((insn >> 12) & 0xF) < 4 {
            // HINT / バリア / CLREX 空間（bits[15:12] = 2: HINT、3: バリア）
            if insn == 0xD503_207F {                                    // WFI
                if !(interruptPending && !irqMasked) { idle = true }
            } else if insn == 0xD503_305F {                             // CLREX
                exclusiveAddress = nil
            }
            return                                                      // NOP / バリアは無動作
        }
        if (insn & 0xFF00_0000) == 0xD500_0000 {                        // システム命令空間
            try executeSystem(insn, at: instructionPC)
            return
        }

        // --- 分岐 ---
        if (insn & 0x7C00_0000) == 0x1400_0000 {                        // B / BL
            let offset = signExtend(UInt64(insn & 0x03FF_FFFF) << 2, bits: 28)
            if insn & 0x8000_0000 != 0 { writeReg(30, pc) }             // BL: LR = 次の命令
            pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            return
        }
        if (insn & 0xFF00_0010) == 0x5400_0000 {                        // B.cond
            if conditionHolds(Int(insn & 0xF)) {
                let offset = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            }
            return
        }
        if (insn & 0x7E00_0000) == 0x3400_0000 {                        // CBZ / CBNZ
            let is64 = insn & 0x8000_0000 != 0
            var value = readReg(rd)
            if !is64 { value &= 0xFFFF_FFFF }
            let isZero = value == 0
            let invert = insn & 0x0100_0000 != 0
            if isZero != invert {
                let offset = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            }
            return
        }
        if (insn & 0x7E00_0000) == 0x3600_0000 {                        // TBZ / TBNZ
            let bitPos = Int(((insn >> 26) & 0x20) | ((insn >> 19) & 0x1F))
            let bit = (readReg(Int(insn & 0x1F)) >> bitPos) & 1
            let invert = insn & 0x0100_0000 != 0
            if (bit == 1) == invert {
                let offset = signExtend(UInt64((insn >> 5) & 0x3FFF) << 2, bits: 16)
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            }
            return
        }
        if (insn & 0xFFFF_FC1F) == 0xD61F_0000 { pc = readReg(rn); return }        // BR
        if (insn & 0xFFFF_FC1F) == 0xD63F_0000 { writeReg(30, pc); pc = readReg(rn); return } // BLR
        if (insn & 0xFFFF_FC1F) == 0xD65F_0000 { pc = readReg(rn); return }        // RET

        // --- ロード / ストア ---
        if try executeLoadStore(insn, rd: rd, rn: rn, rm: rm, at: instructionPC) { return }

        // --- データ処理（即値） ---
        if try executeDataImmediate(insn, rd: rd, rn: rn, at: instructionPC) { return }

        // --- データ処理（レジスタ） ---
        if try executeDataRegister(insn, rd: rd, rn: rn, rm: rm) { return }

        // 未定義命令（SIMD / FP など未実装の領域を含む）
        raiseSync(ec: 0x00, iss: 0, elr: instructionPC)
    }

    // MARK: データ処理（即値）

    private func executeDataImmediate(_ insn: UInt32, rd: Int, rn: Int, at instructionPC: UInt64) throws -> Bool {
        let sf = insn & 0x8000_0000 != 0
        // PC 相対: ADR / ADRP
        if (insn & 0x1F00_0000) == 0x1000_0000 {
            let imm = signExtend((UInt64(insn & 0x6000_0000) >> 29) | (UInt64((insn >> 5) & 0x7_FFFF) << 2), bits: 21)
            if insn & 0x8000_0000 != 0 {  // ADRP（命令自体の sf ではなく op ビット）
                let base = instructionPC & ~0xFFF
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: base) &+ (Int64(bitPattern: imm) << 12)))
            } else {
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: imm)))
            }
            return true
        }
        // ADD / SUB（即値）
        if (insn & 0x1F00_0000) == 0x1100_0000 {
            let isSub = insn & 0x4000_0000 != 0
            let setFlags = insn & 0x2000_0000 != 0
            var imm = UInt64((insn >> 10) & 0xFFF)
            if insn & 0x0040_0000 != 0 { imm <<= 12 }
            let a = readReg(rn, sp: !setFlags)
            let b = isSub ? ~imm : imm
            let r = addWithCarry(a, b, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(rd, r.result, sp: !setFlags, width64: sf)
            return true
        }
        // 論理（即値）
        if (insn & 0x1F80_0000) == 0x1200_0000 {
            let opc = (insn >> 29) & 0x3
            let nBit = Int((insn >> 22) & 1)
            let immr = Int((insn >> 16) & 0x3F)
            let imms = Int((insn >> 10) & 0x3F)
            guard let imm = decodeBitMasks(n: nBit, imms: imms, immr: immr, is64: sf) else {
                raiseSync(ec: 0x00, iss: 0, elr: instructionPC)
                return true
            }
            let a = readReg(rn)
            let result: UInt64
            switch opc {
            case 0: result = a & imm
            case 1: result = a | imm
            case 2: result = a ^ imm
            default:
                result = a & imm
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        // Move wide（MOVZ / MOVN / MOVK）
        if (insn & 0x1F80_0000) == 0x1280_0000 {
            let opc = (insn >> 29) & 0x3
            let hw = Int((insn >> 21) & 0x3) * 16
            let imm = UInt64((insn >> 5) & 0xFFFF) << hw
            switch opc {
            case 0: writeReg(rd, ~imm, width64: sf)                                   // MOVN
            case 2: writeReg(rd, imm, width64: sf)                                    // MOVZ
            case 3:                                                                    // MOVK
                var current = readReg(rd)
                current = (current & ~(UInt64(0xFFFF) << hw)) | imm
                writeReg(rd, current, width64: sf)
            default:
                raiseSync(ec: 0x00, iss: 0, elr: instructionPC)
            }
            return true
        }
        // ビットフィールド（SBFM / BFM / UBFM）
        if (insn & 0x1F80_0000) == 0x1300_0000 {
            let opc = (insn >> 29) & 0x3
            let immr = Int((insn >> 16) & 0x3F)
            let imms = Int((insn >> 10) & 0x3F)
            let width = sf ? 64 : 32
            let source = readReg(rn)
            let result: UInt64
            if imms >= immr {
                // 右寄せ抽出（LSR 相当の範囲）
                let bits = imms - immr + 1
                let mask = bits >= 64 ? UInt64.max : ((UInt64(1) << bits) - 1)
                let extracted = (source >> immr) & mask
                switch opc {
                case 0: result = signExtend(extracted, bits: bits) & (sf ? UInt64.max : 0xFFFF_FFFF)  // SBFM
                case 1:                                                                                // BFM
                    let dest = readReg(rd)
                    result = (dest & ~mask) | extracted
                default: result = extracted                                                           // UBFM
                }
            } else {
                // 左寄せ挿入（LSL 相当の範囲）
                let bits = imms + 1
                let mask = ((UInt64(1) << bits) - 1) << (width - immr)
                let inserted = (source << (width - immr)) & mask
                switch opc {
                case 0:  // SBFM（挿入フィールドの最上位ビットから符号拡張）
                    let signTopPos = (width - immr) + imms
                    let sh = 63 - signTopPos
                    result = UInt64(bitPattern: (Int64(bitPattern: inserted) << sh) >> sh) & (sf ? UInt64.max : 0xFFFF_FFFF)
                case 1:
                    let dest = readReg(rd)
                    result = (dest & ~mask) | inserted
                default: result = inserted
                }
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        // EXTR
        if (insn & 0x1F80_0000) == 0x1380_0000 {
            let imms = Int((insn >> 10) & 0x3F)
            let hi = readReg(rn)
            let lo = readReg(Int((insn >> 16) & 0x1F))
            let result: UInt64
            if sf {
                result = imms == 0 ? lo : ((hi << (64 - imms)) | (lo >> imms))
            } else {
                let combined = (UInt64(UInt32(hi)) << 32) | UInt64(UInt32(lo))
                result = UInt64(UInt32((combined >> imms) & 0xFFFF_FFFF))
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        return false
    }

    // MARK: データ処理（レジスタ）

    private func executeDataRegister(_ insn: UInt32, rd: Int, rn: Int, rm: Int) throws -> Bool {
        let sf = insn & 0x8000_0000 != 0
        // 論理（シフト付きレジスタ）
        if [0x0A00_0000, 0x2A00_0000, 0x4A00_0000, 0x6A00_0000].contains(insn & 0x1F00_0000) {
            let opc = (insn >> 29) & 0x3
            let invert = insn & 0x0020_0000 != 0
            let shiftType = (insn >> 22) & 0x3
            let amount = Int((insn >> 10) & 0x3F)
            var operand = shiftValue(readReg(rm), type: shiftType, amount: amount, is64: sf)
            if invert { operand = ~operand }
            let a = readReg(rn)
            let result: UInt64
            switch opc {
            case 0: result = a & operand
            case 1: result = a | operand
            case 2: result = a ^ operand
            default:
                result = a & operand
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        // ADD / SUB（シフト付きレジスタ）
        if (insn & 0x1F20_0000) == 0x0B00_0000 {
            let isSub = insn & 0x4000_0000 != 0
            let setFlags = insn & 0x2000_0000 != 0
            let shiftType = (insn >> 22) & 0x3
            let amount = Int((insn >> 10) & 0x3F)
            let operand = shiftValue(readReg(rm), type: shiftType, amount: amount, is64: sf)
            let a = readReg(rn)
            let r = addWithCarry(a, isSub ? ~operand : operand, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(rd, r.result, width64: sf)
            return true
        }
        // ADD / SUB（拡張レジスタ）
        if (insn & 0x1F20_0000) == 0x0B20_0000 {
            let isSub = insn & 0x4000_0000 != 0
            let setFlags = insn & 0x2000_0000 != 0
            let option = Int((insn >> 13) & 0x7)
            let amount = Int((insn >> 10) & 0x7)
            let operand = extendValue(readReg(rm), option: option, shift: amount)
            let a = readReg(rn, sp: !setFlags)
            let r = addWithCarry(a, isSub ? ~operand : operand, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(rd, r.result, sp: !setFlags, width64: sf)
            return true
        }
        // ADC / SBC
        if (insn & 0x1FE0_0000) == 0x1A00_0000 {
            let isSub = insn & 0x4000_0000 != 0
            let setFlags = insn & 0x2000_0000 != 0
            let a = readReg(rn)
            let b = readReg(rm)
            let r = addWithCarry(a, isSub ? ~b : b, carry: flagC, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(rd, r.result, width64: sf)
            return true
        }
        // 条件選択（CSEL / CSINC / CSINV / CSNEG）
        if (insn & 0x1FE0_0000) == 0x1A80_0000 {
            let cond = Int((insn >> 12) & 0xF)
            let invertResult = insn & 0x4000_0000 != 0     // CSINV / CSNEG 側
            let increment = insn & 0x0000_0400 != 0        // CSINC / CSNEG 側
            let other = readReg(rm)
            let result: UInt64
            if conditionHolds(cond) {
                result = readReg(rn)
            } else if invertResult && increment {
                result = ~other &+ 1                       // CSNEG
            } else if invertResult {
                result = ~other                            // CSINV
            } else if increment {
                result = other &+ 1                        // CSINC
            } else {
                result = other                             // CSEL
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        // 条件比較（CCMP / CCMN、レジスタ・即値）
        if (insn & 0x3FE0_0000) == 0x3A40_0000 {
            let isCompare = insn & 0x4000_0000 != 0        // 1 = CCMP（減算）
            let cond = Int((insn >> 12) & 0xF)
            if conditionHolds(cond) {
                let a = readReg(rn)
                let b: UInt64
                if insn & 0x0000_0800 != 0 {
                    b = UInt64((insn >> 16) & 0x1F)        // 即値形式
                } else {
                    b = readReg(rm)
                }
                let r = addWithCarry(a, isCompare ? ~b : b, carry: isCompare, is64: sf)
                applyFlags(r)
            } else {
                let nzcv = insn & 0xF
                setNZCV(n: nzcv & 0x8 != 0, z: nzcv & 0x4 != 0, c: nzcv & 0x2 != 0, v: nzcv & 0x1 != 0)
            }
            return true
        }
        // データ処理（2 ソース / 1 ソース）
        if (insn & 0x1FE0_0000) == 0x1AC0_0000 {
            let opcode = Int((insn >> 10) & 0x3F)
            let a = readReg(rn)
            if insn & 0x4000_0000 != 0 {
                // 1 ソース（RBIT / REV16 / REV / CLZ / CLS）
                let result: UInt64
                switch opcode {
                case 0x00:  // RBIT
                    result = sf ? reverseBits(a) : UInt64(reverseBits32(UInt32(a)))
                case 0x01:  // REV16
                    result = sf ? byteSwap16(a) : UInt64(byteSwap16(UInt64(UInt32(a))) & 0xFFFF_FFFF)
                case 0x02:  // REV32（32 ビット形のみ）
                    if sf { return false }
                    result = UInt64(UInt32(a).byteSwapped)
                case 0x03:  // REV（64 ビット形のみ）
                    if !sf { return false }
                    result = a.byteSwapped
                case 0x04:  // CLZ
                    result = UInt64(sf ? a.leadingZeroBitCount : UInt32(a).leadingZeroBitCount)
                case 0x05:  // CLS
                    result = UInt64(countLeadingSignBits(a, is64: sf))
                default:
                    return false
                }
                writeReg(rd, result, width64: sf)
                return true
            }
            let b = readReg(rm)
            let amount = Int(b & (sf ? 63 : 31))
            let result: UInt64
            switch opcode {
            case 0x02:  // UDIV
                result = (sf ? b : (b & 0xFFFF_FFFF)) == 0 ? 0 : (sf ? a / b : (a & 0xFFFF_FFFF) / (b & 0xFFFF_FFFF))
            case 0x03:  // SDIV
                result = signedDivide(a, b, is64: sf)
            case 0x08: result = shiftValue(a, type: 0, amount: amount, is64: sf)   // LSL
            case 0x09: result = shiftValue(a, type: 1, amount: amount, is64: sf)   // LSR
            case 0x0A: result = shiftValue(a, type: 2, amount: amount, is64: sf)   // ASR
            case 0x0B: result = shiftValue(a, type: 3, amount: amount, is64: sf)   // ROR
            default:
                return false
            }
            writeReg(rd, result, width64: sf)
            return true
        }
        // データ処理（3 ソース）
        if (insn & 0x1F00_0000) == 0x1B00_0000 {
            let ra = Int((insn >> 10) & 0x1F)
            let a = readReg(rn)
            let b = readReg(rm)
            let addend = readReg(ra)
            let masked = insn & 0x7FE0_8000
            switch masked {
            case 0x1B00_0000:  // MADD
                writeReg(rd, addend &+ (a &* b), width64: sf)
            case 0x1B00_8000:  // MSUB
                writeReg(rd, addend &- (a &* b), width64: sf)
            case 0x1B40_0000:  // SMULH
                let product = Int64(bitPattern: a).multipliedFullWidth(by: Int64(bitPattern: b))
                writeReg(rd, UInt64(bitPattern: product.high))
            case 0x1BC0_0000:  // UMULH
                let product = a.multipliedFullWidth(by: b)
                writeReg(rd, product.high)
            case 0x1B20_0000 where sf:  // SMADDL
                let product = Int64(Int32(bitPattern: UInt32(a))) * Int64(Int32(bitPattern: UInt32(b)))
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: addend) &+ product))
            case 0x1B20_8000 where sf:  // SMSUBL
                let product = Int64(Int32(bitPattern: UInt32(a))) * Int64(Int32(bitPattern: UInt32(b)))
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: addend) &- product))
            case 0x1BA0_0000 where sf:  // UMADDL
                let product = UInt64(UInt32(a)) * UInt64(UInt32(b))
                writeReg(rd, addend &+ product)
            case 0x1BA0_8000 where sf:  // UMSUBL
                let product = UInt64(UInt32(a)) * UInt64(UInt32(b))
                writeReg(rd, addend &- product)
            default:
                return false
            }
            return true
        }
        return false
    }

    private func extendValue(_ value: UInt64, option: Int, shift: Int) -> UInt64 {
        let extended: UInt64
        switch option {
        case 0: extended = value & 0xFF                    // UXTB
        case 1: extended = value & 0xFFFF                  // UXTH
        case 2: extended = value & 0xFFFF_FFFF             // UXTW
        case 3: extended = value                           // UXTX
        case 4: extended = signExtend(value & 0xFF, bits: 8)     // SXTB
        case 5: extended = signExtend(value & 0xFFFF, bits: 16)  // SXTH
        case 6: extended = signExtend(value & 0xFFFF_FFFF, bits: 32)  // SXTW
        default: extended = value                          // SXTX
        }
        return extended << shift
    }

    private func signedDivide(_ a: UInt64, _ b: UInt64, is64: Bool) -> UInt64 {
        if is64 {
            let x = Int64(bitPattern: a), y = Int64(bitPattern: b)
            if y == 0 { return 0 }
            if x == Int64.min && y == -1 { return a }
            return UInt64(bitPattern: x / y)
        }
        let x = Int32(bitPattern: UInt32(a)), y = Int32(bitPattern: UInt32(b))
        if y == 0 { return 0 }
        if x == Int32.min && y == -1 { return UInt64(UInt32(bitPattern: x)) }
        return UInt64(UInt32(bitPattern: x / y))
    }

    private func reverseBits(_ value: UInt64) -> UInt64 {
        var v = value
        var r: UInt64 = 0
        for _ in 0..<64 {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }

    private func reverseBits32(_ value: UInt32) -> UInt32 {
        UInt32(reverseBits(UInt64(value) << 32) & 0xFFFF_FFFF)
    }

    /// 16 ビット要素ごとのバイト入れ替え（REV16）。
    private func byteSwap16(_ value: UInt64) -> UInt64 {
        ((value & 0x00FF_00FF_00FF_00FF) << 8) | ((value >> 8) & 0x00FF_00FF_00FF_00FF)
    }

    private func countLeadingSignBits(_ value: UInt64, is64: Bool) -> Int {
        if is64 {
            let sign = value >> 63
            var count = 0
            var bit = 62
            while bit >= 0 {
                if (value >> bit) & 1 == sign { count += 1; bit -= 1 } else { break }
            }
            return count
        }
        let v = UInt32(value)
        let sign = v >> 31
        var count = 0
        var bit = 30
        while bit >= 0 {
            if (v >> bit) & 1 == sign { count += 1; bit -= 1 } else { break }
        }
        return count
    }

    // MARK: ロード / ストア

    private func executeLoadStore(_ insn: UInt32, rd: Int, rn: Int, rm: Int, at instructionPC: UInt64) throws -> Bool {
        let size = Int((insn >> 30) & 0x3)
        let bytes = 1 << size
        let opc = Int((insn >> 22) & 0x3)
        let base = readReg(rn, sp: true)

        // 排他アクセス / CAS（0x08 空間）
        if (insn & 0x3F00_0000) == 0x0800_0000 {
            if insn & 0x0020_0000 != 0 {
                // CAS: Rs = 期待値、Rt = 新しい値（旧値を返す）
                let rs = Int((insn >> 16) & 0x1F)
                let expected = readReg(rs)
                let old = try loadValue(address: base, size: bytes)
                if old == (bytes == 8 ? expected : (expected & ((UInt64(1) << (bytes * 8)) - 1))) {
                    try storeValue(address: base, size: bytes, readReg(rd))
                }
                writeReg(rs, old, width64: bytes == 8)   // 旧値は Rs（期待値レジスタ）へ返す
                return true
            }
            if insn & 0x0040_0000 != 0 {
                // LDXR / LDAXR
                let value = try loadValue(address: base, size: bytes)
                exclusiveAddress = base
                writeReg(rd, value, width64: bytes == 8)
            } else {
                // STXR / STLXR: Rs に成否（0 = 成功）
                let rs = Int((insn >> 16) & 0x1F)
                if exclusiveAddress == base {
                    try storeValue(address: base, size: bytes, readReg(rd))
                    writeReg(rs, 0)
                } else {
                    writeReg(rs, 1)
                }
                exclusiveAddress = nil
            }
            return true
        }

        // LSE アトミック（LDADD 系 / SWP）
        // 注意: レジスタオフセット形式のロード/ストア（bits[11:10] = 0b10）と
        // 未スケーリング即値形式（bits[22:21] = 0b10）を巻き込まないよう、
        // bits[22:21] = 0b01 かつ bits[11:10] = 0b00 まで含めて判定する。
        if (insn & 0x3F60_0C00) == 0x3820_0000 {
            let rs = Int((insn >> 16) & 0x1F)
            let operand = readReg(rs)
            let old = try loadValue(address: base, size: bytes)
            let mask: UInt64 = bytes == 8 ? UInt64.max : ((UInt64(1) << (bytes * 8)) - 1)
            let newValue: UInt64
            if ((insn >> 10) & 0x3F) == 0b100000 {
                newValue = operand & mask                          // SWP
            } else {
                switch Int((insn >> 12) & 0x7) {
                case 0: newValue = (old &+ operand) & mask         // LDADD
                case 1: newValue = old & ~operand                  // LDCLR
                case 2: newValue = old ^ (operand & mask)           // LDEOR
                case 3: newValue = old | (operand & mask)           // LDSET
                case 4: newValue = signedMax(old, operand, bytes: bytes)   // LDSMAX
                case 5: newValue = signedMin(old, operand, bytes: bytes)   // LDSMIN
                case 6: newValue = max(old, operand & mask)                 // LDUMAX
                default: newValue = min(old, operand & mask)                // LDUMIN
                }
            }
            try storeValue(address: base, size: bytes, newValue)
            writeReg(rd, old, width64: bytes == 8)
            return true
        }

        // LDR リテラル（サイズ選択は bits[31:30]。bits[23:22] は imm19 の一部）
        if (insn & 0x3B00_0000) == 0x1800_0000 {
            let literalOpc = Int((insn >> 30) & 0x3)
            if literalOpc == 3 { return true }                     // PRFM は NOP 扱い
            let offset = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
            let address = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            switch literalOpc {
            case 0: writeReg(rd, try loadValue(address: address, size: 4), width64: false)
            case 1: writeReg(rd, try loadValue(address: address, size: 8))
            default: writeReg(rd, try loadValue(address: address, size: 4, signExtendTo64: true, signBit: 32))
            }
            return true
        }

        // ペア（LDP / STP / LDPSW）
        if (insn & 0x3A00_0000) == 0x2800_0000 && (insn & 0x0400_0000) == 0 {
            let isLoad = insn & 0x0040_0000 != 0
            let mode = Int((insn >> 23) & 0x7)   // 001 = ポスト、010 = オフセット、011 = プレ
            // ペアの要素サイズは bits[31:30]（0 = 4 バイト、1 = LDPSW、2 = 8 バイト）
            let pairSize = size == 2 ? 8 : 4
            let imm7 = signExtend(UInt64((insn >> 15) & 0x7F), bits: 7)
            let offset = Int64(bitPattern: imm7) * Int64(pairSize)
            let rt2 = Int((insn >> 10) & 0x1F)
            var address = base
            switch mode {
            case 1: address = base                              // ポストインデックス
            case 3: address = UInt64(bitPattern: Int64(bitPattern: base) &+ offset)  // プレインデックス
            default: address = UInt64(bitPattern: Int64(bitPattern: base) &+ offset) // オフセット
            }
            if isLoad {
                let first = try loadValue(address: address, size: pairSize)
                let second = try loadValue(address: address &+ UInt64(pairSize), size: pairSize)
                if size == 1 {  // LDPSW（32 ビット ×2 を符号拡張）
                    writeReg(rd, signExtend(first, bits: 32))
                    writeReg(rt2, signExtend(second, bits: 32))
                } else {
                    writeReg(rd, first, width64: pairSize == 8)
                    writeReg(rt2, second, width64: pairSize == 8)
                }
            } else {
                try storeValue(address: address, size: pairSize, readReg(rd))
                try storeValue(address: address &+ UInt64(pairSize), size: pairSize, readReg(rt2))
            }
            if mode == 1 || mode == 3 {
                writeReg(rn, UInt64(bitPattern: Int64(bitPattern: base) &+ offset), sp: true)
            }
            return true
        }

        // 単一ロード / ストア: アドレス計算
        let address: UInt64
        var writeback: UInt64? = nil
        if (insn & 0x3B00_0000) == 0x3900_0000 {
            // 符号なし即値オフセット
            let imm12 = UInt64((insn >> 10) & 0xFFF) << size
            address = base &+ imm12
        } else if (insn & 0x3B20_0C00) == 0x3820_0800 {
            // レジスタオフセット
            let option = Int((insn >> 13) & 0x7)
            let shiftAmount = ((insn >> 12) & 1) == 1 ? size : 0
            let offset = extendValue(readReg(rm), option: option, shift: shiftAmount)
            address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: offset))
        } else if (insn & 0x3B20_0000) == 0x3800_0000 {
            // 即値 9 ビット（アンスケールド / プレ / ポスト / 非特権）
            let imm9 = signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)
            let indexMode = Int((insn >> 10) & 0x3)
            switch indexMode {
            case 1:  // ポストインデックス
                address = base
                writeback = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
            case 3:  // プレインデックス
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
                writeback = address
            default: // アンスケールド / 非特権（LDTR は通常アクセスとして扱う）
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
            }
        } else {
            return false
        }

        switch opc {
        case 0:  // ストア
            try storeValue(address: address, size: bytes, readReg(rd))
        case 1:  // ロード（ゼロ拡張）
            writeReg(rd, try loadValue(address: address, size: bytes), width64: bytes == 8)
        case 2:  // ロード（64 ビットへ符号拡張）
            writeReg(rd, try loadValue(address: address, size: bytes, signExtendTo64: true, signBit: bytes * 8))
        default: // ロード（32 ビットへ符号拡張）
            let value = try loadValue(address: address, size: bytes, signExtendTo64: true, signBit: bytes * 8)
            writeReg(rd, value & 0xFFFF_FFFF, width64: false)
        }
        if let writeback {
            writeReg(rn, writeback, sp: true)
        }
        return true
    }

    private func signedMax(_ a: UInt64, _ b: UInt64, bytes: Int) -> UInt64 {
        let mask: UInt64 = bytes == 8 ? UInt64.max : ((UInt64(1) << (bytes * 8)) - 1)
        let sa = Int64(bitPattern: signExtend(a & mask, bits: bytes * 8))
        let sb = Int64(bitPattern: signExtend(b & mask, bits: bytes * 8))
        return UInt64(bitPattern: max(sa, sb)) & mask
    }

    private func signedMin(_ a: UInt64, _ b: UInt64, bytes: Int) -> UInt64 {
        let mask: UInt64 = bytes == 8 ? UInt64.max : ((UInt64(1) << (bytes * 8)) - 1)
        let sa = Int64(bitPattern: signExtend(a & mask, bits: bytes * 8))
        let sb = Int64(bitPattern: signExtend(b & mask, bits: bytes * 8))
        return UInt64(bitPattern: min(sa, sb)) & mask
    }

    // MARK: システム命令（MSR / MRS / SYS）

    private func executeSystem(_ insn: UInt32, at instructionPC: UInt64) throws {
        let isRead = (insn >> 21) & 1 == 1     // L: 1 = MRS（読み）、0 = MSR（書き）
        let rt = Int(insn & 0x1F)
        let op0 = Int((insn >> 19) & 0x3)
        let op1 = Int((insn >> 16) & 0x7)
        let crn = Int((insn >> 12) & 0xF)
        let crm = Int((insn >> 8) & 0xF)
        let op2 = Int((insn >> 5) & 0x7)

        // MSR（即値）: PSTATE フィールド（CRn = 4、Rt = 31）
        if !isRead && crn == 4 && rt == 31 {
            let imm4 = crm
            switch (op1, op2) {
            case (0, 5):  // SPSel
                if imm4 & 1 != 0 { pstate |= 0x1 } else { pstate &= ~0x1 }
            case (3, 6):  // DAIFSet
                for i in 0..<4 where (imm4 >> i) & 1 == 1 { pstate |= UInt32(1 << (6 + i)) }
            case (3, 7):  // DAIFClr
                for i in 0..<4 where (imm4 >> i) & 1 == 1 { pstate &= ~UInt32(1 << (6 + i)) }
            default:
                break
            }
            return
        }
        // SYS 命令（TLBI / キャッシュ保守など）は、変換を毎回行うため無動作で正しい
        if !isRead && op0 <= 1 { return }

        let key = (op0 << 13) | (op1 << 10) | (crn << 6) | (crm << 3) | op2
        if isRead {
            writeReg(rt, readSysReg(key))
        } else {
            writeSysReg(key, readReg(rt))
        }
    }

    private func readSysReg(_ key: Int) -> UInt64 {
        switch key {
        case 0x6040: return sctlrEL1
        case 0x6080: return ttbr0EL1
        case 0x6081: return ttbr1EL1
        case 0x6082: return tcrEL1
        case 0x6290: return mairEL1
        case 0x6300: return vbarEL1
        case 0x6100: return UInt64(spsrEL1)
        case 0x6101: return elrEL1
        case 0x6150: return esrEL1
        case 0x6180: return farEL1
        case 0x6108: return spEL0
        case 0x7108: return spEL1
        case 0x6112: return UInt64(currentEL) << 2          // CurrentEL
        case 0x6D10: return UInt64(pstate & 0xF000_0000)    // NZCV
        case 0x6D11: return UInt64((pstate >> 6) & 0xF) << 6  // DAIF
        case 0x6000: return 0x410F_D034                     // MIDR（仮の実装値）
        case 0x6005: return 0x8000_0000                     // MPIDR（単一コア）
        case 0x6038: return 0x0FF0_0022                     // ID_AA64MMFR0（4K 対応 / 40 ビット PA / 16 ビット ASID）
        case 0x6F80: return timerFrequency                  // CNTFRQ_EL0
        case 0x6F81, 0x6F82: return counterValue()          // CNTPCT / CNTVCT
        case 0x6F90, 0x6FA8:                                // CNTP_TVAL / CNTV_TVAL
            return UInt64(UInt32(truncatingIfNeeded: cntpCval &- counterValue()))
        case 0x6F91, 0x6FA9:                                // CNTP_CTL / CNTV_CTL
            return (cntpCtl & 0x3) | (timerExpired ? 0x4 : 0)
        case 0x6F92, 0x6FAA: return cntpCval                // CNTP_CVAL / CNTV_CVAL
        default: return 0
        }
    }

    private func writeSysReg(_ key: Int, _ value: UInt64) {
        switch key {
        case 0x6040: sctlrEL1 = value
        case 0x6080: ttbr0EL1 = value
        case 0x6081: ttbr1EL1 = value
        case 0x6082: tcrEL1 = value
        case 0x6290: mairEL1 = value
        case 0x6300: vbarEL1 = value
        case 0x6100: spsrEL1 = UInt32(value & 0xFFFF_FFFF)
        case 0x6101: elrEL1 = value
        case 0x6150: esrEL1 = value
        case 0x6180: farEL1 = value
        case 0x6108: spEL0 = value
        case 0x7108: spEL1 = value
        case 0x6D10:  // NZCV
            var flags = pstate & 0x0FFF_FFFF
            flags |= UInt32(value & 0xF000_0000)
            pstate = flags
        case 0x6D11:  // DAIF
            pstate = (pstate & ~0x3C0) | (UInt32(value) & 0x3C0)
        case 0x6F90, 0x6FA8:  // TVAL: 現在値 + 符号拡張した 32 ビット
            cntpCval = counterValue() &+ UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(value & 0xFFFF_FFFF))))
        case 0x6F91, 0x6FA9: cntpCtl = value & 0x3
        case 0x6F92, 0x6FAA: cntpCval = value
        default: break
        }
    }

    // MARK: SVC（コンソールサービス / 例外）

    private func executeSVC(imm: Int, at instructionPC: UInt64) throws {
        switch imm {
        case 1:  // putchar
            onChar?(UInt8(registers[0] & 0xFF))
        case 2:  // print int（符号付き 64 ビット）
            for byte in String(Int64(bitPattern: registers[0])).utf8 { onChar?(byte) }
        case 3:  // print string
            var address = registers[0]
            var safety = 0
            while safety < 1_000_000 {
                let byte = try loadValue(address: address, size: 1)
                if byte == 0 { break }
                onChar?(UInt8(byte))
                address &+= 1
                safety += 1
            }
        case 4:  // getchar
            inputLock.lock()
            if let byte = inputQueue.first {
                inputQueue.removeFirst()
                inputLock.unlock()
                registers[0] = UInt64(byte)
            } else {
                inputLock.unlock()
                pc = instructionPC
                waitingForInput = true
            }
        case 5:
            onClearScreen?()
        case 6:  // random（xorshift32）
            randomState ^= randomState << 13
            randomState ^= randomState >> 17
            randomState ^= randomState << 5
            registers[0] = UInt64(randomState)
        case 10:  // exit
            halted = true
            exitCode = Int32(bitPattern: UInt32(registers[0] & 0xFFFF_FFFF))
        default:
            // それ以外の SVC は EL1 への同期例外として配送する（ELR は次の命令）
            raiseSync(ec: 0x15, iss: UInt64(imm), elr: pc)
        }
    }
}
