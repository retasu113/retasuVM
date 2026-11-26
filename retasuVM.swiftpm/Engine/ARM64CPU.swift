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
        case vmApple
    }
    var platform: Platform = .gic

    // MARK: - 状態

    var registers = [UInt64](repeating: 0, count: 31)   // X0...X30
    /// FP/SIMD レジスタファイル（V0...V31、各 128 ビットを lo/hi の 2 ワードで保持）
    var fpRegisters = [UInt64](repeating: 0, count: 64)
    var fpsr: UInt32 = 0
    var fpcr: UInt32 = 0
    private(set) var pc: UInt64 = 0
    var spEL0: UInt64 = 0
    var tpidrEL0: UInt64 = 0      // TPIDR_EL0（S3_3_C13_C0_2）: executeSystem で専用に振り分け
    var tpidrROEL0: UInt64 = 0    // TPIDRRO_EL0（S3_3_C13_C0_3、読み取り専用）
    var spEL1: UInt64 = 0
    /// PSTATE（SPSR 形式: NZCV[31:28] / DAIF[9:6] / EL[3:2] / SPSel[0]）
    var pstate: UInt32 = 0x3C5                            // EL1h, 全割り込みマスク
    private(set) var halted = false
    /// 実行した命令数（診断用）
    private(set) var instructionsExecuted: UInt64 = 0
    /// システムレジスタアクセスの診断フック（isRead, key, value, pc）
    var onSysRegAccess: ((Bool, Int, UInt64, UInt64) -> Void)?
    /// 例外配送フック（vector, esr, elr）
    var onException: ((UInt64, UInt64, UInt64) -> Void)?
    /// 命令フェッチフック（pc, insn）
    var onFetch: ((UInt64, UInt32) -> Void)?
    /// 例外配送の診断カウンタ（ベクタオフセット → 回数）と最終例外の内容
    private(set) var exceptionCounts: [UInt64: Int] = [:]
    private(set) var lastExceptionESR: UInt64 = 0
    private(set) var lastExceptionELR: UInt64 = 0
    private(set) var lastExceptionVector: UInt64 = 0
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
    var parEL1: UInt64 = 0

    // システムレジスタ（EL2、VMAPPLE の VHE カーネル用）
    var sctlrEL2: UInt64 = 0
    var tcrEL2: UInt64 = 0
    var ttbr0EL2: UInt64 = 0
    var ttbr1EL2: UInt64 = 0
    var mairEL2: UInt64 = 0
    var vbarEL2: UInt64 = 0
    var elrEL2: UInt64 = 0
    var spsrEL2: UInt32 = 0
    var esrEL2: UInt64 = 0
    var farEL2: UInt64 = 0
    var hcrEL2: UInt64 = 0
    var spEL2: UInt64 = 0

    /// 実効 RAM ベース（プラットフォームで切替。既定は従来の 0x4000_0000）
    var ramBaseAddress: UInt64 = ARM64CPU.ramBase
    /// 未実装システムレジスタの汎用ストレージ（VMAPPLE 用）
    private var sysRegStorage: [Int: UInt64] = [:]

    // VMAPPLE デバイス配置
    var gic3: GICv3? = nil
    private var vmGICDistPA: UInt64 = 0
    private var vmGICRedistPA: UInt64 = 0
    private var vmUARTPA: UInt64 = 0
    /// AVPBooter ROM イメージ（0x0010_0000 に RAM としてマップ。ROM 起動時のみ）
    var romData: [UInt8] = []
    /// vmapple cfg ウィンドウ（0x0040_0000 から 1 MiB。先頭 64 KiB が構造体、残りは RAM）
    var cfgWindow: [UInt8] = []
    /// cfg `rnd` レジスタ用 xorshift 状態（読むたびに新しい乱数を返す）
    private var cfgRNGState: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// bdif（0x3000_0000、2 MiB）に接続された root / aux ディスク
    var bdifRootDisk: BdifDisk? = nil
    var bdifAuxDisk: BdifDisk? = nil
    /// VMAPPLE PCIe バスと virtio デバイス（ディスク接続時に生成）
    var pcieBus: PcieBus? = nil
    var vmAuxBlk: VirtioBlk? = nil
    var vmRootBlk: VirtioBlk? = nil
    var vmUsbDev: VirtioUsbDevice? = nil
    /// 未知の arm-io アクセス記録（診断用、先頭のみ保持）
    private(set) var unknownMMIOAccesses: [UInt64] = []

    // ジェネリックタイマ（物理カウンタ）
    private var timerFrequency: UInt64 = 62_500_000
    /// [p28 FIX] Monotonic epoch for counterValue() (DispatchTime =
    /// CLOCK_MONOTONIC). The old implementation used Date() (the host
    /// wall clock); WSL2 host clock steps rewound the guest counter
    /// and fired XNU's Non-monotonic-time panic (phase 28). QEMU uses
    /// CLOCK_MONOTONIC, Henge uses mach_absolute_time().
    private let timerEpochMonoNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    /// ゲスト時間の進む速さ（1.0 = 実時間）。大きくするとゲスト側の待ち・
    /// タイムアウトが短縮される（時短用）。カウンタの全読み出しは
    /// counterValue() 経由なので、ここを掛けるだけで一貫する。
    public var timeScale: Double = 1.0
    private var cntpCval: UInt64 = UInt64.max
    private var cntpCtl: UInt64 = 0                       // bit0 ENABLE, bit1 IMASK
    private var cntvCval: UInt64 = UInt64.max
    private var cntvCtl: UInt64 = 0
    private var cntvOff: UInt64 = 0                       // CNTVOFF_EL2

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
            if currentEL == 2 { return spSel ? spEL2 : spEL0 }
            return spSel ? spEL1 : spEL0
        }
        set {
            if currentEL == 0 { spEL0 = newValue }
            else if currentEL == 2 { if spSel { spEL2 = newValue } else { spEL0 = newValue } }
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
        guard address >= ramBaseAddress else { return }
        let offset = Int(address - ramBaseAddress)
        guard offset + bytes.count <= memory.count else { return }
        memory.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        pc = address
        spEL1 = ramBaseAddress + UInt64(memorySize) - 0x1000
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
            guard vaddr >= ramBaseAddress else {
                throw ARM64Fault.invalidELF("セグメントが RAM の範囲外です")
            }
            let dest = Int(vaddr - ramBaseAddress)
            guard dest + memSize <= memory.count, fileOff + fileSize <= data.count else {
                throw ARM64Fault.invalidELF("セグメントが RAM の範囲外です")
            }
            for j in 0..<memSize {
                memory[dest + j] = j < fileSize ? data[fileOff + j] : 0
            }
        }
        pc = entry
        spEL1 = ramBaseAddress + UInt64(memorySize) - 0x1000
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
                // WFI 中: 割り込みが「保留」になったら復帰し、来ていなければ呼び出しを返す。
                // 起床条件はマスク非依存（保留状態のみで判定）。DAIF マスクは例外の
                // 「配送」だけをゲートし、起床はゲートしない — Henge core/dispatch.c
                // wait_for_interrupt()（"pending, masked or not"）と QEMU
                // target/arm/cpu.c arm_cpu_has_work()（配送判定は
                // arm_cpu_exec_interrupt() が別途行う）と同じ分離。
                // 配送側のゲートは step() が従来どおり行う。
                if platform == .vmApple {
                    if vmAppleFIQPending || vmAppleIRQPending { idle = false } else { break }
                } else if platform == .appleSilicon {
                    if fiqPending { idle = false } else { break }
                } else if interruptPending { idle = false } else { break }
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
        // [p28 FIX] Monotonic time source (see timerEpochMonoNs). The
        // wall clock must never feed the guest counter: a host clock
        // step backwards rewinds CNTVCT/CNTPCT and XNU panics with
        // "Non-monotonic time" (check_monotonic_time, thread_unblock).
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- timerEpochMonoNs
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        return UInt64(elapsed * timeScale * Double(timerFrequency))
    }

    private func gicEnabled(_ intid: UInt64) -> Bool {
        gicDistEnabled && gicCPUEnabled && (gicEnabledINTIDs >> intid) & 1 == 1 && gicPriorityMask != 0
    }

    // MARK: - ステップ実行

    private func step() throws {
        // 割り込みは命令境界で受け付ける（ELR は次に実行する命令を指す）
        if platform == .vmApple {
            if vmAppleFIQPending && !fiqMasked {
                enterException(vectorOffset: fiqVectorOffset(), elr: pc, esr: 0)
            } else if vmAppleIRQPending && !irqMasked {
                enterException(vectorOffset: irqVectorOffset(), elr: pc, esr: 0)
            }
        } else if platform == .appleSilicon {
            if fiqPending && !fiqMasked {
                enterException(vectorOffset: fiqVectorOffset(), elr: pc, esr: 0)
            }
        } else if interruptPending && !irqMasked {
            enterException(vectorOffset: irqVectorOffset(), elr: pc, esr: 0)
        }
        instructionsExecuted &+= 1
        let instructionPC = pc
        do {
            let insn = try fetch32(at: instructionPC)
            onFetch?(instructionPC, insn)
            pc = instructionPC &+ 4
            if decodeCacheEnabled {
                try executeCached(insn, at: instructionPC)
            } else {
                try execute(insn, at: instructionPC)
            }
        } catch let abort as AbortSignal {
            // データ / 命令アボートは例外として配送する（セッションは継続）
            let target = exceptionTargetEL
            if target == 2 { farEL2 = abort.address } else { farEL1 = abort.address }
            let fromLower = currentEL < target
            let ec: UInt64 = abort.isInstruction ? (fromLower ? 0x20 : 0x21) : (fromLower ? 0x24 : 0x25)
            enterException(vectorOffset: syncVectorOffset(), elr: instructionPC, esr: (ec << 26) | (1 << 25) | (abort.isWrite ? (1 << 6) : 0) | abort.fsc)
        }
    }

    /// 命令アボート / データアボートの内部シグナル。
    private struct AbortSignal: Error {
        var address: UInt64
        var isInstruction: Bool
        var isWrite: Bool = false
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

    /// 例外の配送先 EL（現在の EL が EL2 のときは EL2、それ以外は EL1）。
    private var exceptionTargetEL: Int {
        if currentEL == 2 { return 2 }
        return 1
    }

    /// 例外をターゲット EL へ配送する（ELR / ESR を設定し、SPSR へ現在の PSTATE を退避）。
    private func enterException(vectorOffset: UInt64, elr: UInt64, esr: UInt64) {
        exceptionCounts[vectorOffset, default: 0] += 1
        onException?(vectorOffset, esr, elr)
        lastExceptionESR = esr
        lastExceptionELR = elr
        lastExceptionVector = vectorOffset
        let target = exceptionTargetEL
        if target == 2 {
            esrEL2 = esr
            elrEL2 = elr
            spsrEL2 = pstate
        } else {
            esrEL1 = esr
            elrEL1 = elr
            spsrEL1 = pstate
        }
        // 例外突入: ターゲット EL / SP_ELx を使い、割り込みをマスクする
        var newState = pstate
        newState = (newState & 0xFFFF_FF00) | 0x3C0 | (UInt32(target) << 2) | 0x01
        // 例外突入時の PAN / UAO（ARM ARM の TakeException 規則。QEMU
        // target/arm/helper.c aarch64_cpu_do_interrupt および Henge
        // core/exception.c hv_take_exception と同一セマンティクス）:
        //   UAO は例外突入で常に 0 になる。
        //   PAN は通常は保持されるが、ターゲットが EL1、または
        //   HCR_EL2.{E2H,TGE}={1,1} を満たす EL2 で、対象 EL の
        //   SCTLR.SPAN（bit 23）が 0 のときは 1 にセットされる。
        // XNU は SCTLR_EL1.SPAN=0 をプログラムし、「例外突入で PAN=1」
        // を前提に machine_switch_context が PAN を検証する
        // （osfmk/arm64/pcb.c）。この規則がないと、EL0 往復後や
        // copyio 等の PAN=0 区間で取った例外の先の文脈切替で
        // "context switch with PAN disabled" panic になる（phase 18）。
        newState &= ~(1 << 23)   // UAO := 0
        if target == 1 {
            if (sctlrEL1 >> 23) & 1 == 0 { newState |= (1 << 22) }   // PAN := 1
        } else if target == 2 {
            if (hcrEL2 >> 34) & 1 == 1 && (hcrEL2 >> 27) & 1 == 1 && (sctlrEL2 >> 23) & 1 == 0 {
                newState |= (1 << 22)   // PAN := 1
            }
        }
        pstate = newState
        let vbar = target == 2 ? vbarEL2 : vbarEL1
        pc = (vbar & ~0x7FF) &+ vectorOffset
    }

    /// 同期例外（SVC / 未定義命令など）。ELR は呼び出し側で決める。
    private func raiseSync(ec: UInt64, iss: UInt64, elr: UInt64) {
        enterException(vectorOffset: syncVectorOffset(), elr: elr, esr: (ec << 26) | (1 << 25) | (iss & 0x1FF_FFFF))
    }

    private func eret() {
        if currentEL == 2 {
            pc = elrEL2
            pstate = spsrEL2
        } else {
            pc = elrEL1
            pstate = spsrEL1
        }
    }

    // MARK: - メモリアクセス（MMU + 物理）

    private func fetch32(at address: UInt64) throws -> UInt32 {
        let physical = try translate(address: address, isWrite: false, isFetch: true)
        return try readPhysical32(physical)
    }

    /// 変換レジーム（SCTLR / TCR / TTBR の組と TCR 形式）。
    private struct TranslationRegime {
        var sctlr: UInt64
        var tcr: UInt64
        var ttbr0: UInt64
        var ttbr1: UInt64?
        var el1Format: Bool   // TCR が EL1 形式（T1SZ / TG1 を持つ）か
    }

    private func currentRegime() -> TranslationRegime {
        if currentEL == 2 {
            // VMAPPLE のカーネルは EL2（VHE）。EL2 ストレージが実効レジームで、
            // E2H 有効時は TTBR1 と EL1 形式 TCR を使う。
            let e2h = (hcrEL2 >> 34) & 1 == 1
            return TranslationRegime(sctlr: sctlrEL2, tcr: tcrEL2, ttbr0: ttbr0EL2,
                                     ttbr1: e2h ? ttbr1EL2 : nil, el1Format: e2h)
        }
        return TranslationRegime(sctlr: sctlrEL1, tcr: tcrEL1, ttbr0: ttbr0EL1, ttbr1: ttbr1EL1, el1Format: true)
    }

    /// ステージ 1 変換（4 KB / 16 KB / 64 KB グラニュール、TTBR0 / TTBR1）。
    /// MMU 無効時は恒等変換。失敗時は AbortSignal を投げる。
    private func translate(address: UInt64, isWrite: Bool, isFetch: Bool) throws -> UInt64 {
        let regime = currentRegime()
        guard regime.sctlr & 0x1 != 0 else { return address }
        let t0sz = Int(regime.tcr & 0x3F)
        let t1sz = regime.el1Format ? Int((regime.tcr >> 16) & 0x3F) : 64
        // TTBR1 領域: VA の上位ビットが（TTBR1 の VA サイズより上が）すべて 1
        var useTTBR1 = false
        if regime.ttbr1 != nil && t1sz < 64 {
            let vaBits1 = 64 - t1sz
            if vaBits1 < 64 && (address >> vaBits1) == (UInt64.max >> vaBits1) {
                useTTBR1 = true
            }
        }
        let vaBits = 64 - (useTTBR1 ? t1sz : t0sz)
        guard vaBits >= 25, vaBits <= 48 else {
            throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b000100)
        }
        // VA の範囲検査（TTBR0 側は上位ビットが 0、TTBR1 側は 1 でなければならない）
        if useTTBR1 {
            guard address >> vaBits == (UInt64.max >> vaBits) else {
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b000100)
            }
        } else {
            guard address >> vaBits == 0 else {
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b000100)
            }
        }
        // グラニュール: TG0 は TCR[15:14]（0=4K, 1=64K, 2=16K）、TG1 は TCR[31:30]（1=16K, 2=64K, 3=4K）
        let pageShift: Int
        if useTTBR1 {
            switch Int((regime.tcr >> 30) & 0x3) {
            case 1: pageShift = 14
            case 2: pageShift = 16
            default: pageShift = 12
            }
        } else {
            switch Int((regime.tcr >> 14) & 0x3) {
            case 1: pageShift = 16
            case 2: pageShift = 14
            default: pageShift = 12
            }
        }
        let indexBits = pageShift - 3
        let oaMask = UInt64(0x0000_FFFF_FFFF_FFFF) & ~((UInt64(1) << pageShift) - 1)
        var tableBase = (useTTBR1 ? regime.ttbr1! : regime.ttbr0) & oaMask
        let levelCount = (vaBits - pageShift + indexBits - 1) / indexBits
        let startLevel = 4 - levelCount
        let topIndexBits = vaBits - pageShift - (levelCount - 1) * indexBits
        var level = startLevel
        var pa: UInt64 = 0
        walk: while true {
            let shift = pageShift + (3 - level) * indexBits
            let bitsHere = level == startLevel ? topIndexBits : indexBits
            let index = Int((address >> shift) & ((UInt64(1) << bitsHere) - 1))
            let descAddress = tableBase &+ UInt64(index * 8)
            let desc = try readTableEntry(descAddress)
            let kind = desc & 0x3
            if kind == 0 || kind == 2 {
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b000100 | UInt64(level))
            }
            if kind == 1 {
                // ブロック記述子（レベル 1 / 2 のみ）
                guard level == 1 || level == 2 else {
                    throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b000100 | UInt64(level))
                }
                try checkPermissions(desc: desc, isWrite: isWrite, isFetch: isFetch, level: level, address: address)
                let mask = (UInt64(1) << shift) - 1
                pa = (desc & oaMask & ~mask) | (address & mask)
                break walk
            }
            // テーブル記述子 or ページ記述子
            if level == 3 {
                try checkPermissions(desc: desc, isWrite: isWrite, isFetch: isFetch, level: level, address: address)
                pa = (desc & oaMask) | (address & ((UInt64(1) << pageShift) - 1))
                break walk
            }
            tableBase = desc & oaMask
            level += 1
        }
        return pa
    }

    private func checkPermissions(desc: UInt64, isWrite: Bool, isFetch: Bool, level: Int, address: UInt64) throws {
        // アクセスフラグ（bit 10）が立っていなければアクセスフラグフォールト
        if desc & (1 << 10) == 0 {
            throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b001000 | UInt64(level))
        }
        let el0Access = desc & (1 << 6) != 0          // AP[1]
        let readOnly = desc & (1 << 7) != 0           // AP[2]
        if currentEL == 0 {
            if !el0Access {
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b001100 | UInt64(level))
            }
            if isWrite && readOnly {
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b001100 | UInt64(level))
            }
            if isFetch && desc & (1 << 54) != 0 {     // UXN
                throw AbortSignal(address: address, isInstruction: true, isWrite: false, fsc: 0b001100 | UInt64(level))
            }
        } else {
            if isWrite && readOnly {
                // EL1 からの書き込み: AP[2] = 1（AP 0b10 / 0b11）は読み取り専用
                throw AbortSignal(address: address, isInstruction: isFetch, isWrite: isWrite, fsc: 0b001100 | UInt64(level))
            }
            if isFetch && desc & (1 << 53) != 0 {     // PXN
                throw AbortSignal(address: address, isInstruction: true, isWrite: false, fsc: 0b001100 | UInt64(level))
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
        if pa >= ramBaseAddress && pa < ramBaseAddress + UInt64(memorySize) {
            return memory[Int(pa - ramBaseAddress)]
        }
        return UInt8(try readMMIO(pa, size: 1) & 0xFF)
    }

    /// RAM 範囲内のオフセット（アドレス加算のラップアラウンドを避けた安全な判定）。
    private func ramOffset(_ pa: UInt64, size: Int) -> Int? {
        guard pa >= ramBaseAddress, size >= 0 else { return nil }
        let off = pa - ramBaseAddress
        guard off <= UInt64(memorySize), UInt64(size) <= UInt64(memorySize) - off else { return nil }
        return Int(off)
    }

    private func readPhysical32(_ pa: UInt64) throws -> UInt32 {
        if let o = ramOffset(pa, size: 4) {
            return UInt32(memory[o]) | UInt32(memory[o + 1]) << 8 | UInt32(memory[o + 2]) << 16 | UInt32(memory[o + 3]) << 24
        }
        return UInt32(try readMMIO(pa, size: 4) & 0xFFFF_FFFF)
    }

    private func readPhysical(_ pa: UInt64, size: Int) throws -> UInt64 {
        if let o = ramOffset(pa, size: size) {
            var value: UInt64 = 0
            for i in 0..<size { value |= UInt64(memory[o + i]) << (8 * i) }
            return value
        }
        return try readMMIO(pa, size: size)
    }

    private func writePhysical(_ pa: UInt64, size: Int, _ value: UInt64) throws {
        if let o = ramOffset(pa, size: size) {
            for i in 0..<size { memory[o + i] = UInt8((value >> (8 * i)) & 0xFF) }
            return
        }
        try writeMMIO(pa, size: size, value)
    }

    private func readMMIO(_ pa: UInt64, size: Int) throws -> UInt64 {
        if platform == .vmApple {
            if !romData.isEmpty && pa >= 0x0010_0000 && pa < 0x0020_0000 {
                // AVPBooter ROM（QEMU/Henge とも RAM としてマップ）
                var v: UInt64 = 0
                let o = Int(pa - 0x0010_0000)
                for i in 0..<size where o + i < romData.count { v |= UInt64(romData[o + i]) << (8 * i) }
                return v
            }
            if !cfgWindow.isEmpty && pa >= 0x0040_0000 && pa < 0x0050_0000 {
                return cfgRead(offset: pa - 0x0040_0000, size: size)
            }
            if pa >= 0x3000_0000 && pa < 0x3020_0000 {
                return bdifRead(offset: pa - 0x3000_0000)
            }
            if pa >= 0x3020_0000 && pa < 0x3021_0000 {
                return pvgGfxRead(offset: pa - 0x3020_0000)
            }
            if pa >= 0x3021_0000 && pa < 0x3022_0000 {
                return pvgIosfcRead(offset: pa - 0x3021_0000)
            }
            if pa >= 0x3022_0000 && pa < 0x3022_0000 + 0x4000 {
                return aesRead(offset: pa - 0x3022_0000)
            }
            if pa >= 0x3023_0000 && pa < 0x3023_0000 + 0x4000 {
                return 0 // AES 第2ウィンドウ: QEMU/Henge とも読みは 0
            }
            if let bus = pcieBus {
                if pa >= PcieBus.ecamBase && pa < PcieBus.ecamBase + 0x1000_0000 {
                    return bus.ecamRead(offset: pa - PcieBus.ecamBase, size: size)
                }
                if pa >= PcieBus.mmioBase && pa < PcieBus.mmioBase + PcieBus.mmioSize {
                    return bus.windowRead(offset: pa - PcieBus.mmioBase, size: size)
                }
            }
            if let gic = gic3 {
                if pa >= vmGICDistPA && pa < vmGICDistPA + 0x10000 {
                    return gic.distRead(offset: pa - vmGICDistPA)
                }
                if pa >= vmGICRedistPA && pa < vmGICRedistPA + 0x20000 {
                    return gic.redistRead(offset: pa - vmGICRedistPA)
                }
            }
            if pa >= 0x1FFF_0000 && pa < 0x1FFF_0000 + 0x10000 {
                return gicMsiRead(offset: pa - 0x1FFF_0000)
            }
            if pa >= 0x2005_0000 && pa < 0x2005_0000 + 0x1000 {
                return pl031Read(offset: pa - 0x2005_0000)
            }
            if pa >= 0x3024_0000 && pa < 0x3024_0000 + 0x4000 {
                return rtcSelectRead(offset: pa - 0x3024_0000, size: size)
            }
            if pa >= vmUARTPA && pa < vmUARTPA + 0x10000 {
                return vmPL011Read(offset: pa - vmUARTPA)
            }
            if pa == VMAppleBoot.armIOBase + 0x10070000 {
                return 0 // pvpanic
            }
            if pa >= VMAppleBoot.armIOBase + 0x30000000 && pa < VMAppleBoot.armIOBase + 0x40000000 {
                return UInt64.max // PCIe 設定空間: デバイスなし
            }
            if pa >= VMAppleBoot.armIOBase && pa < VMAppleBoot.armIOBase + 0x7000_0000 {
                noteUnknownMMIO(pa)
                return 0
            }
        }
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
        if platform == .vmApple {
            if !romData.isEmpty && pa >= 0x0010_0000 && pa < 0x0020_0000 {
                let o = Int(pa - 0x0010_0000)
                for i in 0..<size where o + i < romData.count { romData[o + i] = UInt8((value >> (8 * i)) & 0xFF) }
                return
            }
            if !cfgWindow.isEmpty && pa >= 0x0040_0000 && pa < 0x0050_0000 {
                cfgWrite(offset: pa - 0x0040_0000, size: size, value: value)
                return
            }
            if pa >= 0x3000_0000 && pa < 0x3020_0000 {
                bdifWrite(offset: pa - 0x3000_0000, value: value)
                return
            }
            if pa >= 0x3020_0000 && pa < 0x3021_0000 {
                pvgGfxWrite(offset: pa - 0x3020_0000, value: value)
                return
            }
            if pa >= 0x3021_0000 && pa < 0x3022_0000 {
                pvgIosfcWrite(offset: pa - 0x3021_0000, value: value)
                return
            }
            if pa >= 0x3022_0000 && pa < 0x3022_0000 + 0x4000 {
                aesWrite(offset: pa - 0x3022_0000, value: value)
                return
            }
            if pa >= 0x3023_0000 && pa < 0x3023_0000 + 0x4000 {
                return // AES 第2ウィンドウ: 書き込みは無視（QEMU/Henge 同様）
            }
            if let bus = pcieBus {
                if pa >= PcieBus.ecamBase && pa < PcieBus.ecamBase + 0x1000_0000 {
                    bus.ecamWrite(offset: pa - PcieBus.ecamBase, value: value, size: size)
                    return
                }
                if pa >= PcieBus.mmioBase && pa < PcieBus.mmioBase + PcieBus.mmioSize {
                    bus.windowWrite(offset: pa - PcieBus.mmioBase, value: value, size: size)
                    return
                }
            }
            if let gic = gic3 {
                if pa >= vmGICDistPA && pa < vmGICDistPA + 0x10000 {
                    gic.distWrite(offset: pa - vmGICDistPA, value: value, size: size)
                    return
                }
                if pa >= vmGICRedistPA && pa < vmGICRedistPA + 0x20000 {
                    gic.redistWrite(offset: pa - vmGICRedistPA, value: value, size: size)
                    return
                }
            }
            if pa >= 0x1FFF_0000 && pa < 0x1FFF_0000 + 0x10000 {
                gicMsiWrite(offset: pa - 0x1FFF_0000, value: value)
                return
            }
            if pa >= 0x2005_0000 && pa < 0x2005_0000 + 0x1000 {
                pl031Write(offset: pa - 0x2005_0000, value: value)
                return
            }
            if pa >= 0x3024_0000 && pa < 0x3024_0000 + 0x4000 {
                rtcSelectWrite(offset: pa - 0x3024_0000, value: value)
                return
            }
            if pa >= vmUARTPA && pa < vmUARTPA + 0x10000 {
                vmPL011Write(offset: pa - vmUARTPA, value: value)
                return
            }
            if pa == VMAppleBoot.armIOBase + 0x10070000 {
                // pvpanic: ゲストパニック通知。エミュレーションを停止する。
                if value & 1 != 0 {
                    halted = true
                    exitCode = 0x5041_4E49 // 'PANI'
                }
                return
            }
            if pa >= VMAppleBoot.armIOBase + 0x30000000 && pa < VMAppleBoot.armIOBase + 0x40000000 {
                return // PCIe 設定空間（未実装デバイス分は無視）
            }
            if pa >= VMAppleBoot.armIOBase && pa < VMAppleBoot.armIOBase + 0x7000_0000 {
                noteUnknownMMIO(pa)
                return
            }
        }
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

    // MARK: VMAPPLE 補助（未知 MMIO 記録 / Samsung UART）

    private func noteUnknownMMIO(_ pa: UInt64) {
        if unknownMMIOAccesses.count < 128 && !unknownMMIOAccesses.contains(pa) {
            unknownMMIOAccesses.append(pa)
        }
    }

    /// Samsung S5L 系 UART（AppleSamsungSerial / PE 早期コンソール用レジスタ配置）。
    private var samsungUARTStorage: [UInt64: UInt64] = [:]

    private func samsungUARTRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x10:  // UTRSTAT: bit0 = RX データあり, bit1 = TX バッファ空, bit2 = TX 空
            return 0x6 | (inputQueueEmpty ? 0 : 1)
        case 0x14:  // UERSTAT
            return 0
        case 0x18:  // UFSTAT: RX FIFO 件数 [5:0]
            inputLock.lock()
            let count = inputQueue.count
            inputLock.unlock()
            return UInt64(min(count, 63))
        case 0x1C:  // UMSTAT
            return 0
        case 0x24:  // URXH
            inputLock.lock()
            defer { inputLock.unlock() }
            if inputQueue.isEmpty { return 0 }
            return UInt64(inputQueue.removeFirst())
        case 0x30:  // UINTP: bit0 = TX 完了, bit1 = RX あり
            return 0x1 | (inputQueueEmpty ? 0 : 0x2)
        default:
            return samsungUARTStorage[offset] ?? 0
        }
    }

    private func samsungUARTWrite(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x20:  // UTXH
            onChar?(UInt8(value & 0xFF))
        case 0x30:  // UINTP（書き込みクリア。状態は保持しない）
            break
        default:
            samsungUARTStorage[offset] = value
        }
    }

    // MARK: VMAPPLE cfg（QEMU hw/vmapple/cfg.c + Henge devices/cfg.c の実レイアウト）

    private func cfgRead(offset: UInt64, size: Int) -> UInt64 {
        if offset == 0x38 {
            // rnd: boot ROM がバッファを乱数で埋めるために読むたび新しい値を返す
            cfgRNGState ^= cfgRNGState << 13
            cfgRNGState ^= cfgRNGState >> 7
            cfgRNGState ^= cfgRNGState << 17
            if size >= 4 { return cfgRNGState & 0xFFFF_FFFF }
            return cfgRNGState & ((UInt64(1) << (size * 8)) - 1)
        }
        var v: UInt64 = 0
        let o = Int(offset)
        for i in 0..<size where o + i < cfgWindow.count { v |= UInt64(cfgWindow[o + i]) << (8 * i) }
        return v
    }

    private func cfgWrite(offset: UInt64, size: Int, value: UInt64) {
        let o = Int(offset)
        for i in 0..<size where o + i < cfgWindow.count { cfgWindow[o + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    // MARK: bdif（VMApple Backdoor Interface、QEMU hw/vmapple/bdif.c の再現）
    // ROM と iBoot がディスクを読むためのチャネル。devid = offset & 0xFFFF0000
    // （ROOT=0x00000 / AUX=0x10000 / USB=0x100000）、reg = offset & 0xFFFF。

    /// bdif に root / aux ディスクイメージ（メモリ）を接続する。
    func attachBdifDisks(root: [UInt8], aux: [UInt8]) {
        bdifRootDisk = BdifDisk(memory: root)
        bdifAuxDisk = BdifDisk(memory: aux)
        setupPCIeIfNeeded()
    }

    /// bdif に root / aux ディスクファイル（スパース可）を接続する。
    func attachBdifDiskFiles(rootPath: String, rootSize: Int, auxPath: String, auxSize: Int) {
        bdifRootDisk = BdifDisk(fileAt: rootPath, size: rootSize)
        bdifAuxDisk = BdifDisk(fileAt: auxPath, size: auxSize)
        setupPCIeIfNeeded()
    }

    /// ゲスト物理メモリのバイト列読み（virtio のリング/バッファ用。RAM は直接、それ以外は MMIO 経由）
    func physReadBytes(_ pa: UInt64, _ count: Int) -> [UInt8]? {
        if pa >= ramBaseAddress && pa + UInt64(count) <= ramBaseAddress + UInt64(memory.count) {
            let o = Int(pa - ramBaseAddress)
            return [UInt8](memory[o..<o + count])
        }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var done = 0
        while done < count {
            let n = min(8, count - done)
            guard let v = try? readPhysical(pa + UInt64(done), size: n) else { return nil }
            for i in 0..<n { out.append(UInt8((v >> UInt64(8 * i)) & 0xFF)) }
            done += n
        }
        return out
    }

    /// ゲスト物理メモリへのバイト列書き込み
    func physWriteBytes(_ pa: UInt64, _ bytes: [UInt8]) {
        if pa >= ramBaseAddress && pa + UInt64(bytes.count) <= ramBaseAddress + UInt64(memory.count) {
            writeGuestMemory(bytes, at: pa)
            return
        }
        var done = 0
        while done < bytes.count {
            let n = min(8, bytes.count - done)
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(bytes[done + i]) << UInt64(8 * i) }
            try? writePhysical(pa + UInt64(done), size: n, v)
            done += n
        }
    }

    /// PCIe バスと virtio デバイス（aux blk → root blk → usb）を構築する（Henge の接続順）。
    private func setupPCIeIfNeeded() {
        guard platform == .vmApple, pcieBus == nil else { return }
        guard bdifRootDisk != nil || bdifAuxDisk != nil else { return }
        let bus = PcieBus()
        bus.setIRQ = { [weak self] intid, level in self?.gic3?.setSPILevel(intid, level) }
        pcieBus = bus
        func wire(_ v: VirtioDevice) {
            v.physRead = { [weak self] pa, n in self?.physReadBytes(pa, n) }
            v.physWrite = { [weak self] pa, bytes in self?.physWriteBytes(pa, bytes) }
        }
        if let aux = bdifAuxDisk {
            let blk = VirtioBlk(disk: aux, appleVariant: 2)   // HV_VBLK_AUX
            wire(blk.vio)
            bus.attach(blk.vio.pci)
            vmAuxBlk = blk
        }
        if let root = bdifRootDisk {
            let blk = VirtioBlk(disk: root, appleVariant: 1)   // HV_VBLK_ROOT
            wire(blk.vio)
            bus.attach(blk.vio.pci)
            vmRootBlk = blk
        }
        if bdifUSBEnabled {
            let usb = VirtioUsbDevice(cpu: self)
            wire(usb.vio)
            bus.attach(usb.vio.pci)
            vmUsbDev = usb
        }
    }

    private func bdifRead(offset: UInt64) -> UInt64 {
        let devid = offset & 0xFFFF_0000
        if devid == 0x0010_0000 && bdifUSBEnabled { return bdifUSBRead(reg: offset & 0xFFFF) }
        switch offset & 0xFFFF {
        case 0x0000: return 1                 // STATUS: ACTIVE
        case 0x0004: return 2                 // CFG: ACTIVE
        case 0x0008: return 0x420             // UNK1
        case 0x0010: return 1                 // BUSY: READY
        case 0x0400: return 1                 // UNK2
        case 0x0434: return 0                 // UNK3
        case 0x0420:                          // NEXT_DEVICE: ストレージでは容量（512B セクタ数）。iBoot が GPT を検証する（Henge 準拠）
            switch devid {
            case 0x0000_0000: return UInt64(bdifRootDisk?.size ?? 0) / 512
            case 0x0001_0000: return UInt64(bdifAuxDisk?.size ?? 0) / 512
            default: return UInt64.max
            }
        default: return UInt64.max
        }
    }

    private func bdifWrite(offset: UInt64, value: UInt64) {
        let devid = offset & 0xFFFF_0000
        if devid == 0x0010_0000 && bdifUSBEnabled {
            bdifUSBWrite(reg: offset & 0xFFFF, value: value)
            return
        }
        guard offset & 0xFFFF == 0x0408 else { return }   // REG_CMD のみ
        switch devid {
        case 0x0000_0000: bdifVblkCommand(isAux: false, requestPA: value)
        case 0x0001_0000: bdifVblkCommand(isAux: true, requestPA: value)
        default: break
        }
    }

    /// VblkReq（sector / data / retval の各 {addr, len, flags}、計 48 バイト）を処理する。
    private func bdifVblkCommand(isAux: Bool, requestPA: UInt64) {
        func rd64(_ pa: UInt64) -> UInt64 { readGuestMemory(address: pa, size: 8) }
        func rd32(_ pa: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: readGuestMemory(address: pa, size: 4)) }
        let sectorAddr = rd64(requestPA), sectorLen = rd32(requestPA + 8)
        let dataAddr = rd64(requestPA + 16), dataLen = Int(rd32(requestPA + 24)), dataFlags = rd32(requestPA + 28)
        let retvalAddr = rd64(requestPA + 32)
        var ret: UInt8 = 1   // FAILED
        defer { writeGuestMemory([ret], at: retvalAddr) }
        guard sectorLen == 16 else { return }
        let off = Int(rd32(sectorAddr + 8)) * 512
        guard let disk = isAux ? bdifAuxDisk : bdifRootDisk else { return }
        if dataFlags == 0x0003_0001 {   // READ（デバイスがバッファへ書く）
            guard let bytes = disk.read(offset: off, count: dataLen) else { return }
            writeGuestMemory(bytes, at: dataAddr)
            ret = 0   // SUCCESS
        } else if dataFlags == 0x0001_0001 {   // WRITE（Henge は実装。macOS 27 の iBSS が aux へ書く）
            var bytes = [UInt8]()
            bytes.reserveCapacity(dataLen)
            var pa = dataAddr
            var left = dataLen
            while left > 0 {
                let n = min(8, left)
                let v = readGuestMemory(address: pa, size: n)
                for i in 0..<n { bytes.append(UInt8((v >> UInt64(8 * i)) & 0xFF)) }
                pa += UInt64(n); left -= n
            }
            if disk.write(offset: off, bytes: bytes) { ret = 0 }   // SUCCESS
        }
    }

    // MARK: bdif USB チャネル（devid 0x100000、インストーラ起動時のみ。Henge devices/bdif.c の USB 部再現）
    // メッセージ形式は virtio-usb と共通: 要求は {u32 len, u8 ep, u8 type} ヘッダ＋ペイロードを
    // queue 0 のバッファへ、応答は queue 1 のチェーン先頭 2 バイト {type, ep}＋データ。

    /// USB チャネルが有効か（インストーラ起動で有効化）
    var bdifUSBEnabled = false
    private var usbRomOn = false
    private var usbQsel: UInt32 = 0
    private var usbIRQValue: UInt32 = 0
    private var usbQueues: [(pending: UInt64, done: Bool)] = [(0, false), (0, false)]
    /// ホスト→ゲスト要求リング / ゲスト→ホスト応答リング（HvVusbMsg 相当）
    struct VusbMessage { var type: UInt8; var ep: UInt8; var len: UInt32; var data: [UInt8]? }
    private var vusbOutRing: [VusbMessage] = []
    private var vusbInRing: [VusbMessage] = []
    private(set) var vusbOnline = false
    private(set) var vusbSession: UInt32 = 0
    /// USB チャネルのデバッグイベント通知（ハーネス用）
    var onVusbEvent: ((String) -> Void)?

    /// ホスト側: 要求をキューする（オンラインでなければ false）
    func vusbSendRequest(type: UInt8, ep: UInt8, data: [UInt8]?, len: UInt32) -> Bool {
        guard vusbOnline, vusbOutRing.count < 256 else { return false }
        vusbOutRing.append(VusbMessage(type: type, ep: ep, len: len, data: data))
        return true
    }

    /// ホスト側: 次の応答を取り出す
    func vusbTakeResponse() -> VusbMessage? {
        guard !vusbInRing.isEmpty else { return nil }
        return vusbInRing.removeFirst()
    }

    /// virtio-usb フロントエンド用: 先頭の要求を覗く / 取り出す / 応答を返す
    func vusbPeekRequest() -> VusbMessage? { vusbOutRing.first }
    func vusbTakeRequest() -> VusbMessage? {
        guard !vusbOutRing.isEmpty else { return nil }
        return vusbOutRing.removeFirst()
    }
    func vusbPutResponse(type: UInt8, ep: UInt8, data: [UInt8]?) {
        guard vusbInRing.count < 256 else { return }
        vusbInRing.append(VusbMessage(type: type, ep: ep, len: UInt32(data?.count ?? 0), data: data))
    }
    func vusbSetOnlineFromDevice(_ on: Bool) { vusbSetOnline(on) }
    func usbRomOnSet(_ on: Bool) { usbRomOn = on }

    /// デバイスのポーリング（ハーネスが実行チャンクの間に呼ぶ）
    func pollVMAppleDevices() {
        bdifPoll()
        vmUsbDev?.poll()
    }

    private func vusbSetOnline(_ on: Bool) {
        if on || vusbOnline { vusbSession &+= 1 }
        vusbOnline = on
        vusbOutRing.removeAll()
        vusbInRing.removeAll()
    }

    private func bdifUSBRead(reg: UInt64) -> UInt64 {
        switch reg {
        case 0x0000: return 1                                   // STATUS
        case 0x0004: return 0x1A01                              // CFG: USB デバイスタイプ
        case 0x0008: return 0x420                               // UNK1
        case 0x0010: return usbQsel < 2 ? (usbQueues[Int(usbQsel)].done ? 1 : 0) : 0   // BUSY: 選択キューの done
        case 0x0400: return 1                                   // UNK2
        case 0x0404: return UInt64(usbIRQValue)
        case 0x0410: return UInt64(usbQsel)                     // QSEL
        case 0x0434: return 0                                   // UNK3
        case 0x0420: return UInt64.max                          // NEXT_DEVICE
        default: return 0
        }
    }

    private func bdifUSBWrite(reg: UInt64, value: UInt64) {
        switch reg {
        case 0x0400:   // UNK2: (再)有効化。ブートチェーンの新ステージが接続する
            usbRomOn = value != 0
            vusbSetOnline(value != 0)
            usbQueues = [(0, true), (0, true)]   // idle: 未送信
            onVusbEvent?("UNK2 write v=\(value) -> online=\(vusbOnline) session=\(vusbSession) at instr \(instructionsExecuted)")
        case 0x0404: usbIRQValue = UInt32(truncatingIfNeeded: value)
        case 0x0410: usbQsel = UInt32(truncatingIfNeeded: value)
        case 0x0408:   // CMD: チェーン送信
            guard usbQsel < 2 else { break }
            let q = Int(usbQsel)
            usbQueues[q].done = false
            if q == 0 {
                usbQueues[0].pending = value
                onVusbEvent?("Q0 submit chain=0x\(String(value, radix: 16)) at instr \(instructionsExecuted)")
                bdifPoll()
            } else {
                onVusbEvent?("Q1 submit chain=0x\(String(value, radix: 16)) romOn=\(usbRomOn) at instr \(instructionsExecuted)")
                defer { usbQueues[1].done = true }
                guard usbRomOn else { break }
                var buf = [UInt8]()
                _ = bdifUSBXfer(chain: value, write: false, buf: &buf, collect: true)
                if buf.count >= 2 {
                    vusbInRing.append(VusbMessage(type: buf[0], ep: buf[1], len: UInt32(buf.count - 2),
                                                  data: buf.count > 2 ? [UInt8](buf[2...]) : nil))
                }
            }
        default: break
        }
    }

    /// ディスクリプタチェーン（最大 5 個、各 16 バイト {u64 addr, u32 len, u16 one, u16 flags}）をたどる。
    /// write=true: デバイス書き込み側（flags bit1）のバッファへ buf を書く。write=false: デバイス読み取り側から buf へ集める。
    /// 戻り値は対象ディスクリプタの合計容量。
    private func bdifUSBXfer(chain: UInt64, write: Bool, buf: inout [UInt8], collect: Bool = false) -> Int {
        var total = 0
        var done = 0
        for i in 0..<5 {
            let base = chain + UInt64(16 * i)
            let addr = readGuestMemory(address: base, size: 8)
            let len = Int(readGuestMemory(address: base + 8, size: 4))
            let flags = readGuestMemory(address: base + 14, size: 2)   // {u64 addr, u32 len, u16 one, u16 flags}
            let devWrites = flags & 2 != 0
            if devWrites == write {
                total += len
                if collect {
                    var pa = addr
                    var left = len
                    while left > 0 {
                        let n = min(8, left)
                        let v = readGuestMemory(address: pa, size: n)
                        for j in 0..<n { buf.append(UInt8((v >> UInt64(8 * j)) & 0xFF)) }
                        pa += UInt64(n); left -= n
                    }
                    done += len
                } else {
                    let n = min(len, buf.count - done)
                    if n > 0 {
                        writeGuestMemory([UInt8](buf[done..<done + n]), at: addr)
                        done += n
                    }
                }
            }
            if flags & 1 == 0 { break }
        }
        return total
    }

    /// CPU スレッド側ポーリング: queue 0 にバッファがありホスト要求が来ていれば届ける（hv_bdif_poll 相当）。
    func bdifPoll() {
        guard bdifUSBEnabled, usbRomOn, usbQueues[0].pending != 0, !usbQueues[0].done else { return }
        guard !vusbOutRing.isEmpty else { return }
        let m = vusbOutRing.removeFirst()
        onVusbEvent?("deliver type=\(m.type) ep=0x\(String(m.ep, radix: 16)) len=\(m.len) payload=\(m.data?.count ?? 0) at instr \(instructionsExecuted)")
        let chain = usbQueues[0].pending
        for i in 0..<5 {
            let base = chain + UInt64(16 * i)
            let a = readGuestMemory(address: base, size: 8)
            let l = readGuestMemory(address: base + 8, size: 4)
            let f = readGuestMemory(address: base + 14, size: 2)
            onVusbEvent?("  desc\(i) addr=0x\(String(a, radix: 16)) len=\(l) flags=0x\(String(f, radix: 16))")
            if f & 1 == 0 { break }
        }
        var probe = [UInt8]()
        _ = bdifUSBXfer(chain: chain, write: true, buf: &probe)
        var msg = [UInt8]()
        let payload = m.data ?? []
        msg += [UInt8(m.len & 0xFF), UInt8((m.len >> 8) & 0xFF), UInt8((m.len >> 16) & 0xFF), UInt8((m.len >> 24) & 0xFF), m.ep, m.type]
        msg += payload
        _ = bdifUSBXfer(chain: chain, write: true, buf: &msg)
        usbQueues[0].done = true
        usbQueues[0].pending = 0
    }

    // MARK: VMAPPLE UART（ARM PL011。DT compatible "arm,pl011" / QEMU vmapple の実デバイス）

    private var vmPL011Storage: [UInt64: UInt64] = [:]

    private func vmPL011Read(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x00:  // DR: 受信データ
            inputLock.lock()
            defer { inputLock.unlock() }
            if inputQueue.isEmpty { return 0 }
            return UInt64(inputQueue.removeFirst())
        case 0x04:  // RSR: エラーなし
            return 0
        case 0x18:  // FR: TX FIFO は即時ドレイン（TXFE 常時 1）、BUSY 0
            return 0x80 | (inputQueueEmpty ? 0x10 : 0)
        case 0x3C:  // RIS: TXRIS は FIFO 空で立つ。RXRIS は受信データあり
            return 0x20 | (inputQueueEmpty ? 0 : 0x10)
        case 0x40:  // MIS
            let ris: UInt64 = 0x20 | (inputQueueEmpty ? 0 : 0x10)
            return ris & (vmPL011Storage[0x38] ?? 0)
        case 0xFE0: return 0x11  // PeriphID0
        case 0xFE4: return 0x10  // PeriphID1
        case 0xFE8: return 0x14  // PeriphID2
        case 0xFEC: return 0x00  // PeriphID3
        case 0xFF0: return 0x0D  // CellID0
        case 0xFF4: return 0xF0  // CellID1
        case 0xFF8: return 0x05  // CellID2
        case 0xFFC: return 0xB1  // CellID3
        default:
            return vmPL011Storage[offset] ?? 0
        }
    }

    private func vmPL011Write(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x00:  // DR: 送信データ
            onChar?(UInt8(value & 0xFF))
        case 0x44:  // ICR: 状態は動的に生成するため何もしない
            break
        default:
            vmPL011Storage[offset] = value
        }
    }

    /// PL011 の割り込み線（INTID 33）を MIS から駆動する。
    /// Henge devices/pl011.c の update（(ris & imsc) != 0 で IRQ）と等価。
    private func syncVMAppleUARTLine() {
        guard let gic = gic3 else { return }
        let ris: UInt64 = 0x20 | (inputQueueEmpty ? 0 : 0x10)
        let mis = ris & (vmPL011Storage[0x38] ?? 0)
        gic.setSPILevel(33, mis != 0)
    }

    // MARK: VMAPPLE GIC MSI フレーム（0x1FFF0000。Henge devices/vmapple.c
    // gic_msi_read / gic_msi_write、VMAPPLE_MSI_BASE = 96、COUNT = 64）
    // カーネルの AppleVirtualPlatformPCIEMSIController は +0x8 の
    // タイプレジスタ bit31（valid）を要求し、+0x40 をドアベルとして使う。

    private func gicMsiRead(offset: UInt64) -> UInt64 {
        if offset == 0x8 { return (1 << 31) | (96 << 16) | 64 }
        return 0
    }

    private func gicMsiWrite(offset: UInt64, value: UInt64) {
        if offset == 0x40 {
            let intid = Int(value)
            if intid >= 96 && intid < 96 + 64 { gic3?.pendSPI(intid) }
        }
    }

    // MARK: VMAPPLE RTC セレクト（0x30240000。Henge devices/vmapple.c
    // rtc_select_read / rtc_select_write。QEMU vmapple には無い）
    // +0x40 = 0xF001 → iBootStage2 / カーネルは PL031 ドライバを使う。
    // +0 = Unix 時刻のマイクロ秒カウンタ、+0x08..+0x38 は保持領域
    // （+0x18 有効ビット、+0x20 割り込み制御、+0x38 アラーム）。

    private var avpRtcStorage = [UInt64](repeating: 0, count: 8)

    private func rtcSelectRead(offset: UInt64, size: Int) -> UInt64 {
        if offset == 0x40 { return 0xF001 }
        if offset < 0x40 && offset != 0 && offset & 7 == 0 {
            return avpRtcStorage[Int(offset / 8)]
        }
        if offset == 0 || offset == 4 {
            let us = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            return offset == 4 ? us >> 32 : (size == 4 ? us & 0xFFFF_FFFF : us)
        }
        return 0
    }

    private func rtcSelectWrite(offset: UInt64, value: UInt64) {
        if offset != 0 && offset < 0x40 && offset & 7 == 0 {
            avpRtcStorage[Int(offset / 8)] = value
        }
    }

    // MARK: VMAPPLE AES エンジン（0x30220000 / 0x30230000、各 16 KiB、IRQ = INTID 50。
    // QEMU hw/vmapple/aes.c の移植。Henge devices/aes.c も同じ QEMU 実装の移植で、
    // レジスタ配置・リセット値・FIFO 意味論は両リファレンスで一致する）
    //
    // レジスタ（第1ウィンドウ）:
    //   0x0C STATUS（リセット値 0x3F80。bit7 = TEXT_DPA_SEEDED、bit8 =
    //   UNWRAP_DPA_SEEDED。AppleS8000AESAccelerator::_enableAES はこの
    //   レジスタの bit 群が立つまでポーリングし、タイムアウトすると
    //   "DPA has not been seeded!" で panic する — phase 11 で確定した壁）
    //   0x18 IRQ_STATUS（書き込みでビットクリア）、0x1C IRQ_ENABLE、
    //   0x20 WATERMARK、0x24 Q_STATUS（リセット値 2）、0x30 FLAG_INFO、
    //   0x200 コマンド FIFO（32 bit ワードを push するたびに消化を試みる）
    // コマンド（word0 の bits[31:28]）: 1=KEY, 2=IV, 5=DATA, 6=STORE_IV,
    // 8=FLAG。それ以外は IRQ_STATUS の INVALID_CMD(bit2) を立て、FIFO は
    // 消費しない（QEMU の fifo_process の default 節そのまま）。
    // QEMU との意図的な一致: DATA コマンドの IV コンテキストは QEMU では
    // 常に 0（cmd_data の ctxt_iv ハードコード）。IV/STORE_IV のコンテキスト
    // デコードも QEMU のマスク（bits[28:27] を >>26）をそのまま再現する。
    // Henge は bits[27:26] でデコードする点だけ異なる（両者とも macOS は
    // 起動する。起動経路では発散しない）。

    private var aesStatus: UInt32 = 0x3F80
    private var aesQStatus: UInt32 = 2
    private var aesIrqStatus: UInt32 = 0
    private var aesIrqEnable: UInt32 = 0
    private var aesWatermark: UInt32 = 0
    private var aesFlagInfo: UInt32 = 0
    private var aesFifo = [UInt32](repeating: 0, count: 9)
    private var aesFifoIdx = 0
    private var aesKeyLen = [Int](repeating: 0, count: 2)
    private var aesKeys = [[UInt8]](repeating: [UInt8](repeating: 0, count: 32), count: 2)
    private var aesIvs = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 4)
    private var aesEncrypt = false
    private var aesCbc = false

    private func aesUpdateIRQ() {
        gic3?.setSPILevel(50, aesIrqStatus & aesIrqEnable != 0)
    }

    private func aesRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x0C: return UInt64(aesStatus)
        case 0x18: return UInt64(aesIrqStatus)
        case 0x1C: return UInt64(aesIrqEnable)
        case 0x20: return UInt64(aesWatermark)
        case 0x24: return UInt64(aesQStatus)
        case 0x30: return UInt64(aesFlagInfo)
        default: return 0
        }
    }

    private func aesWrite(offset: UInt64, value: UInt64) {
        let v = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x18:
            aesIrqStatus &= ~v
        case 0x1C:
            aesIrqEnable = v
        case 0x200:
            if aesFifoIdx < aesFifo.count {
                aesFifo[aesFifoIdx] = v
                aesFifoIdx += 1
            }
            aesFifoProcess()
        default:
            return // 未実装オフセット: QEMU は IRQ 更新もしない
        }
        aesUpdateIRQ()
    }

    private func aesHasPayload(_ elems: Int) -> Bool { aesFifoIdx >= elems + 1 }

    private func aesFifoProcess() {
        guard aesFifoIdx > 0 else { return }
        let cmd = aesFifo[0]
        var success = false
        switch cmd >> 28 {
        case 1: success = aesCmdKey()
        case 2: success = aesCmdIv()
        case 5: success = aesCmdData()
        case 6: success = aesCmdStoreIv()
        case 8: success = aesCmdFlag()
        default: aesIrqStatus |= 1 << 2 // INVALID_CMD
        }
        if success { aesFifoIdx = 0 }
    }

    private func aesCmdKey() -> Bool {
        let cmd = aesFifo[0]
        switch (cmd >> 16) & 3 {
        case 0: aesCbc = false
        case 1: aesCbc = true
        default: return false
        }
        aesEncrypt = (cmd >> 20) & 1 != 0
        let keyLens = [16, 24, 32, 64]
        let keyLen = keyLens[Int((cmd >> 22) & 3)]
        let sel = Int((cmd >> 24) & 7)
        let ctx = Int((cmd >> 27) & 1)
        if sel != 0 {
            // 組み込みキー 1..3（QEMU builtin_keys）: 32 バイト、先頭バイト = 選択番号。
            // 4..7 は QEMU ではゼロ初期化エントリ（長さ 0）。
            if sel <= 3 {
                aesKeys[ctx] = [UInt8](repeating: 0, count: 32)
                aesKeys[ctx][0] = UInt8(sel)
                aesKeyLen[ctx] = 32
            } else {
                aesKeys[ctx] = [UInt8](repeating: 0, count: 32)
                aesKeyLen[ctx] = 0
            }
            return true
        }
        if keyLen > 32 { return false }
        if !aesHasPayload(keyLen / 4) { return false }
        var key = [UInt8](repeating: 0, count: 32)
        for i in 0..<keyLen {
            key[i] = UInt8((aesFifo[1 + i / 4] >> (8 * (i % 4))) & 0xFF)
        }
        aesKeys[ctx] = key
        aesKeyLen[ctx] = keyLen
        return true
    }

    private func aesCmdIv() -> Bool {
        // QEMU のデコード: (cmd & (0x3 << 27)) >> 26 → 0/2/4/6。
        let ctx = Int((aesFifo[0] & 0x1800_0000) >> 26)
        if !aesHasPayload(4) { return false }
        if ctx < 4 {
            for i in 0..<16 {
                aesIvs[ctx][i] = UInt8((aesFifo[1 + i / 4] >> (8 * (i % 4))) & 0xFF)
            }
        }
        return true
    }

    private func aesCmdStoreIv() -> Bool {
        let cmd = aesFifo[0]
        let ctx = Int((cmd & 0x1800_0000) >> 26)
        if !aesHasPayload(1) { return false }
        if ctx >= 4 { return false }
        let addr = UInt64(aesFifo[1]) | ((UInt64(cmd) << 32) & 0xFF_0000_0000)
        guard let o = ramOffset(addr, size: 16) else { return false }
        for i in 0..<16 { memory[o + i] = aesIvs[ctx][i] }
        return true
    }

    private func aesCmdFlag() -> Bool {
        let cmd = aesFifo[0]
        if (cmd >> 27) & 1 != 0 { aesIrqStatus |= 1 << 5 }
        aesFlagInfo = cmd & 0xFF
        return true
    }

    private func aesCmdData() -> Bool {
        let cmd = aesFifo[0]
        let keyCtx = Int((cmd >> 27) & 1)
        let len = Int(cmd & 0xFF_FFFF)
        if !aesHasPayload(3) { return false }
        let src = UInt64(aesFifo[2]) | ((UInt64(aesFifo[1]) << 16) & 0xFFFF_0000_0000)
        let dst = UInt64(aesFifo[3]) | ((UInt64(aesFifo[1]) << 32) & 0xFFFF_0000_0000)
        let keyLen = aesKeyLen[keyCtx]
        if keyLen != 16 && keyLen != 24 && keyLen != 32 { return false }
        if len == 0 { return true }
        if len % 16 != 0 { return false } // QEMU では cipher 段で失敗し未消費
        guard let so = ramOffset(src, size: len), let dof = ramOffset(dst, size: len) else { return false }
        var buf = [UInt8](repeating: 0, count: len)
        for i in 0..<len { buf[i] = memory[so + i] }
        let key = Array(aesKeys[keyCtx][0..<keyLen])
        let iv = aesIvs[0] // QEMU cmd_data は IV コンテキストを常に 0 とする
        var prev = iv
        var pos = 0
        while pos < len {
            var block = Array(buf[pos..<(pos + 16)])
            if aesEncrypt {
                if aesCbc { for i in 0..<16 { block[i] ^= prev[i] } }
                let out = Self.aesDevCryptBlock(block, key: key, encrypt: true)
                for i in 0..<16 { buf[pos + i] = out[i] }
                if aesCbc { prev = out }
            } else {
                let input = block
                var out = Self.aesDevCryptBlock(block, key: key, encrypt: false)
                if aesCbc { for i in 0..<16 { out[i] ^= prev[i] } }
                for i in 0..<16 { buf[pos + i] = out[i] }
                prev = input
            }
            pos += 16
        }
        for i in 0..<len { memory[dof + i] = buf[i] }
        return true
    }

    // MARK: AES ブロック暗号（FIPS-197。デバイス FIFO の DATA コマンド用。
    // 鍵長 16/24/32 の暗号化・復号。S-box は命令エミュレーションと共用）

    private static func aesDevGFMul(_ a: UInt8, _ f: UInt8) -> UInt8 {
        var x = a, r: UInt8 = 0, f = f
        for _ in 0..<8 {
            if f & 1 != 0 { r ^= x }
            x = (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)
            f >>= 1
        }
        return r
    }

    static func aesDevExpandKey(_ key: [UInt8]) -> [UInt8] {
        let nk = key.count / 4
        let nr = nk + 6
        var w = [UInt8](repeating: 0, count: 16 * (nr + 1))
        for i in 0..<key.count { w[i] = key[i] }
        var rcon: UInt8 = 1
        var i = nk
        while i < 4 * (nr + 1) {
            var t = [w[4 * (i - 1)], w[4 * (i - 1) + 1], w[4 * (i - 1) + 2], w[4 * (i - 1) + 3]]
            if i % nk == 0 {
                t = [aesSBox[Int(t[1])] ^ rcon, aesSBox[Int(t[2])], aesSBox[Int(t[3])], aesSBox[Int(t[0])]]
                rcon = aesDevGFMul(rcon, 2)
            } else if nk > 6 && i % nk == 4 {
                t = [aesSBox[Int(t[0])], aesSBox[Int(t[1])], aesSBox[Int(t[2])], aesSBox[Int(t[3])]]
            }
            for j in 0..<4 { w[4 * i + j] = w[4 * (i - nk) + j] ^ t[j] }
            i += 1
        }
        return w
    }

    static func aesDevCryptBlock(_ input: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        let rk = aesDevExpandKey(key)
        let nr = key.count / 4 + 6
        var s = input
        func addRK(_ round: Int) {
            for i in 0..<16 { s[i] ^= rk[16 * round + i] }
        }
        func sub(_ inv: Bool) {
            for i in 0..<16 { s[i] = inv ? aesInvSBox[Int(s[i])] : aesSBox[Int(s[i])] }
        }
        func shift(_ inv: Bool) {
            let old = s
            for c in 0..<4 {
                for r in 0..<4 {
                    let src = inv ? (c + 4 - r) & 3 : (c + r) & 3
                    s[r + 4 * c] = old[r + 4 * src]
                }
            }
        }
        func mix(_ inv: Bool) {
            for c in 0..<4 {
                let a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3]
                if inv {
                    s[4 * c] = aesDevGFMul(a0, 14) ^ aesDevGFMul(a1, 11) ^ aesDevGFMul(a2, 13) ^ aesDevGFMul(a3, 9)
                    s[4 * c + 1] = aesDevGFMul(a0, 9) ^ aesDevGFMul(a1, 14) ^ aesDevGFMul(a2, 11) ^ aesDevGFMul(a3, 13)
                    s[4 * c + 2] = aesDevGFMul(a0, 13) ^ aesDevGFMul(a1, 9) ^ aesDevGFMul(a2, 14) ^ aesDevGFMul(a3, 11)
                    s[4 * c + 3] = aesDevGFMul(a0, 11) ^ aesDevGFMul(a1, 13) ^ aesDevGFMul(a2, 9) ^ aesDevGFMul(a3, 14)
                } else {
                    s[4 * c] = aesDevGFMul(a0, 2) ^ aesDevGFMul(a1, 3) ^ a2 ^ a3
                    s[4 * c + 1] = a0 ^ aesDevGFMul(a1, 2) ^ aesDevGFMul(a2, 3) ^ a3
                    s[4 * c + 2] = a0 ^ a1 ^ aesDevGFMul(a2, 2) ^ aesDevGFMul(a3, 3)
                    s[4 * c + 3] = aesDevGFMul(a0, 3) ^ a1 ^ a2 ^ aesDevGFMul(a3, 2)
                }
            }
        }
        if encrypt {
            addRK(0)
            for round in 1..<nr {
                sub(false); shift(false); mix(false); addRK(round)
            }
            sub(false); shift(false); addRK(nr)
        } else {
            addRK(nr)
            var round = nr - 1
            while round >= 1 {
                shift(true); sub(true); addRK(round); mix(true)
                round -= 1
            }
            shift(true); sub(true); addRK(0)
        }
        return s
    }

    // MARK: VMAPPLE PVG（gfx 0x30200000 / iOSurface 0x30210000、IRQ = INTID 49 / 48。
    // Henge devices/pvg_lite.c のレジスタ契約を移植したもの。QEMU vmapple の
    // memmap / irqmap とも一致: GFX = SPI 0x11, IOSFC = SPI 0x10、両窓とも 64 KiB）
    //
    // gfx レジスタ（レジスタ領域はウィンドウ +0x1000..+0x2000。ドライバは
    // マップした VA + 0x1000 を基点にアクセスする）:
    //   +1000 enable, +1004 FIFO バッファサイズ, +1008 ルートリング書込み
    //   ポインタ（ドアベル）, +100c ルートリング読込みポインタ（読むと
    //   do_root が走る。ドライバは空き待ちでここをポーリングする）,
    //   +1010 リングオフセット, +1014 display bits, +1018 ステータス
    //   （チャンネル完了ビット。読むとクリア）, +101c ルートページ (<<14),
    //   +1020 チャンネルドアベル（値 = チャンネル番号）, +102c faults,
    //   +1030 FIFO バッファページ (<<14), +1034 プロトコルバージョン
    //   （ドライバが書き、読み戻して交渉する。素の保持で足りる）,
    //   +122c ディスプレイ数（読みは常に 1）
    // 全コマンドは {op, length, stamp} で始まり、完了は FIFO バッファ先頭の
    // チャンネル別スタンプ欄（+4 * channel）への stamp 書戻しと読込み
    // ポインタの前進で通知される。
    // iOSurface マッパ（u64 レジスタ、+1000..+1040）:
    //   +1000 リング, +1008 サイズ, +1010 記述子テーブル, +1018 投入
    //   インデクス（書くと消化）, +1020 完了インデクス, +1028 キュー数
    //   （読みは 1）, +1030 enable

    private var pvgRegs = [UInt32](repeating: 0, count: 0x1000 / 4)
    private var pvgRootRP: UInt32 = 0
    private var pvgStatus: UInt32 = 0
    private var pvgTaskRoot = [UInt32](repeating: 0, count: 512)
    private var pvgTaskObjects = [UInt64](repeating: 0, count: 512)
    private var pvgTaskPlacement = [UInt64](repeating: 0, count: 512)
    private var pvgDisplayPA: UInt64 = 0
    private var pvgSwaps: UInt64 = 0
    private var pvgIosfcRegs = [UInt64](repeating: 0, count: 0x40 / 8)

    private func pvgReg(_ off: UInt64) -> UInt32 { pvgRegs[Int((off - 0x1000) / 4)] }

    /// ゲスト物理メモリ（DRAM）への直接アクセス。範囲外は nil / 無視。
    private func pvgMem32(_ pa: UInt64) -> UInt32? {
        guard let o = ramOffset(pa, size: 4) else { return nil }
        return UInt32(memory[o]) | UInt32(memory[o + 1]) << 8 | UInt32(memory[o + 2]) << 16 | UInt32(memory[o + 3]) << 24
    }

    private func pvgStore32(_ pa: UInt64, _ v: UInt32) {
        guard let o = ramOffset(pa, size: 4) else { return }
        memory[o] = UInt8(v & 0xFF)
        memory[o + 1] = UInt8((v >> 8) & 0xFF)
        memory[o + 2] = UInt8((v >> 16) & 0xFF)
        memory[o + 3] = UInt8((v >> 24) & 0xFF)
    }

    private func pvgStore8(_ pa: UInt64, _ v: UInt8) {
        guard let o = ramOffset(pa, size: 1) else { return }
        memory[o] = v
    }

    /// ルートリングの消化（Henge do_root）。op 0x38 = タスクルート登録
    /// （+12 = id, +24 = ページ）、op 0x3a = GetDeviceInfo（+20 のページへ
    /// key/value 表を書く）。それ以外のコマンドは完了扱い。
    private func pvgDoRoot() {
        let buf = UInt64(pvgReg(0x1030)) << 14
        let off = pvgReg(0x1010)
        let size = pvgReg(0x1004)
        let wp = pvgReg(0x1008)
        guard buf != 0, size > off else { return }
        let ring = size - off
        while pvgRootRP != wp {
            let at = pvgRootRP % ring
            var hdr = [UInt32](repeating: 0, count: 3)
            for i in 0..<3 {
                hdr[i] = pvgMem32(buf + UInt64(off) + UInt64((at + 4 * UInt32(i)) % ring)) ?? 0
            }
            if hdr[1] < 12 || hdr[1] > ring {
                pvgRootRP = wp
                break
            }
            let op = hdr[0] & 0xFFFF
            if op == 0x38 && hdr[1] >= 28 {
                let id = pvgMem32(buf + UInt64(off) + UInt64((at + 12) % ring)) ?? 0
                let page = pvgMem32(buf + UInt64(off) + UInt64((at + 24) % ring)) ?? 0
                if id >> 1 < 512 { pvgTaskRoot[Int(id >> 1)] = page }
            }
            if op == 0x3A && hdr[1] >= 24 {
                let page = pvgMem32(buf + UInt64(off) + UInt64((at + 20) % ring)) ?? 0
                if page != 0 {
                    let dst = UInt64(page) << 14
                    for (i, kv) in Self.pvgDeviceInfo.enumerated() {
                        pvgStore32(dst + UInt64(8 * i), kv.0)
                        pvgStore32(dst + UInt64(8 * i + 4), kv.1)
                    }
                }
            }
            pvgRootRP += hdr[1]
            pvgStore32(buf, hdr[2]) // チャンネル 0 のスタンプ欄
        }
    }

    /// GetDeviceInfo の応答表（Henge pvg_lite.c の device_info そのまま）。
    private static let pvgDeviceInfo: [(UInt32, UInt32)] = [
        (0x01, 4), (0x02, 0), (0x03, 0x400), (0x04, 0x400), (0x05, 0x400), (0x06, 0x8000), (0x07, 1),
        (0x08, 1), (0x09, 1), (0x0A, 8), (0x0B, 0x1FF), (0x0C, 1), (0x0D, 0x10), (0x0E, 1),
        (0x0F, 0x100), (0x10, 1), (0x11, 1), (0x12, 0x20007), (0x13, 1), (0x14, 2), (0x15, 1),
        (0x16, 2), (0x17, 1), (0x18, 1), (0x19, 1), (0x1A, 1), (0x1B, 1), (0x1C, 7),
        (0x21, 0xFFF), (0x24, 0xFFFF_FFFF), (0x1D, 0x400), (0x1E, 0x1F), (0x1F, 0x10000), (0x20, 0x10), (0x22, 5),
        (0x29, 7), (0x23, 0x800), (0x25, 0x3F1), (0x28, 0x10),
    ]

    /// 散在ページで構成されるチャンネルリングから count バイト読む
    /// （Henge ring_read。テーブルは 16 KiB ページ番号の u32 配列）。
    private func pvgRingRead(table: [UInt32], size: UInt32, at: UInt32, count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var done = 0
        var pos = at
        while done < count {
            let o = pos % size
            var chunk = Int(0x4000 - (o & 0x3FFF))
            if chunk > count - done { chunk = count - done }
            let pa = (UInt64(table[Int(o >> 14)]) << 14) + UInt64(o & 0x3FFF)
            for k in 0..<chunk {
                if let b = ramOffset(pa + UInt64(k), size: 1) { out.append(memory[b]) } else { out.append(0) }
            }
            done += chunk
            pos += UInt32(chunk)
        }
        return out
    }

    private func pvgWords(_ bytes: [UInt8], count: Int) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: count)
        for i in 0..<count where 4 * i + 3 < bytes.count {
            let b = 4 * i
            w[i] = UInt32(bytes[b]) | UInt32(bytes[b + 1]) << 8 | UInt32(bytes[b + 2]) << 16 | UInt32(bytes[b + 3]) << 24
        }
        return w
    }

    /// チャンネルリングの消化（Henge do_channel の非 Metal 経路。GPU 実行は
    /// 行わず、全コマンドを順序通り完了させる）。
    private func pvgDoChannel(_ ch: UInt32) {
        let root = UInt64(pvgReg(0x101C)) << 14
        let buf = UInt64(pvgReg(0x1030)) << 14
        guard root != 0, buf != 0, ch != 0, ch < 16 else { return }
        let recPA = root + 0x400 + UInt64(0x14 * (ch - 1))
        var rec = [UInt32](repeating: 0, count: 5)
        for i in 0..<5 { rec[i] = pvgMem32(recPA + UInt64(4 * i)) ?? 0 }
        let tablePA = UInt64(rec[4]) << 14
        guard tablePA != 0 else { return }
        var table = [UInt32]()
        while table.count < 0x1000 {
            let v = pvgMem32(tablePA + UInt64(4 * table.count)) ?? 0
            if v == 0 { break }
            table.append(v)
        }
        guard !table.isEmpty else { return }
        let size = UInt32(table.count) << 14
        var rd = rec[1]
        let wr = rec[0]
        var last: UInt32 = 0
        var any = false
        while rd != wr {
            let hdr = pvgWords(pvgRingRead(table: table, size: size, at: rd, count: 12), count: 3)
            if hdr[1] < 12 || hdr[1] > size { rd = wr; break }
            pvgChannelCommand(table: table, size: size, rd: rd, hdr: hdr)
            last = hdr[2]
            any = true
            rd += hdr[1]
        }
        pvgStore32(recPA + 4, rd)
        if any {
            pvgStore32(buf + UInt64(4 * ch), last)
            pvgStatus |= (1 << ch)
        }
    }

    /// チャンネルコマンドのうちホスト側の状態に影響するもの
    /// （Henge channel_command の非 Metal 経路）。
    /// op の上位 16 ビットは先行バリアの個数で、各 8 バイトを読み飛ばす。
    private func pvgChannelCommand(table: [UInt32], size: UInt32, rd: UInt32, hdr: [UInt32]) {
        let op = hdr[0] & 0xFFFF
        let skip = (hdr[0] >> 16) * 8
        let payload = hdr[1] > 12 + skip ? Int(hdr[1] - 12 - skip) : 0
        func args(_ n: Int) -> [UInt32] {
            pvgWords(pvgRingRead(table: table, size: size, at: rd + 12 + skip, count: min(n, payload)), count: n / 4)
        }
        switch op {
        case 0x38:
            let a = args(16)
            if a[0] >> 1 < 512 { pvgTaskRoot[Int(a[0] >> 1)] = a[3] }
        case 0x44:
            // タスクのオブジェクトリスト登録（macOS 15 以降）
            let a = args(28)
            if a[0] < 512 {
                pvgTaskObjects[Int(a[0])] = UInt64(a[2]) << 32 | UInt64(a[1])
                pvgTaskPlacement[Int(a[0])] = UInt64(a[4]) << 32 | UInt64(a[3])
            }
        case 1:
            let a = args(8)
            pvgDisplaySetPage(UInt64(a[1]) << 14)
        case 2:
            let a = args(8)
            pvgDisplayAck(a[1])
        case 8:
            let a = args(40)
            pvgDisplaySwap(mapping: UInt64(a[3]) << 32 | UInt64(a[2]), args: a)
        default:
            break // 実行系コマンドは完了扱い（Henge の非 Metal 経路と同じ）
        }
    }

    /// ディスプレイ共有ステートページの初期化（Henge display_set_page。
    /// 提示モードは 1920x1080@60、パネル 400mm 幅として密度を出す）。
    private func pvgDisplaySetPage(_ pa: UInt64) {
        guard ramOffset(pa, size: 0x4000) != nil else { return }
        pvgDisplayPA = pa
        let w: UInt32 = 1920, h: UInt32 = 1080
        let mmW: UInt32 = 400, mmH: UInt32 = 400 * h / w
        pvgStore32(pa + 0x00, 1)
        pvgStore32(pa + 0x14, mmH << 16 | mmW)
        pvgStore32(pa + 0x18, 0x0100_0100)
        pvgStore32(pa + 0x1C, 0x400)
        pvgStore32(pa + 0x20, 3)
        pvgStore32(pa + 0x24, Float(mmW).bitPattern)
        pvgStore32(pa + 0x28, Float(mmH).bitPattern)
        pvgStore32(pa + 0x208, 1) // モード 1 つ
        pvgStore32(pa + 0x210, h << 16 | w)
        pvgStore32(pa + 0x214, 60 << 16)
        pvgStore32(pa + 0xA10, Float(1.0).bitPattern) // 単位カラー行列
        pvgStore32(pa + 0xA24, Float(1.0).bitPattern)
        pvgStore32(pa + 0xA38, Float(1.0).bitPattern)
        pvgStore8(pa + 0xA73, 1)
        pvgStore32(pa + 0x200, 1) // モードリストのシーケンス番号（guest が ack する）
        pvgStore8(pa + 0xFA9, 1)  // ack pending
        pvgStore32(pa + 0xFC0, 1) // state: 通知済み・ack 待ち
        pvgStore32(pa + 0x100, 4) // モード変更イベント（guest がマスク設定後に読む）
    }

    private func pvgDisplayAck(_ seq: UInt32) {
        guard pvgDisplayPA != 0 else { return }
        pvgStore32(pvgDisplayPA + 0xFBC, seq)
        pvgStore8(pvgDisplayPA + 0xFA9, 0)
        pvgStore32(pvgDisplayPA + 0xFC0, 2)
    }

    private func pvgDisplaySwap(mapping: UInt64, args: [UInt32]) {
        guard pvgDisplayPA != 0 else { return }
        let d = pvgDisplayPA
        for i in 0..<4 { pvgStore32(d + 0xF80 + UInt64(4 * i), args[4 + i]) } // gamma offset/length
        for i in 0..<2 { pvgStore32(d + 0xF90 + UInt64(4 * i), args[8 + i]) } // gamma entries/sum
        pvgSwaps += 1
        pvgStore32(d + 0xF98, UInt32(truncatingIfNeeded: pvgSwaps))
        pvgStore32(d + 0xFB0, UInt32(truncatingIfNeeded: mapping))
        if let cur = pvgMem32(d + 0x100) { pvgStore32(d + 0x100, cur | 2) }
    }

    private func pvgGfxRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x100C:
            pvgDoRoot() // ドライバは空き待ちでここを回す（Henge gfx_read）
            return UInt64(pvgRootRP)
        case 0x1018:
            let v = pvgStatus
            pvgStatus = 0
            return UInt64(v)
        case 0x122C:
            return 1 // ディスプレイ数
        default:
            if offset >= 0x1000 && offset < 0x2000 {
                return UInt64(pvgRegs[Int((offset - 0x1000) / 4)])
            }
            return 0
        }
    }

    private func pvgGfxWrite(offset: UInt64, value: UInt64) {
        if offset >= 0x1000 && offset < 0x2000 {
            pvgRegs[Int((offset - 0x1000) / 4)] = UInt32(truncatingIfNeeded: value)
        }
        // ドアベルは書いた CPU 上で即応答する（Henge gfx_write）
        if offset == 0x1008 {
            pvgDoRoot()
            gic3?.pendSPI(49)
        } else if offset == 0x1020 && value < 16 {
            pvgDoChannel(UInt32(value))
            if pvgStatus != 0 { gic3?.pendSPI(49) }
        }
    }

    private func pvgIosfcRead(offset: UInt64) -> UInt64 {
        if offset == 0x1028 { return 1 } // キュー数
        if offset >= 0x1000 && offset < 0x1040 {
            return pvgIosfcRegs[Int((offset - 0x1000) / 8)]
        }
        return 0
    }

    private func pvgIosfcWrite(offset: UInt64, value: UInt64) {
        if offset >= 0x1000 && offset < 0x1040 {
            pvgIosfcRegs[Int((offset - 0x1000) / 8)] = value
        }
        if offset == 0x1018 {
            // マッパの消化（Henge do_mapper の非 Metal 経路）: 完了インデクスを
            // 投入インデクスまで進めて IOSFC IRQ を立てる。guest は完了
            // インデクスの前進を待つ。
            pvgIosfcRegs[(0x1020 - 0x1000) / 8] = pvgIosfcRegs[(0x1018 - 0x1000) / 8]
            gic3?.pendSPI(48)
        }
    }

    // MARK: VMAPPLE PL031 RTC（0x20050000、IRQ = INTID 34。
    // Henge devices/pl031.c。QEMU vmapple も pl031 を同アドレスに置く）

    private var pl031MR: UInt32 = 0
    private var pl031Offset: Int64 = 0
    private var pl031IMSC: UInt32 = 0
    private var pl031RIS: UInt32 = 0

    private func pl031Now() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970) + pl031Offset)
    }

    /// マッチ判定と IRQ ライン更新（Henge hv_pl031_tick + update 相当）。
    private func pl031Tick() {
        if pl031MR != 0 && pl031Now() >= pl031MR && pl031RIS & 1 == 0 {
            pl031RIS |= 1
        }
        gic3?.setSPILevel(34, pl031RIS & pl031IMSC != 0)
    }

    private func pl031Read(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x00: return UInt64(pl031Now())          // DR
        case 0x04: return UInt64(pl031MR)             // MR
        case 0x08: return UInt64(pl031Now())          // LR（現在値を読み戻す）
        case 0x0C: return 1                           // CR: 常時有効
        case 0x10: return UInt64(pl031IMSC)           // IMSC
        case 0x14: return UInt64(pl031RIS)            // RIS
        case 0x18: return UInt64(pl031RIS & pl031IMSC)  // MIS
        case 0xFE0, 0xFE4, 0xFE8, 0xFEC, 0xFF0, 0xFF4, 0xFF8, 0xFFC:
            let id: [UInt64] = [0x31, 0x10, 0x14, 0x00, 0x0D, 0xF0, 0x05, 0xB1]
            return id[Int((offset - 0xFE0) >> 2)]
        default: return 0
        }
    }

    private func pl031Write(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x04:
            pl031MR = UInt32(truncatingIfNeeded: value)
            pl031Tick()
        case 0x08:
            pl031Offset = Int64(UInt32(truncatingIfNeeded: value)) - Int64(Date().timeIntervalSince1970)
        case 0x10:
            pl031IMSC = UInt32(truncatingIfNeeded: value) & 1
        case 0x1C:
            pl031RIS &= ~(UInt32(truncatingIfNeeded: value) & 1)
        default:
            break
        }
        gic3?.setSPILevel(34, pl031RIS & pl031IMSC != 0)
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
        // [root cause #28] An access crossing a page boundary must be
        // translated per portion (ARM ARM; QEMU softmmu does the
        // same). The old code translated only the first page and
        // accessed PA-contiguously, corrupting data in
        // VA-contiguous / PA-scattered mappings (UPL windows over
        // page-cache pages — this was the launchd decmpfs hash
        // wall). Split at 4 KiB (the minimum granule); fast path
        // when the access lies within one 4 KiB page.
        var value: UInt64 = 0
        if (address & 0xFFF) &+ UInt64(size) <= 0x1000 {
            let pa = try translate(address: address, isWrite: false, isFetch: false)
            value = try readPhysical(pa, size: size)
        } else {
            var done = 0
            while done < size {
                let va = address &+ UInt64(done)
                let chunk = min(size - done, Int(0x1000 - (va & 0xFFF)))
                let pa = try translate(address: va, isWrite: false, isFetch: false)
                let part = try readPhysical(pa, size: chunk)
                value |= part << UInt64(8 * done)
                done += chunk
            }
        }
        if signExtendTo64 {
            let shift = 64 - signBit
            value = UInt64(bitPattern: (Int64(bitPattern: value << shift)) >> shift)
        }
        return value
    }

    private func storeValue(address: UInt64, size: Int, _ value: UInt64) throws {
        // [root cause #28] See loadValue: split page-crossing
        // stores at 4 KiB boundaries, translating each portion.
        if (address & 0xFFF) &+ UInt64(size) <= 0x1000 {
            let pa = try translate(address: address, isWrite: true, isFetch: false)
            try writePhysical(pa, size: size, value)
            return
        }
        var done = 0
        while done < size {
            let va = address &+ UInt64(done)
            let chunk = min(size - done, Int(0x1000 - (va & 0xFFF)))
            let pa = try translate(address: va, isWrite: true, isFetch: false)
            try writePhysical(pa, size: chunk, value >> UInt64(8 * done))
            done += chunk
        }
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
            return UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: v))) >> amt) & width
        default:                                                 // ROR
            if amt == 0 { return v }
            if is64 { return (v >> amt) | (v << (64 - amt)) }
            let v32 = UInt32(truncatingIfNeeded: v)
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
        if (insn & 0xFFFF_FBFF) == 0xD69F_0BFF { eret(); return }       // ERETAA / ERETAB（認証は省略）
        if (insn & 0xFFFF_FFE0) == 0xD69F_03E0 { eret(); return }       // ERET
        if (insn & 0xFFE0_001F) == 0xD400_0002 {                        // HVC
            executeHVC()
            return
        }
        if (insn & 0xFFE0_001F) == 0xD400_0003 {                        // SMC（PSCI 用に HVC と同じ処理）
            executeHVC()
            return
        }
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
                // 起床条件は保留状態のみ（マスク非依存）— run() 側の注記参照。
                // 割り込みが保留中なら idle に入らない（WFI は即座に完了する）。
                if platform == .vmApple {
                    if !(vmAppleFIQPending || vmAppleIRQPending) { idle = true }
                } else if !interruptPending { idle = true }
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
        if (insn & 0xFFFF_F800) == 0xD71F_0800 { pc = readReg(rn); return }        // BRAA / BRAB（認証は省略）
        if (insn & 0xFFFF_F800) == 0xD61F_0800 { pc = readReg(rn); return }        // BRAAZ（認証は省略）
        if (insn & 0xFFFF_F800) == 0xD63F_0800 { writeReg(30, pc); pc = readReg(rn); return } // BLRAAZ
        if (insn & 0xFFFF_F800) == 0xD73F_0800 { writeReg(30, pc); pc = readReg(rn); return } // BLRAA / BLRAB
        if (insn & 0xFFFF_FBFF) == 0xD65F_0BFF { pc = readReg(30); return }        // RETAA / RETAB
        if (insn & 0xFFFF_FC1F) == 0xD61F_0000 { pc = readReg(rn); return }        // BR
        if (insn & 0xFFFF_FC1F) == 0xD63F_0000 { writeReg(30, pc); pc = readReg(rn); return } // BLR
        if (insn & 0xFFFF_FC1F) == 0xD65F_0000 { pc = readReg(rn); return }        // RET

        // --- ポインタ認証（NOP 化: 署名と検証を同じコアが一貫して省略する）---
        if (insn & 0xFFE0_FC00) == 0x9AC0_3000 {                        // PACGA
            writeReg(rd, readReg(rn))
            return
        }
        if (insn & 0xFFFF_8000) == 0xDAC1_0000 {                        // PACIA/B, PACDA/B, AUTIA/B, AUTDA/B, XPAC
            // ポインタは Xd 自身にあり、Rn は修飾子。NOP 化 = Xd をそのまま保持する
            return
        }
        if (insn & 0xFF00_0000) == 0xF800_0000 && (insn & 0x0020_0000) != 0 && (insn & 0x0400) != 0 {
            // LDRAA / LDRAB: 認証なしの 8 バイトロードとして扱う（imm9 は 8 倍スケール）
            let imm9 = signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)
            let address = UInt64(bitPattern: Int64(bitPattern: readReg(rn, sp: true)) &+ Int64(bitPattern: imm9) * 8)
            writeReg(rd, try loadValue(address: address, size: 8))
            return
        }
        // FP / SIMD（ロード/ストア系は executeLoadStore 内で処理）
        if try executeFPOrSIMD(insn, rd: rd, rn: rn, rm: rm, at: instructionPC) { return }


        // --- ロード / ストア ---
        if try executeLoadStore(insn, rd: rd, rn: rn, rm: rm, at: instructionPC) { return }

        // --- データ処理（即値） ---
        if try executeDataImmediate(insn, rd: rd, rn: rn, at: instructionPC) { return }

        // --- データ処理（レジスタ） ---
        if try executeDataRegister(insn, rd: rd, rn: rn, rm: rm) { return }

        // 未定義命令（SIMD / FP など未実装の領域を含む）
        raiseSync(ec: 0x00, iss: 0, elr: instructionPC)
    }

    // MARK: - 命令デコードキャッシュ
    //
    // 命令ワード（32 ビット）→ 復号済み形式（DecodedInsn）の直接マップキャッシュ。
    // 復号はワードだけの純関数（監査済み: プラットフォーム / EL / PSTATE 等の
    // 可変状態に依存する判定は融合パス側に残し、ここでは行わない）。
    // フェッチは毎回現在のワードを読むため、自己書き換えコードでも
    // アドレス無効化は不要（ワードが変われば別のエントリになる）。
    // DECODE_CACHE=0 で無効化できる（A/B 検証用）。既定は有効。
    //
    // キャッシュ対象: 分岐 / PAC の一部 / データ即値 / データレジスタ /
    // ロード・ストアの主要形式。FP・SIMD・暗号・システム・CAS/LSE 等は
    // .fused として従来の融合パスに委譲し、意味論を完全に保存する。
    // 融合側で「受理空間に入るが false を返してフォールスルーする」サブケースも
    // .fused に落とすため、その挙動も同一になる。

    private let decodeCacheEnabled: Bool = ProcessInfo.processInfo.environment["DECODE_CACHE"] != "0"

    private enum DecodedOp: UInt8 {
        case fused = 0, undef, nop
        case b, bCond, cbz, tbz, brReg, pacga, ldraa
        case adr, addImm, logicImm, movWide, bitfield, extr
        case ldrLiteral, pairLS, lsUnsigned, lsRegOff, lsImm9, ldarStlr, ldxrStxr
        case logicShiftReg, addShiftReg, addExtReg, adcSbc, csel, ccmp, dp1src, dp2src, dp3src
    }

    // flags ビット割り当て（op ごとに意味が異なる。復号側のコメント参照）:
    //   bit0 (1)  : sf（64 ビット形）
    //   bit1 (2)  : setFlags
    //   bit2 (4)  : isSub / isCompare
    //   bit3 (8)  : invert（CBZ/TBZ の反転、論理シフトの N、条件選択の invertResult）
    //   bit4 (16) : リンク（B/BLR 系）/ 条件選択の increment
    //   bit5 (32) : ロード系の isLoad / CCMP の即値形式
    //   bit6 (64) : ADRP
    private struct DecodedInsn {
        var op: DecodedOp = .fused
        var rd: Int = 0
        var rn: Int = 0
        var rm: Int = 0
        var ra: Int = 0
        var imm: UInt64 = 0     // 主即値 / オフセット（符号拡張済みビットパターン）
        var immB: UInt64 = 0    // 副即値（MOVK のマスク等）
        var aux: Int = 0        // cond / bitPos / imms / option / mode / indexMode 等
        var f1: Int = 0         // opc / size / literalOpc 等
        var f2: Int = 0         // shiftType / amount / imms / opc 等
        var f3: Int = 0         // レジスタオフセット形式の shiftAmount 等
        var flags: UInt32 = 0
    }

    private struct DecodeSlot {
        var word: UInt32 = 0
        var valid: Bool = false
        var decoded = DecodedInsn()
    }

    private var decodeCache = [DecodeSlot](repeating: DecodeSlot(), count: 65536)

    private func executeCached(_ insn: UInt32, at instructionPC: UInt64) throws {
        let idx = Int(insn ^ (insn >> 16)) & 0xFFFF
        if decodeCache[idx].valid && decodeCache[idx].word == insn {
            let d = decodeCache[idx].decoded
            if d.op == .fused { try execute(insn, at: instructionPC); return }
            try executeDecoded(d, at: instructionPC)
            return
        }
        let d = decodeInsn(insn)
        decodeCache[idx].word = insn
        decodeCache[idx].decoded = d
        decodeCache[idx].valid = true
        if d.op == .fused { try execute(insn, at: instructionPC); return }
        try executeDecoded(d, at: instructionPC)
    }

    /// ワードの復号。execute() と各サブ実行関数の受理順・受理条件をそのまま写す。
    private func decodeInsn(_ insn: UInt32) -> DecodedInsn {
        var d = DecodedInsn()
        d.rd = Int(insn & 0x1F)
        d.rn = Int((insn >> 5) & 0x1F)
        d.rm = Int((insn >> 16) & 0x1F)
        if insn & 0x8000_0000 != 0 { d.flags |= 1 }   // sf

        // --- execute() プロローグ: 状態依存（ERET / SVC / HVC / WFI 等）のため融合へ ---
        if (insn & 0xFFFF_FBFF) == 0xD69F_0BFF { return d }       // ERETAA / ERETAB
        if (insn & 0xFFFF_FFE0) == 0xD69F_03E0 { return d }       // ERET
        if (insn & 0xFFE0_001F) == 0xD400_0002 { return d }       // HVC
        if (insn & 0xFFE0_001F) == 0xD400_0003 { return d }       // SMC
        if (insn & 0xFFE0_001F) == 0xD400_0001 { return d }       // SVC
        if (insn & 0xFFE0_001F) == 0xD420_0000 { return d }       // BRK
        if (insn & 0xFFFF_0000) == 0xD503_0000 && ((insn >> 12) & 0xF) < 4 { return d }  // HINT / WFI / CLREX
        if (insn & 0xFF00_0000) == 0xD500_0000 { return d }       // システム命令空間

        // --- 分岐 ---
        if (insn & 0x7C00_0000) == 0x1400_0000 {                        // B / BL
            d.op = .b
            d.imm = signExtend(UInt64(insn & 0x03FF_FFFF) << 2, bits: 28)
            if insn & 0x8000_0000 != 0 { d.flags |= 16 }                // BL
            return d
        }
        if (insn & 0xFF00_0010) == 0x5400_0000 {                        // B.cond
            d.op = .bCond
            d.imm = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
            d.aux = Int(insn & 0xF)
            return d
        }
        if (insn & 0x7E00_0000) == 0x3400_0000 {                        // CBZ / CBNZ
            d.op = .cbz
            d.imm = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
            if insn & 0x0100_0000 != 0 { d.flags |= 8 }
            return d
        }
        if (insn & 0x7E00_0000) == 0x3600_0000 {                        // TBZ / TBNZ
            d.op = .tbz
            d.imm = signExtend(UInt64((insn >> 5) & 0x3FFF) << 2, bits: 16)
            d.aux = Int(((insn >> 26) & 0x20) | ((insn >> 19) & 0x1F))
            if insn & 0x0100_0000 != 0 { d.flags |= 8 }
            return d
        }
        if (insn & 0xFFFF_F800) == 0xD71F_0800 { d.op = .brReg; return d }                    // BRAA / BRAB
        if (insn & 0xFFFF_F800) == 0xD61F_0800 { d.op = .brReg; return d }                    // BRAAZ
        if (insn & 0xFFFF_F800) == 0xD63F_0800 { d.op = .brReg; d.flags |= 16; return d }     // BLRAAZ
        if (insn & 0xFFFF_F800) == 0xD73F_0800 { d.op = .brReg; d.flags |= 16; return d }     // BLRAA / BLRAB
        if (insn & 0xFFFF_FBFF) == 0xD65F_0BFF { d.op = .brReg; d.rn = 30; return d }         // RETAA / RETAB
        if (insn & 0xFFFF_FC1F) == 0xD61F_0000 { d.op = .brReg; return d }                    // BR
        if (insn & 0xFFFF_FC1F) == 0xD63F_0000 { d.op = .brReg; d.flags |= 16; return d }     // BLR
        if (insn & 0xFFFF_FC1F) == 0xD65F_0000 { d.op = .brReg; return d }                    // RET

        // --- ポインタ認証 ---
        if (insn & 0xFFE0_FC00) == 0x9AC0_3000 { d.op = .pacga; return d }                    // PACGA
        if (insn & 0xFFFF_8000) == 0xDAC1_0000 { d.op = .nop; return d }                      // PAC / AUT / XPAC（NOP 化）
        if (insn & 0xFF00_0000) == 0xF800_0000 && (insn & 0x0020_0000) != 0 && (insn & 0x0400) != 0 {
            d.op = .ldraa                                                                     // LDRAA / LDRAB
            d.imm = UInt64(bitPattern: Int64(bitPattern: signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)) * 8)
            return d
        }

        // --- FP / SIMD ゲート: executeFPOrSIMD の受理空間はすべて融合へ ---
        if insn & 0x0400_0000 != 0 { return d }                                               // FP ロード / ストア入口（bit26）
        if (insn & 0x7F00_0000) == 0x1F00_0000 { return d }                                   // FP 3 ソース
        if (insn & 0x5E00_0000) == 0x1E00_0000 && insn & 0x4000_0000 == 0 { return d }        // FP スカラ
        let structTop = (insn >> 24) & 0xBF
        if structTop == 0x0C || structTop == 0x0D { return d }                                // 構造体ロード / ストア
        if (insn & 0x0E00_0000) == 0x0E00_0000 { return d }                                   // SIMD ベクタ / スカラ / 暗号

        // --- ロード / ストア → データ即値 → データレジスタ（元の試行順） ---
        if let ls = decodeLoadStore(insn, d) { return ls }
        if let di = decodeDataImmediate(insn, d) { return di }
        if let dr = decodeDataRegister(insn, d) { return dr }
        d.op = .undef
        return d
    }

    /// executeLoadStore の受理順の写し。受理しなければ nil（次の段へフォールスルー）。
    private func decodeLoadStore(_ insn: UInt32, _ base: DecodedInsn) -> DecodedInsn? {
        var d = base
        let size = Int((insn >> 30) & 0x3)
        let opc = Int((insn >> 22) & 0x3)
        // 排他アクセス / CAS 空間
        if (insn & 0x3F00_0000) == 0x0800_0000 {
            if insn & 0x0080_0000 != 0 && insn & 0x0020_0000 == 0
                && ((insn >> 16) & 0x1F) == 0x1F && insn & 0x0000_8000 != 0 {
                d.op = .ldarStlr                                                        // LDAR / STLR
                d.f1 = size
                if insn & 0x0040_0000 != 0 { d.flags |= 32 }
                return d
            }
            if insn & 0x0020_0000 != 0 { d.op = .fused; return d }                      // CAS / CASP は融合へ
            d.op = .ldxrStxr                                                            // LDXR / STXR 系
            d.f1 = size
            if insn & 0x0040_0000 != 0 { d.flags |= 32 } else { d.rm = Int((insn >> 16) & 0x1F) }  // STXR の Rs
            return d
        }
        // LSE アトミックは融合へ
        if (insn & 0x3F20_0C00) == 0x3820_0000 { d.op = .fused; return d }
        // LDR リテラル
        if (insn & 0x3B00_0000) == 0x1800_0000 {
            let literalOpc = Int((insn >> 30) & 0x3)
            if literalOpc == 3 { d.op = .nop; return d }                                // PRFM は NOP
            d.op = .ldrLiteral
            d.f1 = literalOpc
            d.imm = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
            return d
        }
        // ペア（LDP / STP / LDPSW）
        if (insn & 0x3A00_0000) == 0x2800_0000 && (insn & 0x0400_0000) == 0 {
            d.op = .pairLS
            let pairSize = size == 2 ? 8 : 4
            let imm7 = signExtend(UInt64((insn >> 15) & 0x7F), bits: 7)
            d.imm = UInt64(bitPattern: Int64(bitPattern: imm7) * Int64(pairSize))
            d.aux = Int((insn >> 23) & 0x7)                                             // mode
            d.f1 = pairSize
            d.f2 = size                                                                 // LDPSW 判定（== 1）
            d.rm = Int((insn >> 10) & 0x1F)                                             // Rt2
            if insn & 0x0040_0000 != 0 { d.flags |= 32 }                                // isLoad
            return d
        }
        // 単一ロード / ストア: 符号なし即値オフセット
        if (insn & 0x3B00_0000) == 0x3900_0000 {
            d.op = .lsUnsigned
            d.f1 = size
            d.f2 = opc
            d.imm = UInt64((insn >> 10) & 0xFFF) << size
            return d
        }
        // レジスタオフセット
        if (insn & 0x3B20_0C00) == 0x3820_0800 {
            d.op = .lsRegOff
            d.f1 = size
            d.f2 = opc
            d.aux = Int((insn >> 13) & 0x7)                                             // option
            d.f3 = ((insn >> 12) & 1) == 1 ? size : 0                                   // shiftAmount
            return d
        }
        // 即値 9 ビット（アンスケールド / プレ / ポスト）
        if (insn & 0x3B20_0000) == 0x3800_0000 {
            d.op = .lsImm9
            d.f1 = size
            d.f2 = opc
            d.imm = signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)
            d.aux = Int((insn >> 10) & 0x3)                                             // indexMode
            return d
        }
        return nil
    }

    /// executeDataImmediate の受理順の写し。
    private func decodeDataImmediate(_ insn: UInt32, _ base: DecodedInsn) -> DecodedInsn? {
        var d = base
        let sf = insn & 0x8000_0000 != 0
        // ADR / ADRP
        if (insn & 0x1F00_0000) == 0x1000_0000 {
            d.op = .adr
            d.imm = signExtend((UInt64(insn & 0x6000_0000) >> 29) | (UInt64((insn >> 5) & 0x7_FFFF) << 2), bits: 21)
            if insn & 0x8000_0000 != 0 { d.flags |= 64 }                                // ADRP
            return d
        }
        // ADD / SUB（即値）
        if (insn & 0x1F00_0000) == 0x1100_0000 {
            d.op = .addImm
            var imm = UInt64((insn >> 10) & 0xFFF)
            if insn & 0x0040_0000 != 0 { imm <<= 12 }
            d.imm = imm
            if insn & 0x4000_0000 != 0 { d.flags |= 4 }                                 // isSub
            if insn & 0x2000_0000 != 0 { d.flags |= 2 }                                 // setFlags
            return d
        }
        // 論理（即値）: ビットマスク即値はワードの純関数なので復号時に確定させる
        if (insn & 0x1F80_0000) == 0x1200_0000 {
            guard let imm = decodeBitMasks(n: Int((insn >> 22) & 1), imms: Int((insn >> 10) & 0x3F),
                                           immr: Int((insn >> 16) & 0x3F), is64: sf) else {
                d.op = .undef                                                           // 元実装は raiseSync して受理
                return d
            }
            d.op = .logicImm
            d.imm = imm
            d.f1 = Int((insn >> 29) & 0x3)                                              // opc
            return d
        }
        // Move wide（MOVZ / MOVN / MOVK）
        if (insn & 0x1F80_0000) == 0x1280_0000 {
            let opc = Int((insn >> 29) & 0x3)
            if opc == 1 { d.op = .undef; return d }                                     // 元実装は raiseSync して受理
            let hw = Int((insn >> 21) & 0x3) * 16
            d.op = .movWide
            d.f1 = opc
            d.imm = UInt64((insn >> 5) & 0xFFFF) << hw
            d.immB = ~(UInt64(0xFFFF) << hw)                                            // MOVK の保持マスク
            return d
        }
        // ビットフィールド（SBFM / BFM / UBFM）
        if (insn & 0x1F80_0000) == 0x1300_0000 {
            d.op = .bitfield
            d.f1 = Int((insn >> 29) & 0x3)                                              // opc
            d.aux = Int((insn >> 16) & 0x3F)                                            // immr
            d.f2 = Int((insn >> 10) & 0x3F)                                             // imms
            return d
        }
        // EXTR
        if (insn & 0x1F80_0000) == 0x1380_0000 {
            d.op = .extr
            d.aux = Int((insn >> 10) & 0x3F)                                            // imms
            return d
        }
        return nil
    }

    /// executeDataRegister の受理順の写し。
    private func decodeDataRegister(_ insn: UInt32, _ base: DecodedInsn) -> DecodedInsn? {
        var d = base
        let sf = insn & 0x8000_0000 != 0
        // 論理（シフト付きレジスタ）
        if [0x0A00_0000, 0x2A00_0000, 0x4A00_0000, 0x6A00_0000].contains(insn & 0x1F00_0000) {
            d.op = .logicShiftReg
            d.f1 = Int((insn >> 29) & 0x3)                                              // opc
            if insn & 0x0020_0000 != 0 { d.flags |= 8 }                                 // invert (N)
            d.f2 = Int((insn >> 22) & 0x3)                                              // shiftType
            d.aux = Int((insn >> 10) & 0x3F)                                            // amount
            return d
        }
        // ADD / SUB（シフト付きレジスタ）
        if (insn & 0x1F20_0000) == 0x0B00_0000 {
            d.op = .addShiftReg
            if insn & 0x4000_0000 != 0 { d.flags |= 4 }
            if insn & 0x2000_0000 != 0 { d.flags |= 2 }
            d.f2 = Int((insn >> 22) & 0x3)
            d.aux = Int((insn >> 10) & 0x3F)
            return d
        }
        // ADD / SUB（拡張レジスタ）
        if (insn & 0x1F20_0000) == 0x0B20_0000 {
            d.op = .addExtReg
            if insn & 0x4000_0000 != 0 { d.flags |= 4 }
            if insn & 0x2000_0000 != 0 { d.flags |= 2 }
            d.aux = Int((insn >> 13) & 0x7)                                             // option
            d.f2 = Int((insn >> 10) & 0x7)                                              // amount
            return d
        }
        // ADC / SBC
        if (insn & 0x1FE0_0000) == 0x1A00_0000 {
            d.op = .adcSbc
            if insn & 0x4000_0000 != 0 { d.flags |= 4 }
            if insn & 0x2000_0000 != 0 { d.flags |= 2 }
            return d
        }
        // 条件選択（CSEL / CSINC / CSINV / CSNEG）
        if (insn & 0x1FE0_0000) == 0x1A80_0000 {
            d.op = .csel
            d.aux = Int((insn >> 12) & 0xF)                                             // cond
            if insn & 0x4000_0000 != 0 { d.flags |= 8 }                                 // invertResult
            if insn & 0x0000_0400 != 0 { d.flags |= 16 }                                // increment
            return d
        }
        // 条件比較（CCMP / CCMN）
        if (insn & 0x3FE0_0000) == 0x3A40_0000 {
            d.op = .ccmp
            if insn & 0x4000_0000 != 0 { d.flags |= 4 }                                 // isCompare
            d.aux = Int((insn >> 12) & 0xF)                                             // cond
            if insn & 0x0000_0800 != 0 {                                                // 即値形式
                d.flags |= 32
                d.imm = UInt64((insn >> 16) & 0x1F)
            }
            return d
        }
        // データ処理（2 ソース / 1 ソース）
        if (insn & 0x1FE0_0000) == 0x1AC0_0000 {
            let opcode = Int((insn >> 10) & 0x3F)
            if insn & 0x4000_0000 != 0 {
                // 1 ソース（RBIT / REV16 / REV / CLZ / CLS）
                switch opcode {
                case 0x00, 0x01, 0x04, 0x05:
                    d.op = .dp1src; d.f1 = opcode; return d
                case 0x02:  // REV32 は 32 ビット形のみ（64 ビット形は元実装が false）
                    if sf { d.op = .fused; return d }
                    d.op = .dp1src; d.f1 = opcode; return d
                case 0x03:  // REV は 64 ビット形のみ
                    if !sf { d.op = .fused; return d }
                    d.op = .dp1src; d.f1 = opcode; return d
                default:
                    d.op = .fused; return d
                }
            }
            // 2 ソース
            switch opcode {
            case 0x02, 0x03, 0x08, 0x09, 0x0A, 0x0B:
                d.op = .dp2src; d.f1 = opcode; return d
            default:
                d.op = .fused; return d
            }
        }
        // データ処理（3 ソース）
        if (insn & 0x1F00_0000) == 0x1B00_0000 {
            d.ra = Int((insn >> 10) & 0x1F)
            switch insn & 0x7FE0_8000 {
            case 0x1B00_0000: d.op = .dp3src; d.f1 = 0; return d                        // MADD
            case 0x1B00_8000: d.op = .dp3src; d.f1 = 1; return d                        // MSUB
            case 0x1B40_0000: d.op = .dp3src; d.f1 = 2; return d                        // SMULH
            case 0x1BC0_0000: d.op = .dp3src; d.f1 = 3; return d                        // UMULH
            case 0x1B20_0000:                                                           // SMADDL（64 ビット形のみ）
                if sf { d.op = .dp3src; d.f1 = 4; return d }
                d.op = .fused; return d
            case 0x1B20_8000:                                                           // SMSUBL
                if sf { d.op = .dp3src; d.f1 = 5; return d }
                d.op = .fused; return d
            case 0x1BA0_0000:                                                           // UMADDL
                if sf { d.op = .dp3src; d.f1 = 6; return d }
                d.op = .fused; return d
            case 0x1BA0_8000:                                                           // UMSUBL
                if sf { d.op = .dp3src; d.f1 = 7; return d }
                d.op = .fused; return d
            default:
                d.op = .fused; return d
            }
        }
        return nil
    }

    /// 復号済み形式の実行。各ケースは対応する融合パスの命令本体の写し。
    private func executeDecoded(_ d: DecodedInsn, at instructionPC: UInt64) throws {
        let sf = d.flags & 1 != 0
        switch d.op {
        case .fused:
            return  // 呼び出し側で融合パスに振り分けるため、ここには来ない
        case .undef:
            raiseSync(ec: 0x00, iss: 0, elr: instructionPC)
        case .nop:
            return
        case .b:
            if d.flags & 16 != 0 { writeReg(30, pc) }
            pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm))
        case .bCond:
            if conditionHolds(d.aux) {
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm))
            }
        case .cbz:
            var value = readReg(d.rd)
            if !sf { value &= 0xFFFF_FFFF }
            if (value == 0) != (d.flags & 8 != 0) {
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm))
            }
        case .tbz:
            let bit = (readReg(d.rd) >> d.aux) & 1
            if (bit == 1) == (d.flags & 8 != 0) {
                pc = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm))
            }
        case .brReg:
            if d.flags & 16 != 0 { writeReg(30, pc) }
            pc = readReg(d.rn)
        case .pacga:
            writeReg(d.rd, readReg(d.rn))
        case .ldraa:
            let address = UInt64(bitPattern: Int64(bitPattern: readReg(d.rn, sp: true)) &+ Int64(bitPattern: d.imm))
            writeReg(d.rd, try loadValue(address: address, size: 8))
        case .adr:
            if d.flags & 64 != 0 {  // ADRP
                let base = instructionPC & ~0xFFF
                writeReg(d.rd, UInt64(bitPattern: Int64(bitPattern: base) &+ (Int64(bitPattern: d.imm) << 12)))
            } else {
                writeReg(d.rd, UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm)))
            }
        case .addImm:
            let isSub = d.flags & 4 != 0
            let setFlags = d.flags & 2 != 0
            let a = readReg(d.rn, sp: true)
            let r = addWithCarry(a, isSub ? ~d.imm : d.imm, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(d.rd, r.result, sp: !setFlags, width64: sf)
        case .logicImm:
            let a = readReg(d.rn)
            let result: UInt64
            switch d.f1 {
            case 0: result = a & d.imm
            case 1: result = a | d.imm
            case 2: result = a ^ d.imm
            default:
                result = a & d.imm
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            // 宛先 Rd=31 は AND/ORR/EOR では SP（ANDS は XZR）。QEMU gen_rri_log 準拠（根本原因 #31）
            let writeValue = sf ? result : (result & 0xFFFF_FFFF)
            writeReg(d.rd, writeValue, sp: d.f1 != 3, width64: sf)
        case .movWide:
            switch d.f1 {
            case 0: writeReg(d.rd, ~d.imm, width64: sf)                                 // MOVN
            case 2: writeReg(d.rd, d.imm, width64: sf)                                  // MOVZ
            default:                                                                    // MOVK
                var current = readReg(d.rd)
                current = (current & d.immB) | d.imm
                writeReg(d.rd, current, width64: sf)
            }
        case .bitfield:
            let opc = d.f1
            let immr = d.aux
            let imms = d.f2
            let width = sf ? 64 : 32
            let source = readReg(d.rn)
            let result: UInt64
            if imms >= immr {
                let bits = imms - immr + 1
                let mask = bits >= 64 ? UInt64.max : ((UInt64(1) << bits) - 1)
                let extracted = (source >> immr) & mask
                switch opc {
                case 0: result = signExtend(extracted, bits: bits) & (sf ? UInt64.max : 0xFFFF_FFFF)  // SBFM
                case 1:
                    let dest = readReg(d.rd)
                    result = (dest & ~mask) | extracted                                              // BFM
                default: result = extracted                                                          // UBFM
                }
            } else {
                let bits = imms + 1
                let mask = ((UInt64(1) << bits) - 1) << (width - immr)
                let inserted = (source << (width - immr)) & mask
                switch opc {
                case 0:
                    let signTopPos = (width - immr) + imms
                    let sh = 63 - signTopPos
                    result = UInt64(bitPattern: (Int64(bitPattern: inserted) << sh) >> sh) & (sf ? UInt64.max : 0xFFFF_FFFF)
                case 1:
                    let dest = readReg(d.rd)
                    result = (dest & ~mask) | inserted
                default: result = inserted
                }
            }
            writeReg(d.rd, result, width64: sf)
        case .extr:
            let imms = d.aux
            let hi = readReg(d.rn)
            let lo = readReg(d.rm)
            let result: UInt64
            if sf {
                result = imms == 0 ? lo : ((hi << (64 - imms)) | (lo >> imms))
            } else {
                let combined = (UInt64(UInt32(truncatingIfNeeded: hi)) << 32) | UInt64(UInt32(truncatingIfNeeded: lo))
                result = UInt64(UInt32((combined >> imms) & 0xFFFF_FFFF))
            }
            writeReg(d.rd, result, width64: sf)
        case .ldrLiteral:
            let address = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: d.imm))
            switch d.f1 {
            case 0: writeReg(d.rd, try loadValue(address: address, size: 4), width64: false)
            case 1: writeReg(d.rd, try loadValue(address: address, size: 8))
            default: writeReg(d.rd, try loadValue(address: address, size: 4, signExtendTo64: true, signBit: 32))
            }
        case .pairLS:
            let pairSize = d.f1
            let base = readReg(d.rn, sp: true)
            let offset = Int64(bitPattern: d.imm)
            var address = base
            switch d.aux {
            case 1: address = base
            default: address = UInt64(bitPattern: Int64(bitPattern: base) &+ offset)
            }
            if d.flags & 32 != 0 {  // ロード
                let first = try loadValue(address: address, size: pairSize)
                let second = try loadValue(address: address &+ UInt64(pairSize), size: pairSize)
                if d.f2 == 1 {  // LDPSW
                    writeReg(d.rd, signExtend(first, bits: 32))
                    writeReg(d.rm, signExtend(second, bits: 32))
                } else {
                    writeReg(d.rd, first, width64: pairSize == 8)
                    writeReg(d.rm, second, width64: pairSize == 8)
                }
            } else {
                try storeValue(address: address, size: pairSize, readReg(d.rd))
                try storeValue(address: address &+ UInt64(pairSize), size: pairSize, readReg(d.rm))
            }
            if d.aux == 1 || d.aux == 3 {
                writeReg(d.rn, UInt64(bitPattern: Int64(bitPattern: base) &+ offset), sp: true)
            }
        case .lsUnsigned, .lsRegOff, .lsImm9:
            let size = d.f1
            let bytes = 1 << size
            let base = readReg(d.rn, sp: true)
            let address: UInt64
            var writeback: UInt64? = nil
            switch d.op {
            case .lsUnsigned:
                address = base &+ d.imm
            case .lsRegOff:
                let offset = extendValue(readReg(d.rm), option: d.aux, shift: d.f3)
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: offset))
            default:  // .lsImm9
                switch d.aux {
                case 1:  // ポストインデックス
                    address = base
                    writeback = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: d.imm))
                case 3:  // プレインデックス
                    address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: d.imm))
                    writeback = address
                default: // アンスケールド / 非特権
                    address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: d.imm))
                }
            }
            switch d.f2 {  // opc
            case 0:  // ストア
                try storeValue(address: address, size: bytes, readReg(d.rd))
            case 1:  // ロード（ゼロ拡張）
                writeReg(d.rd, try loadValue(address: address, size: bytes), width64: bytes == 8)
            case 2:  // ロード（64 ビットへ符号拡張）
                writeReg(d.rd, try loadValue(address: address, size: bytes, signExtendTo64: true, signBit: bytes * 8))
            default: // ロード（32 ビットへ符号拡張）
                let value = try loadValue(address: address, size: bytes, signExtendTo64: true, signBit: bytes * 8)
                writeReg(d.rd, value & 0xFFFF_FFFF, width64: false)
            }
            if let writeback {
                writeReg(d.rn, writeback, sp: true)
            }
        case .ldarStlr:
            let bytes = 1 << d.f1
            let base = readReg(d.rn, sp: true)
            if d.flags & 32 != 0 {  // LDAR
                let value = try loadValue(address: base, size: bytes)
                writeReg(d.rd, value, width64: bytes == 8)
            } else {                // STLR
                try storeValue(address: base, size: bytes, readReg(d.rd))
            }
        case .ldxrStxr:
            let bytes = 1 << d.f1
            let base = readReg(d.rn, sp: true)
            if d.flags & 32 != 0 {  // LDXR / LDAXR
                let value = try loadValue(address: base, size: bytes)
                exclusiveAddress = base
                writeReg(d.rd, value, width64: bytes == 8)
            } else {                // STXR / STLXR: rm フィールドは Rs
                if exclusiveAddress == base {
                    try storeValue(address: base, size: bytes, readReg(d.rd))
                    writeReg(d.rm, 0)
                } else {
                    writeReg(d.rm, 1)
                }
                exclusiveAddress = nil
            }
        case .logicShiftReg:
            var operand = shiftValue(readReg(d.rm), type: UInt32(d.f2), amount: d.aux, is64: sf)
            if d.flags & 8 != 0 { operand = ~operand }
            let a = readReg(d.rn)
            let result: UInt64
            switch d.f1 {
            case 0: result = a & operand
            case 1: result = a | operand
            case 2: result = a ^ operand
            default:
                result = a & operand
                let masked = sf ? result : (result & 0xFFFF_FFFF)
                setNZCV(n: (masked >> (sf ? 63 : 31)) & 1 == 1, z: masked == 0, c: false, v: false)
            }
            writeReg(d.rd, result, width64: sf)
        case .addShiftReg:
            let isSub = d.flags & 4 != 0
            let setFlags = d.flags & 2 != 0
            let operand = shiftValue(readReg(d.rm), type: UInt32(d.f2), amount: d.aux, is64: sf)
            let a = readReg(d.rn)
            let r = addWithCarry(a, isSub ? ~operand : operand, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(d.rd, r.result, width64: sf)
        case .addExtReg:
            let isSub = d.flags & 4 != 0
            let setFlags = d.flags & 2 != 0
            let operand = extendValue(readReg(d.rm), option: d.aux, shift: d.f2)
            let a = readReg(d.rn, sp: true)
            let r = addWithCarry(a, isSub ? ~operand : operand, carry: isSub, is64: sf)
            if setFlags { applyFlags(r) }
            writeReg(d.rd, r.result, sp: !setFlags, width64: sf)
        case .adcSbc:
            let isSub = d.flags & 4 != 0
            let a = readReg(d.rn)
            let b = readReg(d.rm)
            let r = addWithCarry(a, isSub ? ~b : b, carry: flagC, is64: sf)
            if d.flags & 2 != 0 { applyFlags(r) }
            writeReg(d.rd, r.result, width64: sf)
        case .csel:
            let other = readReg(d.rm)
            let result: UInt64
            if conditionHolds(d.aux) {
                result = readReg(d.rn)
            } else if d.flags & 8 != 0 && d.flags & 16 != 0 {
                result = ~other &+ 1                       // CSNEG
            } else if d.flags & 8 != 0 {
                result = ~other                            // CSINV
            } else if d.flags & 16 != 0 {
                result = other &+ 1                        // CSINC
            } else {
                result = other                             // CSEL
            }
            writeReg(d.rd, result, width64: sf)
        case .ccmp:
            if conditionHolds(d.aux) {
                let a = readReg(d.rn)
                let b: UInt64
                if d.flags & 32 != 0 {
                    b = d.imm                              // 即値形式
                } else {
                    b = readReg(d.rm)
                }
                let isCompare = d.flags & 4 != 0
                let r = addWithCarry(a, isCompare ? ~b : b, carry: isCompare, is64: sf)
                applyFlags(r)
            } else {
                let nzcv = UInt32(d.rd) & 0xF              // 元実装はワード下位 4 ビット（= rd の下位）
                setNZCV(n: nzcv & 0x8 != 0, z: nzcv & 0x4 != 0, c: nzcv & 0x2 != 0, v: nzcv & 0x1 != 0)
            }
        case .dp1src:
            let a = readReg(d.rn)
            let result: UInt64
            switch d.f1 {
            case 0x00:  // RBIT
                result = sf ? reverseBits(a) : UInt64(reverseBits32(UInt32(truncatingIfNeeded: a)))
            case 0x01:  // REV16
                result = sf ? byteSwap16(a) : UInt64(byteSwap16(UInt64(UInt32(a))) & 0xFFFF_FFFF)
            case 0x02:  // REV32（32 ビット形のみ復号される）
                result = UInt64(UInt32(truncatingIfNeeded: a).byteSwapped)
            case 0x03:  // REV（64 ビット形のみ復号される）
                result = a.byteSwapped
            case 0x04:  // CLZ
                result = UInt64(sf ? a.leadingZeroBitCount : UInt32(truncatingIfNeeded: a).leadingZeroBitCount)
            default:    // CLS（0x05）
                result = UInt64(countLeadingSignBits(a, is64: sf))
            }
            writeReg(d.rd, result, width64: sf)
        case .dp2src:
            let a = readReg(d.rn)
            let b = readReg(d.rm)
            let amount = Int(b & (sf ? 63 : 31))
            let result: UInt64
            switch d.f1 {
            case 0x02:  // UDIV
                result = (sf ? b : (b & 0xFFFF_FFFF)) == 0 ? 0 : (sf ? a / b : (a & 0xFFFF_FFFF) / (b & 0xFFFF_FFFF))
            case 0x03:  // SDIV
                result = signedDivide(a, b, is64: sf)
            case 0x08: result = shiftValue(a, type: 0, amount: amount, is64: sf)   // LSL
            case 0x09: result = shiftValue(a, type: 1, amount: amount, is64: sf)   // LSR
            case 0x0A: result = shiftValue(a, type: 2, amount: amount, is64: sf)   // ASR
            default: result = shiftValue(a, type: 3, amount: amount, is64: sf)     // ROR（0x0B）
            }
            writeReg(d.rd, result, width64: sf)
        case .dp3src:
            let a = readReg(d.rn)
            let b = readReg(d.rm)
            let addend = readReg(d.ra)
            switch d.f1 {
            case 0:  // MADD
                writeReg(d.rd, addend &+ (a &* b), width64: sf)
            case 1:  // MSUB
                writeReg(d.rd, addend &- (a &* b), width64: sf)
            case 2:  // SMULH
                let product = Int64(bitPattern: a).multipliedFullWidth(by: Int64(bitPattern: b))
                writeReg(d.rd, UInt64(bitPattern: product.high))
            case 3:  // UMULH
                let product = a.multipliedFullWidth(by: b)
                writeReg(d.rd, product.high)
            case 4:  // SMADDL
                let product = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) * Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b)))
                writeReg(d.rd, UInt64(bitPattern: Int64(bitPattern: addend) &+ product))
            case 5:  // SMSUBL
                let product = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) * Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b)))
                writeReg(d.rd, UInt64(bitPattern: Int64(bitPattern: addend) &- product))
            case 6:  // UMADDL
                let product = UInt64(UInt32(truncatingIfNeeded: a)) * UInt64(UInt32(truncatingIfNeeded: b))
                writeReg(d.rd, addend &+ product)
            default:  // UMSUBL（7）
                let product = UInt64(UInt32(truncatingIfNeeded: a)) * UInt64(UInt32(truncatingIfNeeded: b))
                writeReg(d.rd, addend &- product)
            }
        }
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
            let a = readReg(rn, sp: true)   // ソース Rn=31 はフラグ形式（CMP）でも SP（QEMU で実証）
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
            // 宛先 Rd=31 は AND/ORR/EOR では SP（ANDS は XZR）。QEMU gen_rri_log の
            // cpu_reg_sp 準拠（根本原因 #31: start の `and sp, x0, #~0xF` が無効化されていた）
            let writeValue = sf ? result : (result & 0xFFFF_FFFF)
            writeReg(rd, writeValue, sp: opc != 3, width64: sf)
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
                let combined = (UInt64(UInt32(truncatingIfNeeded: hi)) << 32) | UInt64(UInt32(truncatingIfNeeded: lo))
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
            let a = readReg(rn)   // シフト付きレジスタ形式では Rn/Rd=31 は常に XZR（SP が使えるのは即値/拡張形式のみ。NEG の誤動作＝根本原因 #18）
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
            let a = readReg(rn, sp: true)   // ソース Rn=31 はフラグ形式でも SP
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
                    result = sf ? reverseBits(a) : UInt64(reverseBits32(UInt32(truncatingIfNeeded: a)))
                case 0x01:  // REV16
                    result = sf ? byteSwap16(a) : UInt64(byteSwap16(UInt64(UInt32(a))) & 0xFFFF_FFFF)
                case 0x02:  // REV32（32 ビット形のみ）
                    if sf { return false }
                    result = UInt64(UInt32(truncatingIfNeeded: a).byteSwapped)
                case 0x03:  // REV（64 ビット形のみ）
                    if !sf { return false }
                    result = a.byteSwapped
                case 0x04:  // CLZ
                    result = UInt64(sf ? a.leadingZeroBitCount : UInt32(truncatingIfNeeded: a).leadingZeroBitCount)
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
                let product = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) * Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b)))
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: addend) &+ product))
            case 0x1B20_8000 where sf:  // SMSUBL
                let product = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) * Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b)))
                writeReg(rd, UInt64(bitPattern: Int64(bitPattern: addend) &- product))
            case 0x1BA0_0000 where sf:  // UMADDL
                let product = UInt64(UInt32(truncatingIfNeeded: a)) * UInt64(UInt32(truncatingIfNeeded: b))
                writeReg(rd, addend &+ product)
            case 0x1BA0_8000 where sf:  // UMSUBL
                let product = UInt64(UInt32(truncatingIfNeeded: a)) * UInt64(UInt32(truncatingIfNeeded: b))
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
            // LDAR / STLR（順序付きアクセス）: bit23=1, bit21=0, Rs フィールド=31, bit15=1。
            // これを STXR と誤認するとストアが排他モニタ条件で静かに落ち、
            // チケットロックの解放（stlrb）が失われてデッドロックする。
            if insn & 0x0080_0000 != 0 && insn & 0x0020_0000 == 0
                && ((insn >> 16) & 0x1F) == 0x1F && insn & 0x0000_8000 != 0 {
                if insn & 0x0040_0000 != 0 {
                    // LDAR
                    let value = try loadValue(address: base, size: bytes)
                    writeReg(rd, value, width64: bytes == 8)
                } else {
                    // STLR
                    try storeValue(address: base, size: bytes, readReg(rd))
                }
                return true
            }
            if insn & 0x0020_0000 != 0 {
                let rs = Int((insn >> 16) & 0x1F)
                if insn & 0x0080_0000 == 0 {
                    // CASP: レジスタペアの CAS（bit23=0）。要素サイズは bit30 で選択。
                    // ペアレジスタは偶数かつ 30 以下が正規符号化（範囲外は未割り当てとして弾く）
                    guard rs % 2 == 0 && rs <= 30 && rd % 2 == 0 && rd <= 30 else { return false }
                    let elem = insn & 0x4000_0000 != 0 ? 8 : 4
                    let maskP: UInt64 = elem == 8 ? UInt64.max : 0xFFFF_FFFF
                    let expLo = readReg(rs) & maskP
                    let expHi = readReg(rs + 1) & maskP
                    let oldLo = try loadValue(address: base, size: elem)
                    let oldHi = try loadValue(address: base &+ UInt64(elem), size: elem)
                    if oldLo == expLo && oldHi == expHi {
                        try storeValue(address: base, size: elem, readReg(rd) & maskP)
                        try storeValue(address: base &+ UInt64(elem), size: elem, readReg(rd + 1) & maskP)
                    }
                    writeReg(rs, oldLo, width64: elem == 8)
                    writeReg(rs + 1, oldHi, width64: elem == 8)
                    return true
                }
                // CAS: Rs = 期待値、Rt = 新しい値（旧値を返す）
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
        if (insn & 0x3F20_0C00) == 0x3820_0000 {
            let rs = Int((insn >> 16) & 0x1F)
            let operand = readReg(rs)
            let old = try loadValue(address: base, size: bytes)
            if ((insn >> 12) & 0xF) == 0b1100 {
                // LDAPR 系: 読み取りのみ（書き戻しなし）
                writeReg(rd, old, width64: bytes == 8)
                return true
            }
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
            case (0, 4):  // PAN（SPSR の bit22 に保持し、例外/ERET で自動的に保存・復元される）
                if imm4 & 1 != 0 { pstate |= (1 << 22) } else { pstate &= ~(1 << 22) }
            case (0, 3):  // UAO（bit23）
                if imm4 & 1 != 0 { pstate |= (1 << 23) } else { pstate &= ~(1 << 23) }
            case (3, 6):  // DAIFSet
                for i in 0..<4 where (imm4 >> i) & 1 == 1 { pstate |= UInt32(1 << (6 + i)) }
            case (3, 7):  // DAIFClr
                for i in 0..<4 where (imm4 >> i) & 1 == 1 { pstate &= ~UInt32(1 << (6 + i)) }
            default:
                break
            }
            return
        }
        // DC ZVA: 64 バイトブロックをゼロ化する（メモリへの実効果があるため no-op にできない）
        if !isRead && op0 == 1 && op1 == 3 && crn == 7 && crm == 4 && op2 == 1 {
            let blockBase = readReg(rt) & ~UInt64(0x3F)
            for i in 0..<8 {
                try storeValue(address: blockBase + UInt64(i * 8), size: 8, 0)
            }
            return
        }
        // AT（アドレス変換）: 結果を PAR_EL1 に書き込む。XNU の kvtophys が AT S1E1R + PAR_EL1 で
        // VA→PA 変換を行うため、no-op では済まない（PAR が 0 のままだと変換失敗と誤認される）
        if !isRead && op0 == 1 && crn == 7 && crm == 8 {
            let va = readReg(rt)
            let writeAccess = (op2 & 1) == 1
            if let pa = try? translate(address: va, isWrite: writeAccess, isFetch: false) {
                parEL1 = (pa & 0x0000_FFFF_FFFF_F000) | (UInt64(0b10) << 7)  // F=0、SH=インナーシェアラブル
            } else {
                parEL1 = 1 | (UInt64(0b000100) << 1)  // F=1、FST=変換フォルト
            }
            return
        }
        // SYS 命令（TLBI / その他のキャッシュ保守）は、変換を毎回行うため無動作で正しい
        if !isRead && op0 <= 1 { return }

        // TPIDR_EL0 / TPIDRRO_EL0（S3_3_C13_C0_2 / _3）: writeSysReg の default は
        // .vmApple 以外では書き込みを保持しないため、全プラットフォームで効くよう
        // フィールドが分かれているここで専用ストレージへ振り分ける。
        if op0 == 3 && op1 == 3 && crn == 13 && crm == 0 {
            if op2 == 2 {  // TPIDR_EL0
                if isRead { writeReg(rt, tpidrEL0) } else { tpidrEL0 = readReg(rt) }
                return
            }
            if op2 == 3 {  // TPIDRRO_EL0: EL0 からは読み取り専用、EL1 からは書き込み可（QEMU: PL0_R | PL1_W）
                if isRead { writeReg(rt, tpidrROEL0) } else if currentEL >= 1 { tpidrROEL0 = readReg(rt) }
                return
            }
        }

        var key = (op0 << 13) | (op1 << 10) | (crn << 6) | (crm << 3) | op2
        if platform == .vmApple && currentEL == 2 && (hcrEL2 >> 34) & 1 == 1 {
            key = Self.vheRedirectedKey(key)
        }
        if isRead {
            let value = readSysReg(key)
            onSysRegAccess?(true, key, value, instructionPC)
            writeReg(rt, value)
        } else {
            onSysRegAccess?(false, key, readReg(rt), instructionPC)
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
        case 0x61E0: return parEL1
        case 0x6108: return spEL0
        case 0x7108: return spEL1
        case 0x6112: return UInt64(currentEL) << 2          // CurrentEL
        case 0x6D10: return UInt64(pstate & 0xF000_0000)    // NZCV
        case 0x6113: return UInt64((pstate >> 22) & 1)       // PAN
        case 0x6114: return UInt64((pstate >> 23) & 1)       // UAO
        case 0x6110: return UInt64(pstate & 1)               // SPSel
        case 0x6D11: return UInt64((pstate >> 6) & 0xF) << 6  // DAIF
        case 0x6C01: return 0x3444_8004                    // CTR_EL0（I/D ライン 64B、IDC/DIC）
        case 0x6C07: return 4                              // DCZID_EL0（BS=4: ZVA ブロック 64 バイト）
        case 0x6000: return platform == .vmApple ? 0x610F_0000 : 0x410F_D034   // MIDR
        case 0x6020: return platform == .vmApple ? 0x0100_0111 : 0             // ID_AA64PFR0（EL0/1/2, FP/SIMD, GIC sysreg）
        case 0x6031: return platform == .vmApple ? 0x0100_0010 : 0             // ID_AA64ISAR1（PAC アーキテクチャ）
        case 0x6005: return 0x8000_0000                     // MPIDR（単一コア）
        case 0x6038:  // ID_AA64MMFR0
            return platform == .vmApple ? 0x0000_0025 : 0x0FF0_0022   // VMAPPLE: 48bit PA / 16bit ASID / TGran16=0 (16K 対応)
        case 0x6F80: return timerFrequency                  // CNTFRQ_EL0
        case 0x6F81: return counterValue()                  // CNTPCT_EL0
        case 0x6F82: return counterValue() &- cntvOff       // CNTVCT_EL0
        case 0x6F90:                                        // CNTP_TVAL
            return UInt64(UInt32(truncatingIfNeeded: cntpCval &- counterValue()))
        case 0x6F98, 0x6FA8:                                // CNTV_TVAL
            return UInt64(UInt32(truncatingIfNeeded: cntvCval &- (counterValue() &- cntvOff)))
        case 0x6F91:                                        // CNTP_CTL
            return (cntpCtl & 0x3) | (timerExpired ? 0x4 : 0)
        case 0x6F99, 0x6FA9:                                // CNTV_CTL
            return (cntvCtl & 0x3) | (cntvExpired ? 0x4 : 0)
        case 0x6F92: return cntpCval                        // CNTP_CVAL
        case 0x6F9A, 0x6FAA: return cntvCval                // CNTV_CVAL
        // EL2 レジスタ
        case 0x7040: return sctlrEL2                        // SCTLR_EL2
        case 0x7048: return hcrEL2                          // HCR_EL2
        case 0x7080: return ttbr0EL2                        // TTBR0_EL2
        case 0x7081: return ttbr1EL2                        // TTBR1_EL2
        case 0x7082: return tcrEL2                          // TCR_EL2
        case 0x7290: return mairEL2                         // MAIR_EL2
        case 0x7300: return vbarEL2                         // VBAR_EL2
        case 0x7100: return UInt64(spsrEL2)                 // SPSR_EL2
        case 0x7101: return elrEL2                          // ELR_EL2
        case 0x7150: return esrEL2                          // ESR_EL2
        case 0x7180: return farEL2                          // FAR_EL2
        case 0x7908: return spEL2                           // SP_EL2
        case 0x7383: return cntvOff                         // CNTVOFF_EL2
        // GICv3 CPU インタフェース（ICC）
        case 0x6130: return UInt64(gic3?.iccPMR ?? 0)       // ICC_PMR_EL1
        case 0x6340: return gic3?.acknowledge(group: 0) ?? GICv3.spuriousINTID   // ICC_IAR0_EL1
        case 0x6360: return gic3?.acknowledge(group: 1) ?? GICv3.spuriousINTID   // ICC_IAR1_EL1
        case 0x6342: return gic3?.highestPriorityPending(group: 0) ?? GICv3.spuriousINTID  // ICC_HPPIR0_EL1
        case 0x6362: return gic3?.highestPriorityPending(group: 1) ?? GICv3.spuriousINTID  // ICC_HPPIR1_EL1
        case 0x635B: return gic3?.currentRunningPriority ?? 0xFF                  // ICC_RPR_EL1
        case 0x6364: return UInt64(gic3?.iccCtlr ?? 0)      // ICC_CTLR_EL1
        case 0x6365: return UInt64(gic3?.iccSRE ?? 0)       // ICC_SRE_EL1
        case 0x6366: return UInt64(gic3?.iccIGRPEN0 ?? 0)   // ICC_IGRPEN0_EL1
        case 0x6367: return UInt64(gic3?.iccIGRPEN1 ?? 0)   // ICC_IGRPEN1_EL1
        case 0x6343: return UInt64(gic3?.iccBPR0 ?? 0)      // ICC_BPR0_EL1
        case 0x6363: return UInt64(gic3?.iccBPR1 ?? 0)      // ICC_BPR1_EL1
        default: return platform == .vmApple ? (sysRegStorage[key] ?? 0) : 0
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
        case 0x61E0: parEL1 = value
        case 0x6108: spEL0 = value
        case 0x7108: spEL1 = value
        case 0x6D10:  // NZCV
            var flags = pstate & 0x0FFF_FFFF
            flags |= UInt32(value & 0xF000_0000)
            pstate = flags
        case 0x6D11:  // DAIF
            pstate = (pstate & ~0x3C0) | (UInt32(value) & 0x3C0)
        case 0x6113:  // PAN
            if value & 1 != 0 { pstate |= (1 << 22) } else { pstate &= ~(1 << 22) }
        case 0x6114:  // UAO
            if value & 1 != 0 { pstate |= (1 << 23) } else { pstate &= ~(1 << 23) }
        case 0x6110:  // SPSel
            if value & 1 != 0 { pstate |= 1 } else { pstate &= ~1 }
        case 0x6F90:  // CNTP_TVAL: 現在値 + 符号拡張した 32 ビット
            cntpCval = counterValue() &+ UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(value & 0xFFFF_FFFF))))
        case 0x6F98, 0x6FA8:  // CNTV_TVAL
            cntvCval = (counterValue() &- cntvOff) &+ UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(value & 0xFFFF_FFFF))))
        case 0x6F91: cntpCtl = value & 0x3
        case 0x6F99, 0x6FA9: cntvCtl = value & 0x3
        case 0x6F92: cntpCval = value
        case 0x6F9A, 0x6FAA: cntvCval = value
        // EL2 レジスタ
        case 0x7040: sctlrEL2 = value
        case 0x7048: hcrEL2 = value
        case 0x7080: ttbr0EL2 = value
        case 0x7081: ttbr1EL2 = value
        case 0x7082: tcrEL2 = value
        case 0x7290: mairEL2 = value
        case 0x7300: vbarEL2 = value
        case 0x7100: spsrEL2 = UInt32(value & 0xFFFF_FFFF)
        case 0x7101: elrEL2 = value
        case 0x7150: esrEL2 = value
        case 0x7180: farEL2 = value
        case 0x7908: spEL2 = value
        case 0x7383: cntvOff = value
        // GICv3 CPU インタフェース（ICC）
        case 0x6130: gic3?.iccPMR = UInt32(value & 0xFF)
        case 0x6341: gic3?.endOfInterrupt(group: 0, intid: Int(value & 0xFF_FFFF))   // ICC_EOIR0_EL1
        case 0x6361: gic3?.endOfInterrupt(group: 1, intid: Int(value & 0xFF_FFFF))   // ICC_EOIR1_EL1
        case 0x6359: gic3?.deactivate(intid: Int(value & 0xFF_FFFF))                 // ICC_DIR_EL1
        case 0x635D, 0x635E, 0x635F: gic3?.generateSGI(register: value)               // ICC_SGI1R / ASGI1R / SGI0R
        case 0x6364: gic3?.iccCtlr = UInt32(value & 0xFFFF_FFFF)
        case 0x6365: gic3?.iccSRE = UInt32(value & 0xFFFF_FFFF)
        case 0x6366: gic3?.iccIGRPEN0 = UInt32(value & 1)
        case 0x6367: gic3?.iccIGRPEN1 = UInt32(value & 1)
        case 0x6343: gic3?.iccBPR0 = UInt32(value & 0x7)
        case 0x6363: gic3?.iccBPR1 = UInt32(value & 0x7)
        default:
            if platform == .vmApple { sysRegStorage[key] = value }
        }
    }

    // MARK: SVC（コンソールサービス / 例外）

    private func executeSVC(imm: Int, at instructionPC: UInt64) throws {
        if platform == .vmApple {
            // AVPBooter のハイパーコール・トランポリンは EL1h から svc #0 を発行する。
            // 実機 (VZ) では HCR_EL2.TSC により EL1 の SVC はハイパーバイザへトラップされ、
            // ROM 自身の VBAR+0x200 は到達不能な前提でパークスタブになっている。
            // ROM 起動中はこれをハイパーバイザゲート（無動作で復帰）として扱う。
            if !romData.isEmpty && currentEL == 1 && spSel {
                return
            }
            // XNU 環境ではすべての SVC をカーネルへの同期例外として配送する
            raiseSync(ec: 0x15, iss: UInt64(imm), elr: pc)
            return
        }
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

    // MARK: - VMAPPLE（HVC サービス / タイマ線 / 起動設定）

    /// CNTV の期限切れ（仮想カウンタ基準）。
    private var cntvExpired: Bool {
        (cntvCtl & 0x1) != 0 && (counterValue() &- cntvOff) >= cntvCval
    }

    /// タイマ出力を GIC の PPI ラインへ同期する。
    private func syncVMAppleTimerLines() {
        guard let gic = gic3 else { return }
        let cntpAssert = (cntpCtl & 0x1) != 0 && (cntpCtl & 0x2) == 0 && timerExpired
        let cntvAssert = (cntvCtl & 0x1) != 0 && (cntvCtl & 0x2) == 0 && cntvExpired
        // Henge devices/timer.h: HV_PPI_VTIMER = 27、HV_PPI_PTIMER = 30。
        // QEMU hw/arm/virt.c でも EL1 物理タイマは INTID 30
        // （ARCH_TIMER_NS_EL1_IRQ）。以前は CNTP を EL2 タイマの 25/26 に
        // 誤って割り当て、EL1 物理タイマ（30）を一切駆動していなかった。
        gic.ppiLine[30 - 16] = cntpAssert   // EL1 物理タイマ
        gic.ppiLine[27 - 16] = cntvAssert   // 仮想タイマ
    }

    private var vmAppleFIQPending: Bool {
        syncVMAppleTimerLines()
        syncVMAppleUARTLine()
        pl031Tick()
        return gic3?.pendingGroup(0) ?? false
    }

    private var vmAppleIRQPending: Bool {
        syncVMAppleTimerLines()
        syncVMAppleUARTLine()
        pl031Tick()
        return gic3?.pendingGroup(1) ?? false
    }

    /// HVC / SMC の SMCCC サービス（PSCI + Apple PAC サービス）。
    /// PAC 命令自体は NOP 化しているため、キー管理は成功応答のみで一貫する。
    private func executeHVC() {
        guard platform == .vmApple else {
            raiseSync(ec: 0x16, iss: 0, elr: pc)
            return
        }
        let fid = registers[0]
        switch fid {
        case 0x8400_0000:  // PSCI_VERSION → 1.1
            registers[0] = 0x0001_0001
        case 0x8400_0003, 0xC400_0003:  // CPU_ON（単一 CPU: 起動済みとして成功）
            registers[0] = 0
        case 0x8400_0002:  // CPU_OFF
            registers[0] = 0
        case 0x8400_0004, 0xC400_0004:  // AFFINITY_INFO → ON
            registers[0] = 0
        case 0x8400_000A, 0xC400_000A:  // PSCI_FEATURES → サポート
            registers[0] = 0
        case 0x8400_0001, 0xC400_0001:  // CPU_SUSPEND → そのまま復帰
            registers[0] = 0
        case 0x8400_0008:  // SYSTEM_OFF
            halted = true
            exitCode = 0
        case 0x8400_0009:  // SYSTEM_RESET
            halted = true
            exitCode = 0x5253_5431  // 'RST1'
        case 0xC100_0000:  // Apple PAC サービス（初期状態設定）
            registers[0] = 0
        case 0xC100_0001:  // Apple PAC サービス（デフォルトキー取得: pid は非ゼロ必須）
            registers[0] = 0
            registers[1] = 1
            registers[2] = 2
            registers[3] = 3
            registers[4] = 4
        default:
            if fid >= 0xC100_0000 && fid <= 0xC100_FFFF {
                registers[0] = 0  // Apple 予約域は成功として扱う
            } else {
                registers[0] = 0xFFFF_FFFF  // SMCCC_NOT_SUPPORTED
            }
        }
    }

    /// VHE（HCR_EL2.E2H）有効時に EL1 名レジスタを EL2 ストレージへ振り替える。
    private static func vheRedirectedKey(_ key: Int) -> Int {
        switch key {
        case 0x6040: return 0x7040   // SCTLR_EL1 → SCTLR_EL2
        case 0x6080: return 0x7080   // TTBR0_EL1 → TTBR0_EL2
        case 0x6081: return 0x7081   // TTBR1_EL1 → TTBR1_EL2
        case 0x6082: return 0x7082   // TCR_EL1 → TCR_EL2
        case 0x6290: return 0x7290   // MAIR_EL1 → MAIR_EL2
        case 0x6300: return 0x7300   // VBAR_EL1 → VBAR_EL2
        case 0x6100: return 0x7100   // SPSR_EL1 → SPSR_EL2
        case 0x6101: return 0x7101   // ELR_EL1 → ELR_EL2
        case 0x6150: return 0x7150   // ESR_EL1 → ESR_EL2
        case 0x6180: return 0x7180   // FAR_EL1 → FAR_EL2
        case 0x7108: return 0x7908   // SP_EL1 → SP_EL2
        default: return key
        }
    }

    /// ゲスト物理アドレスへバイト列を書き込む（ブートローダ用）。
    /// 現在の変換レジームで VA→PA を解決する（デバッグ用、失敗時は nil）
    func debugTranslate(_ va: UInt64) -> UInt64? {
        return try? translate(address: va, isWrite: false, isFetch: true)
    }

    /// ゲスト物理メモリの読み出し（デバッグ用）
    func readGuestMemory(address pa: UInt64, size: Int) -> UInt64 {
        return (try? readPhysical(pa, size: size)) ?? 0
    }

    func writeGuestMemory(_ bytes: [UInt8], at pa: UInt64) {
        guard pa >= ramBaseAddress else { return }
        let offset = Int(pa - ramBaseAddress)
        guard offset + bytes.count <= memory.count else { return }
        memory.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    /// VMAPPLE の実行開始状態を設定する（EL2h、CNTFRQ 24 MHz、GICv3 生成）。
    func setupVMAppleEntry(pc entryPC: UInt64, bootArgsPA: UInt64, stackTop: UInt64,
                           gicDistPA: UInt64, gicRedistPA: UInt64, uartPA: UInt64) {
        platform = .vmApple
        ramBaseAddress = VMAppleBoot.dramBase
        timerFrequency = 24_000_000
        gic3 = GICv3()
        vmGICDistPA = gicDistPA
        vmGICRedistPA = gicRedistPA
        vmUARTPA = uartPA
        pc = entryPC
        registers[0] = bootArgsPA
        spEL1 = stackTop
        spEL2 = stackTop
        // VZ は E2H 有効の VHE 環境を提示し、カーネルは EL1 レジスタモデルで動作する。
        // ここでは EL1h で開始し、HVC（PSCI / PAC サービス）はエミュレータが直接処理する。
        pstate = 0x3C5   // EL1h / DAIF マスク / SPSel=1
    }

    /// AVPBooter（VM ブート ROM）から起動する開始状態を設定する。
    /// QEMU hw/vmapple + Henge devices/vmapple.c の再現: リセット時は EL1h・MMU/キャッシュ
    /// オフ・全マスクで PC = 0x0010_0000（ROM 先頭）。ROM は RAM としてマップされ、
    /// cfg ウィンドウ（0x0040_0000 から 1 MiB）にマシン情報が置かれる。
    /// レイアウトは Henge devices/cfg.c の実測値（serial 0x500 / soc_name 0x584）。
    func setupROMBoot(rom: [UInt8], installer: Bool, ecid: UInt64 = 0x0001_0203_0405_0607) {
        platform = .vmApple
        ramBaseAddress = VMAppleBoot.dramBase
        timerFrequency = 24_000_000
        gic3 = GICv3()
        vmGICDistPA = 0x1000_0000
        vmGICRedistPA = 0x1001_0000
        vmUARTPA = 0x2001_0000
        romData = [UInt8](repeating: 0, count: 0x10_0000)
        let n = min(rom.count, romData.count)
        romData.replaceSubrange(0..<n, with: rom.prefix(n))
        cfgWindow = [UInt8](repeating: 0, count: 0x10_0000)
        func put32(_ off: Int, _ v: UInt32) {
            for i in 0..<4 { cfgWindow[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func put64(_ off: Int, _ v: UInt64) {
            for i in 0..<8 { cfgWindow[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func putStr(_ off: Int, _ s: String) {
            for (i, b) in s.utf8.prefix(31).enumerated() { cfgWindow[off + i] = b }
        }
        put32(0x00, 2)                    // version
        put32(0x04, 1)                    // nr_cpus
        put32(0x08, 1)                    // unk1
        put32(0x0C, 1)                    // unk2
        put32(0x10, 0x20)                 // unk3
        put32(0x14, 0)                    // unk4
        put64(0x18, ecid)                 // ecid
        put64(0x20, UInt64(memorySize))   // ram_size
        put32(0x28, installer ? 1 : 0)    // run_installer1
        bdifUSBEnabled = installer        // インストーラ起動時のみ bdif USB チャネルを開く（Henge 準拠）
        put32(0x2C, 1)                    // unk5
        put32(0x30, 1)                    // unk6
        put32(0x34, installer ? 1 : 0)    // run_installer2
        // 0x38 rnd は cfgRead が動的に返す
        for i in 0..<4 {                  // MAC アドレス（en0/en1/wifi/bt、6 バイト + 2 埋め草）
            let base = 0x40 + i * 8
            cfgWindow[base] = 0x02; cfgWindow[base + 1] = 0x00; cfgWindow[base + 2] = 0x00
            cfgWindow[base + 3] = 0x00; cfgWindow[base + 4] = 0x00; cfgWindow[base + 5] = UInt8(1 + i)
        }
        put32(0x100, 0)                   // cpu_ids[0]
        putStr(0x500, "1234")             // serial（Henge 既定）
        putStr(0x520, "D/A")              // unk8
        putStr(0x540, "VM0001")           // model（Henge 既定）
        put32(0x580, 1)                   // unk10
        putStr(0x584, "Apple M1 (Virtual)")  // soc_name（Henge 既定）
        pc = 0x0010_0000
        pstate = 0x3C5   // EL1h / DAIF マスク / SPSel=1（Henge のリセット状態）
        sctlrEL1 = 0x30D0_0980   // アーキテクチャ既定（RES1 ビット群。Henge のリセット値と同一）
    }
}

// MARK: - FP / SIMD 実行（NEON + 浮動小数点）

extension ARM64CPU {

    // MARK: レジスタ / レーン補助

    /// V レジスタの 16 バイト表現（リトルエンディアン）
    func vRegBytes(_ index: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let lo = fpRegisters[index * 2]
        let hi = fpRegisters[index * 2 + 1]
        for j in 0..<8 {
            bytes[j] = UInt8((lo >> (8 * j)) & 0xFF)
            bytes[j + 8] = UInt8((hi >> (8 * j)) & 0xFF)
        }
        return bytes
    }

    func setVRegBytes(_ index: Int, _ bytes: [UInt8]) {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        for j in 0..<8 {
            lo |= UInt64(bytes[j]) << (8 * j)
            hi |= UInt64(bytes[j + 8]) << (8 * j)
        }
        fpRegisters[index * 2] = lo
        fpRegisters[index * 2 + 1] = hi
    }

    /// ベクタ結果の書き戻し（Q=0 のとき上位 64 ビットはゼロになる）
    func setVRegBytes(_ index: Int, _ bytes: [UInt8], q: Bool) {
        if q {
            setVRegBytes(index, bytes)
        } else {
            var lo: UInt64 = 0
            for j in 0..<8 { lo |= UInt64(bytes[j]) << (8 * j) }
            fpRegisters[index * 2] = lo
            fpRegisters[index * 2 + 1] = 0
        }
    }

    func laneGet(_ bytes: [UInt8], _ lane: Int, _ size: Int) -> UInt64 {
        var value: UInt64 = 0
        for j in 0..<size { value |= UInt64(bytes[lane * size + j]) << (8 * j) }
        return value
    }

    func laneSet(_ bytes: inout [UInt8], _ lane: Int, _ size: Int, _ value: UInt64) {
        for j in 0..<size { bytes[lane * size + j] = UInt8((value >> (8 * j)) & 0xFF) }
    }

    func laneSigned(_ bytes: [UInt8], _ lane: Int, _ size: Int) -> Int64 {
        Int64(bitPattern: signExtend(laneGet(bytes, lane, size), bits: size * 8))
    }

    /// スカラ FP レジスタ読み（isDouble=false は単精度）
    func fpScalar(_ index: Int, isDouble: Bool) -> Double {
        if isDouble { return Double(bitPattern: fpRegisters[index * 2]) }
        return Double(Float(bitPattern: UInt32(truncatingIfNeeded: fpRegisters[index * 2])))
    }

    /// スカラ FP レジスタ書き（上位はゼロ埋め）
    func setFPScalar(_ index: Int, _ value: Double, isDouble: Bool) {
        if isDouble {
            fpRegisters[index * 2] = value.bitPattern
        } else {
            fpRegisters[index * 2] = UInt64(Float(value).bitPattern)
        }
        fpRegisters[index * 2 + 1] = 0
    }

    /// 符号付き飽和（bits 幅の符号付き範囲へクランプし、ビットパターンを返す）
    func saturateSigned(_ value: Int64, bits: Int) -> UInt64 {
        if bits >= 64 { return UInt64(bitPattern: value) }
        let maxV = Int64(1) << (bits - 1) - 1
        let minV = -(Int64(1) << (bits - 1))
        let clamped = Swift.min(Swift.max(value, minV), maxV)
        return UInt64(bitPattern: clamped) & ((UInt64(1) << bits) - 1)
    }

    /// 符号付き飽和クランプ（Int64 のまま返す）。
    func clampSigned(_ value: Int64, bits: Int) -> Int64 {
        if bits >= 64 { return value }
        let maxV = (Int64(1) << (bits - 1)) - 1
        let minV = -(Int64(1) << (bits - 1))
        return Swift.min(Swift.max(value, minV), maxV)
    }

    /// 飽和累積（SQDMLAL / SQDMLSL 用）。QEMU target/arm/tcg/translate-a64.c の
    /// gen_sqdmlal_h/s・gen_sqdmlsl_h/s は、積の 2 倍を宛先幅で飽和したうえで
    /// 累積も neon_addl_saturate で宛先幅に飽和させる。ラッピング加減算では
    /// 蓄積側の飽和が起きず qemu-aarch64 と不一致になる（実測で確認）。
    func saturatingAccumulate(acc: Int64, term: Int64, subtract: Bool, bits: Int) -> UInt64 {
        let (r, overflow) = subtract ? acc.subtractingReportingOverflow(term)
                                     : acc.addingReportingOverflow(term)
        if overflow {
            let pos = subtract ? term < 0 : term >= 0
            let v: Int64 = pos ? Int64.max : Int64.min
            return saturateSigned(v, bits: bits)
        }
        return saturateSigned(r, bits: bits)
    }

    /// 符号なし飽和（負値は 0、bits 幅の最大値でクランプ）
    func saturateUnsigned(_ value: Int64, bits: Int) -> UInt64 {
        if value < 0 { return 0 }
        if bits >= 64 { return UInt64(bitPattern: value) }
        let maxV = (UInt64(1) << bits) - 1
        return Swift.min(UInt64(bitPattern: value), maxV)
    }

    /// 偶数への丸め（最近接・タイは偶数）を適用した整数値
    func roundToNearestEven(_ value: Double) -> Double {
        if !value.isFinite { return value }
        let floorV = value.rounded(.down)
        let frac = value - floorV
        if frac > 0.5 { return floorV + 1 }
        if frac < 0.5 { return floorV }
        // ちょうど 0.5: 偶数側へ
        return floorV.truncatingRemainder(dividingBy: 2) == 0 ? floorV : floorV + 1
    }

    // MARK: ルータ

    func executeFPOrSIMD(_ insn: UInt32, rd: Int, rn: Int, rm: Int, at instructionPC: UInt64) throws -> Bool {
        // FP ロード / ストア（V ビット = bit26 が 1 の形式）
        if insn & 0x0400_0000 != 0 {
            if try executeFPLoadStore(insn, rd: rd, rn: rn, rm: rm, at: instructionPC) { return true }
        }
        // FP 3 ソース（FMADD 系）
        if (insn & 0x7F00_0000) == 0x1F00_0000 {
            return try executeFPThreeSource(insn, rd: rd, rn: rn, rm: rm)
        }
        // FP スカラ領域（0x1E / 0x9E 空間: bit30 = 0 が FP データ処理の印）
        if (insn & 0x5E00_0000) == 0x1E00_0000 && insn & 0x4000_0000 == 0 {
            if try executeFPScalar(insn, rd: rd, rn: rn, rm: rm) { return true }
        }
        // 構造体ロード / ストア（LD1〜LD4 / ST1〜ST4: 0x4C/0x4D/0x0C/0x0D 空間）
        if try executeStructLoadStore(insn, rd: rd, rn: rn, rm: rm) { return true }
        // SIMD ベクタ領域（スカラ空間 0x5E / 0x7E を含む）
        if (insn & 0x0E00_0000) == 0x0E00_0000 {
            if try executeSIMDVector(insn, rd: rd, rn: rn, rm: rm) { return true }
        }
        return false
    }

    // MARK: FP ロード / ストア

    private func fpLoad(_ index: Int, address: UInt64, bytes: Int) throws {
        switch bytes {
        case 16:
            fpRegisters[index * 2] = try loadValue(address: address, size: 8)
            fpRegisters[index * 2 + 1] = try loadValue(address: address &+ 8, size: 8)
        default:
            let value = try loadValue(address: address, size: bytes)
            fpRegisters[index * 2] = value
            fpRegisters[index * 2 + 1] = 0
        }
    }

    private func fpStore(_ index: Int, address: UInt64, bytes: Int) throws {
        switch bytes {
        case 16:
            try storeValue(address: address, size: 8, fpRegisters[index * 2])
            try storeValue(address: address &+ 8, size: 8, fpRegisters[index * 2 + 1])
        default:
            try storeValue(address: address, size: bytes, fpRegisters[index * 2])
        }
    }

    func executeFPLoadStore(_ insn: UInt32, rd: Int, rn: Int, rm: Int, at instructionPC: UInt64) throws -> Bool {
        let size = Int((insn >> 30) & 0x3)
        let opc = Int((insn >> 22) & 0x3)
        let base = readReg(rn, sp: true)

        // リテラル
        if (insn & 0x3B00_0000) == 0x1800_0000 {
            let bytes = [4, 8, 16][size == 3 ? 0 : size]
            if size == 3 { return false }
            let offset = signExtend(UInt64((insn >> 5) & 0x7_FFFF) << 2, bits: 21)
            let address = UInt64(bitPattern: Int64(bitPattern: instructionPC) &+ Int64(bitPattern: offset))
            try fpLoad(rd, address: address, bytes: bytes)
            return true
        }

        // ペア
        if (insn & 0x3A00_0000) == 0x2800_0000 {
            let isLoad = insn & 0x0040_0000 != 0
            let mode = Int((insn >> 23) & 0x7)   // 001=ポスト、010=オフセット、011=プレ
            let elemBytes = [4, 8, 16][size == 3 ? 0 : size]
            if size == 3 { return false }
            let imm7 = signExtend(UInt64((insn >> 15) & 0x7F), bits: 7)
            let offset = Int64(bitPattern: imm7) * Int64(elemBytes)
            let rt2 = Int((insn >> 10) & 0x1F)
            var address = base
            if mode != 1 {
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ offset)
            }
            if isLoad {
                try fpLoad(rd, address: address, bytes: elemBytes)
                try fpLoad(rt2, address: address &+ UInt64(elemBytes), bytes: elemBytes)
            } else {
                try fpStore(rd, address: address, bytes: elemBytes)
                try fpStore(rt2, address: address &+ UInt64(elemBytes), bytes: elemBytes)
            }
            if mode == 1 || mode == 3 {
                writeReg(rn, UInt64(bitPattern: Int64(bitPattern: base) &+ offset), sp: true)
            }
            return true
        }

        // 単一: 転送サイズ（size==0 && opc>=2 は 128 ビット）
        let bytes = (size == 0 && opc >= 2) ? 16 : (1 << size)
        let isLoad = (opc == 1 || opc == 3)
        let address: UInt64
        var writeback: UInt64? = nil
        if (insn & 0x3B00_0000) == 0x3900_0000 {
            // 符号なし即値オフセット（転送サイズでスケール）
            let shift = bytes == 16 ? 4 : size
            let imm12 = UInt64((insn >> 10) & 0xFFF) << shift
            address = base &+ imm12
        } else if (insn & 0x3B20_0C00) == 0x3820_0800 {
            // レジスタオフセット
            let option = Int((insn >> 13) & 0x7)
            let shiftAmount = ((insn >> 12) & 1) == 1 ? (bytes == 16 ? 4 : size) : 0
            let offset = extendValue(readReg(rm), option: option, shift: shiftAmount)
            address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: offset))
        } else if (insn & 0x3B20_0000) == 0x3800_0000 {
            // 即値 9 ビット（アンスケールド / プレ / ポスト）
            let imm9 = signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)
            let indexMode = Int((insn >> 10) & 0x3)
            switch indexMode {
            case 1:
                address = base
                writeback = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
            case 3:
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
                writeback = address
            default:
                address = UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(bitPattern: imm9))
            }
        } else {
            return false
        }
        if isLoad {
            try fpLoad(rd, address: address, bytes: bytes)
        } else {
            try fpStore(rd, address: address, bytes: bytes)
        }
        if let writeback = writeback {
            writeReg(rn, writeback, sp: true)
        }
        return true
    }

    // MARK: FP スカラ

    /// FP 即値の展開（VFPExpandImm 相当）: 値 = ±(1 + frac/16) × 2^e
    private func expandFPImmediate(_ imm8: UInt32, isDouble: Bool) -> Double {
        let e3 = Int((imm8 >> 4) & 0x7)
        let e = e3 >= 4 ? e3 - 7 : e3 + 1
        var value = (1.0 + Double(imm8 & 0xF) / 16.0) * pow(2.0, Double(e))
        if imm8 & 0x80 != 0 { value = -value }
        return value
    }

    private func fpCompareFlags(a: Double, b: Double) {
        if a.isNaN || b.isNaN {
            setNZCV(n: false, z: false, c: true, v: true)
        } else {
            setNZCV(n: a < b, z: a == b, c: a >= b, v: false)
        }
    }

    func executeFPThreeSource(_ insn: UInt32, rd: Int, rn: Int, rm: Int) throws -> Bool {
        let isDouble = insn & 0x0040_0000 != 0
        let negateAll = insn & 0x0020_0000 != 0   // o1 (bit21)
        let subtract = insn & 0x0000_8000 != 0    // o3 (bit15)
        let ra = Int((insn >> 10) & 0x1F)
        let n = fpScalar(rn, isDouble: isDouble)
        let m = fpScalar(rm, isDouble: isDouble)
        let a = fpScalar(ra, isDouble: isDouble)
        let product = n * m
        var result = subtract ? (a - product) : (a + product)
        if negateAll { result = -result }
        setFPScalar(rd, result, isDouble: isDouble)
        return true
    }

    func executeFPScalar(_ insn: UInt32, rd: Int, rn: Int, rm: Int) throws -> Bool {
        let isDouble = insn & 0x0040_0000 != 0   // type = bit22（変換系では別途解釈）

        // FMOV（汎用レジスタ ⇔ FP レジスタ）
        switch insn & 0xFFFF_FC00 {
        case 0x1E27_0000:   // Sd ← Wn
            fpRegisters[rd * 2] = readReg(rn) & 0xFFFF_FFFF
            fpRegisters[rd * 2 + 1] = 0
            return true
        case 0x9E67_0000:   // Dd ← Xn
            fpRegisters[rd * 2] = readReg(rn)
            fpRegisters[rd * 2 + 1] = 0
            return true
        case 0x1E26_0000:   // Wd ← Sn
            writeReg(rd, fpRegisters[rn * 2] & 0xFFFF_FFFF, width64: false)
            return true
        case 0x9E66_0000:   // Xd ← Dn
            writeReg(rd, fpRegisters[rn * 2])
            return true
        default:
            break
        }

        // FMOV（即値）
        if (insn & 0x7FA0_1FE0) == 0x1E20_1000 {
            let imm8 = (insn >> 13) & 0xFF
            setFPScalar(rd, expandFPImmediate(imm8, isDouble: isDouble), isDouble: isDouble)
            return true
        }

        let bits1110 = Int((insn >> 10) & 0x3)
        let bit21 = insn & 0x0020_0000 != 0

        // 固定小数点変換（@fcvt32/@fcvt64）: QEMU a64.decode 1347–1355 行。
        // scale フィールド（bits[15:10]）の低位が bits1110 の振り分けと
        // 重なるため、他の分岐より先に判定する。この空間で bits[21:16] が
        // 000010/000011/011000/011001 になるのは固定小数点形式のみ
        // （1 ソース系・FCMP・FCCMP・@icvt 形式は全て bit21=1）。
        let opc6 = Int((insn >> 16) & 0x3F)
        if opc6 == 0b000010 || opc6 == 0b000011 || opc6 == 0b011000 || opc6 == 0b011001 {
            return try executeFPConvertFixed(insn, rd: rd, rn: rn)
        }

        // 2 ソース（FMUL/FDIV/FADD/FSUB/FMAX/FMIN/FNMUL）
        if bits1110 == 0x2 && bit21 {
            let opc = Int((insn >> 12) & 0xF)
            let n = fpScalar(rn, isDouble: isDouble)
            let m = fpScalar(rm, isDouble: isDouble)
            switch opc {
            case 0: setFPScalar(rd, n * m, isDouble: isDouble)
            case 1: setFPScalar(rd, n / m, isDouble: isDouble)
            case 2: setFPScalar(rd, n + m, isDouble: isDouble)
            case 3: setFPScalar(rd, n - m, isDouble: isDouble)
            case 4: setFPScalar(rd, fpMax(n, m), isDouble: isDouble)
            case 5: setFPScalar(rd, fpMin(n, m), isDouble: isDouble)
            case 6: setFPScalar(rd, -(n * m), isDouble: isDouble)
            default: return false
            }
            return true
        }

        // FCSEL
        if bits1110 == 0x3 && bit21 {
            let cond = Int((insn >> 12) & 0xF)
            let source = conditionHolds(cond) ? rn : rm
            fpRegisters[rd * 2] = fpRegisters[source * 2]
            fpRegisters[rd * 2 + 1] = 0
            return true
        }

        // FCCMP
        if bits1110 == 0x1 && bit21 {
            let cond = Int((insn >> 12) & 0xF)
            if conditionHolds(cond) {
                fpCompareFlags(a: fpScalar(rn, isDouble: isDouble), b: fpScalar(rm, isDouble: isDouble))
            } else {
                let nzcv = (insn >> 0) & 0xF
                setNZCV(n: nzcv & 0x8 != 0, z: nzcv & 0x4 != 0, c: nzcv & 0x2 != 0, v: nzcv & 0x1 != 0)
            }
            return true
        }

        if bits1110 == 0x0 {
            // 1 ソース（レジスタ移動系）: bit21 = 0
            if !bit21 {
                let opc = Int((insn >> 15) & 0xF)
                let n = fpScalar(rn, isDouble: isDouble)
                switch opc {
                case 0:   // FMOV（レジスタ）
                    fpRegisters[rd * 2] = fpRegisters[rn * 2]
                    fpRegisters[rd * 2 + 1] = 0
                case 1:   // FABS
                    setFPScalar(rd, abs(n), isDouble: isDouble)
                case 2:   // FNEG
                    setFPScalar(rd, -n, isDouble: isDouble)
                case 3:   // FSQRT
                    setFPScalar(rd, n.squareRoot(), isDouble: isDouble)
                default:
                    return false
                }
                return true
            }
            // FCMP
            if ((insn >> 12) & 0xF) == 0x2 {
                let b = (insn & 0x8) != 0 ? 0.0 : fpScalar(rm, isDouble: isDouble)
                fpCompareFlags(a: fpScalar(rn, isDouble: isDouble), b: b)
                return true
            }
            // 変換（FP ⇔ 整数）: bits[15:12] = 0（FRINT より先に判定する）
            if ((insn >> 12) & 0xF) == 0x0 {
                return try executeFPConvert(insn, rd: rd, rn: rn)
            }
            let opc1815 = Int((insn >> 15) & 0xF)
            // FRINT 系
            if opc1815 >= 8 {
                let n = fpScalar(rn, isDouble: isDouble)
                let rounded: Double
                switch opc1815 {
                case 8: rounded = roundToNearestEven(n)                    // FRINTN
                case 9: rounded = n.rounded(.up)                           // FRINTP
                case 10: rounded = n.rounded(.down)                        // FRINTM
                case 11: rounded = n.rounded(.towardZero)                  // FRINTZ
                case 12: rounded = n.rounded(.toNearestOrAwayFromZero)     // FRINTA
                default: rounded = roundToNearestEven(n)                   // FRINTX / FRINTI
                }
                setFPScalar(rd, rounded, isDouble: isDouble)
                return true
            }
            // FCVT（FP ⇔ FP）
            if ((insn >> 12) & 0xF) == 0x4 || ((insn >> 12) & 0xF) == 0xC {
                let srcType = Int((insn >> 22) & 0x3)   // 0=S, 1=D, 3=H
                let dstType = Int((insn >> 15) & 0x3)   // 0=S, 1=D, 3=H
                if srcType == 3 || dstType == 3 { return false }   // 半精度は未対応
                let value = fpScalar(rn, isDouble: srcType == 1)
                setFPScalar(rd, value, isDouble: dstType == 1)
                return true
            }
            return false
        }
        return false
    }

    /// バイト列のレーンから FP 値を読む（ペアワイズ用）
    private func fpScalarFromBytes(_ bytes: [UInt8], lane: Int, isDouble: Bool) -> Double {
        if isDouble {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[lane * 8 + i]) << (8 * i) }
            return Double(bitPattern: bits)
        }
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(bytes[lane * 4 + i]) << (8 * i) }
        return Double(Float(bitPattern: bits))
    }

    private func fpMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b }
        if b.isNaN { return a }
        if a == b { return (a.sign == .minus && b.sign == .plus) ? b : a }  // +0 を優先（FMAX の仕様近似）
        return Swift.max(a, b)
    }

    private func fpMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b }
        if b.isNaN { return a }
        if a == b { return (a.sign == .minus || b.sign == .minus) ? (a.sign == .minus ? a : b) : a }
        return Swift.min(a, b)
    }

    /// FCVT 系（FP ⇔ 整数変換）
    private func executeFPConvert(_ insn: UInt32, rd: Int, rn: Int) throws -> Bool {
        let opc5 = Int((insn >> 16) & 0x1F)
        let isDouble = insn & 0x0040_0000 != 0
        let sf = insn & 0x8000_0000 != 0
        switch opc5 {
        case 2, 3:
            // SCVTF (2) / UCVTF (3): 整数 → FP
            let raw = readReg(rn)
            let value: Double
            if opc5 == 2 {
                value = sf ? Double(Int64(bitPattern: raw)) : Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            } else {
                value = sf ? Double(raw) : Double(UInt32(truncatingIfNeeded: raw))
            }
            setFPScalar(rd, value, isDouble: isDouble)
            return true
        case 0, 1, 4, 5, 8, 9, 16, 17, 24, 25:
            // FCVT{N,P,M,Z,A}{S,U}: FP → 整数
            let unsigned = opc5 & 1 == 1
            let mode = opc5 & ~1
            let source = fpScalar(rn, isDouble: isDouble)
            let rounded: Double
            if source.isNaN {
                writeReg(rd, 0, width64: sf)
                return true
            }
            switch mode {
            case 0: rounded = roundToNearestEven(source)                 // N
            case 8: rounded = source.rounded(.up)                        // P
            case 16: rounded = source.rounded(.down)                     // M
            case 24: rounded = source.rounded(.towardZero)               // Z
            default: rounded = source.rounded(.toNearestOrAwayFromZero) // A (4)
            }
            let result: UInt64
            if unsigned {
                let limit: Double = sf ? 18446744073709551616.0 : 4294967296.0
                if rounded <= 0 { result = 0 }
                else if rounded >= limit { result = sf ? UInt64.max : 0xFFFF_FFFF }
                else { result = UInt64(rounded) }
            } else {
                let maxV: Double = sf ? 9223372036854775808.0 : 2147483648.0
                if rounded >= maxV { result = sf ? 0x7FFF_FFFF_FFFF_FFFF : 0x7FFF_FFFF }
                else if rounded < -maxV { result = sf ? 0x8000_0000_0000_0000 : 0xFFFF_FFFF_8000_0000 }
                else { result = UInt64(bitPattern: Int64(rounded)) }
            }
            writeReg(rd, result, width64: sf)
            return true
        default:
            return false
        }
    }

    /// 固定小数点 FCVT 系（SCVTF/UCVTF/FCVTZS/FCVTZU の #fbits 形式）
    /// 意味論は QEMU に一致（a64.decode の @fcvt32/@fcvt64、vfp_helper.c の
    /// VFP_CONV_FIX_A64 = float*_to_int*_scalbn / int*_to_float*_scalbn）:
    /// FCVTZ は丸めを切り捨てに固定（do_fcvt_scalar が FPROUNDING_ZERO を
    /// 設定）、NaN は 0、範囲外は飽和。qemu-aarch64 との差分 3876 件
    /// （tests/fcvt）で検証済み。
    private func executeFPConvertFixed(_ insn: UInt32, rd: Int, rn: Int) throws -> Bool {
        let sf = insn & 0x8000_0000 != 0
        let type = Int((insn >> 22) & 0x3)
        guard type == 0 || type == 1 else { return false }   // 半精度は未対応（エンジン全体の方針）
        let isDouble = type == 1
        let opc6 = Int((insn >> 16) & 0x3F)
        let scale = Int((insn >> 10) & 0x3F)
        // @fcvt32 は bit15=1（scale 32...63）を要求する。満たさない
        // エンコーディングは未割り当て（QEMU でも SIGILL を確認済み）。
        if !sf && scale < 32 { return false }
        let fbits = 64 - scale
        switch opc6 {
        case 0b011000, 0b011001:
            // FCVTZS / FCVTZU: trunc(value × 2^fbits) を飽和付きで整数化
            let unsigned = opc6 == 0b011001
            let source = fpScalar(rn, isDouble: isDouble)
            if source.isNaN {
                writeReg(rd, 0, width64: sf)
                return true
            }
            let t = (source * Double(sign: .plus, exponent: fbits, significand: 1.0)).rounded(.towardZero)
            let result: UInt64
            if unsigned {
                let limit: Double = sf ? 18446744073709551616.0 : 4294967296.0
                if t <= 0 { result = 0 }
                else if t >= limit { result = sf ? UInt64.max : 0xFFFF_FFFF }
                else { result = UInt64(t) }
            } else {
                let maxV: Double = sf ? 9223372036854775808.0 : 2147483648.0
                if t >= maxV { result = sf ? 0x7FFF_FFFF_FFFF_FFFF : 0x7FFF_FFFF }
                else if t < -maxV { result = sf ? 0x8000_0000_0000_0000 : 0xFFFF_FFFF_8000_0000 }
                else { result = UInt64(bitPattern: Int64(t)) }
            }
            writeReg(rd, result, width64: sf)
            return true
        case 0b000010, 0b000011:
            // SCVTF / UCVTF: value = int × 2^(−fbits)（単一丸め）
            let signed = opc6 == 0b000010
            let raw = readReg(rn)
            let value: Double
            if signed {
                value = sf ? Double(Int64(bitPattern: raw)) : Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            } else {
                value = sf ? Double(raw) : Double(UInt32(truncatingIfNeeded: raw))
            }
            setFPScalar(rd, value * Double(sign: .plus, exponent: -fbits, significand: 1.0), isDouble: isDouble)
            return true
        default:
            return false
        }
    }

    // MARK: SIMD ベクタ

    func fpLane(_ bytes: [UInt8], _ lane: Int, isDouble: Bool) -> Double {
        if isDouble { return Double(bitPattern: laneGet(bytes, lane, 8)) }
        return Double(Float(bitPattern: UInt32(truncatingIfNeeded: laneGet(bytes, lane, 4))))
    }

    func setFPLane(_ bytes: inout [UInt8], _ lane: Int, _ value: Double, isDouble: Bool) {
        if isDouble {
            laneSet(&bytes, lane, 8, value.bitPattern)
        } else {
            laneSet(&bytes, lane, 4, UInt64(Float(value).bitPattern))
        }
    }

    /// 切り捨て丸め + 飽和で FP → 整数変換（ベクタ FCVTZ 用）
    func fpToIntSaturated(_ value: Double, bits: Int, unsigned: Bool) -> UInt64 {
        if value.isNaN { return 0 }
        let t = value.rounded(.towardZero)
        if unsigned {
            if t <= 0 { return 0 }
            if bits >= 64 {
                if t >= 18446744073709551616.0 { return UInt64.max }
            } else if t >= Double(UInt64(1) << bits) {
                return (UInt64(1) << bits) - 1
            }
            return UInt64(t)
        } else {
            if bits >= 64 {
                if t >= 9223372036854775808.0 { return 0x7FFF_FFFF_FFFF_FFFF }
                if t < -9223372036854775808.0 { return 0x8000_0000_0000_0000 }
                return UInt64(bitPattern: Int64(t))
            }
            let limit = Double(Int64(1) << (bits - 1))
            if t >= limit { return (UInt64(1) << (bits - 1)) - 1 }
            if t < -limit { return UInt64(1) << (bits - 1) }
            return UInt64(bitPattern: Int64(t)) & ((UInt64(1) << bits) - 1)
        }
    }

    /// LD1〜LD4 / ST1〜ST4（複数構造・単一構造・レプリケート、ポストインデックス付き）
    func executeStructLoadStore(_ insn: UInt32, rd: Int, rn: Int, rm: Int) throws -> Bool {
        let top = (insn >> 24) & 0xBF
        guard top == 0x0C || top == 0x0D else { return false }
        let q = insn & 0x4000_0000 != 0
        let isLoad = insn & 0x0040_0000 != 0
        let postIndex = insn & 0x0080_0000 != 0
        let single = insn & 0x0100_0000 != 0
        let base = readReg(rn, sp: true)
        var transferBytes = 0
        if !single {
            // 複数構造: opcode = bits[15:12]、要素サイズ = bits[11:10]
            let opc = Int((insn >> 12) & 0xF)
            let esize = 1 << Int((insn >> 10) & 0x3)
            let lanes = (q ? 16 : 8) / esize
            let nStruct: Int
            let interleaved: Bool
            switch opc {
            case 7: nStruct = 1; interleaved = false
            case 10: nStruct = 2; interleaved = false
            case 6: nStruct = 3; interleaved = false
            case 2: nStruct = 4; interleaved = false
            case 8: nStruct = 2; interleaved = true
            case 4: nStruct = 3; interleaved = true
            case 0: nStruct = 4; interleaved = true
            default: return false
            }
            transferBytes = nStruct * lanes * esize
            if isLoad {
                var regs: [[UInt8]] = (0..<nStruct).map { _ in [UInt8](repeating: 0, count: 16) }
                if interleaved {
                    for e in 0..<(lanes * nStruct) {
                        let v = try loadValue(address: base &+ UInt64(e * esize), size: esize)
                        laneSet(&regs[e % nStruct], e / nStruct, esize, v)
                    }
                } else {
                    for k in 0..<nStruct {
                        for l in 0..<lanes {
                            let v = try loadValue(address: base &+ UInt64((k * lanes + l) * esize), size: esize)
                            laneSet(&regs[k], l, esize, v)
                        }
                    }
                }
                for k in 0..<nStruct { setVRegBytes((rd + k) & 0x1F, regs[k], q: q) }
            } else {
                let regs: [[UInt8]] = (0..<nStruct).map { vRegBytes((rd + $0) & 0x1F) }
                if interleaved {
                    for e in 0..<(lanes * nStruct) {
                        try storeValue(address: base &+ UInt64(e * esize), size: esize,
                                       laneGet(regs[e % nStruct], e / nStruct, esize))
                    }
                } else {
                    for k in 0..<nStruct {
                        for l in 0..<lanes {
                            try storeValue(address: base &+ UInt64((k * lanes + l) * esize), size: esize,
                                           laneGet(regs[k], l, esize))
                        }
                    }
                }
            }
        } else {
            // 単一構造 / レプリケート: opc = bits[15:13]、R = bit21、T = bits[12:10]
            let opc = Int((insn >> 13) & 0x7)
            let rBit = insn & 0x0020_0000 != 0
            let t = Int((insn >> 10) & 0x7)
            if opc >= 6 {
                // レプリケート: T = 要素サイズ log2
                let nStruct = opc == 6 ? (rBit ? 2 : 1) : (rBit ? 4 : 3)
                let esize = 1 << t
                transferBytes = nStruct * esize
                guard isLoad else { return false }
                for k in 0..<nStruct {
                    let v = try loadValue(address: base &+ UInt64(k * esize), size: esize)
                    var out = [UInt8](repeating: 0, count: 16)
                    let total = q ? 16 : 8
                    for l in 0..<(total / esize) { laneSet(&out, l, esize, v) }
                    setVRegBytes((rd + k) & 0x1F, out, q: q)
                }
            } else {
                let nStruct: Int
                let esizeLog2: Int
                switch opc {
                case 0, 1: nStruct = opc == 0 ? (rBit ? 2 : 1) : (rBit ? 4 : 3); esizeLog2 = 0
                case 2, 3: nStruct = opc == 2 ? (rBit ? 2 : 1) : (rBit ? 4 : 3); esizeLog2 = 1
                default: nStruct = opc == 4 ? (rBit ? 2 : 1) : (rBit ? 4 : 3); esizeLog2 = t & 1 == 1 ? 3 : 2
                }
                let esize = 1 << esizeLog2
                let u = ((q ? 1 : 0) << 3) | t
                let index = u >> esizeLog2
                transferBytes = nStruct * esize
                if isLoad {
                    for k in 0..<nStruct {
                        let v = try loadValue(address: base &+ UInt64(k * esize), size: esize)
                        var out = vRegBytes((rd + k) & 0x1F)
                        laneSet(&out, index, esize, v)
                        setVRegBytes((rd + k) & 0x1F, out)
                    }
                } else {
                    for k in 0..<nStruct {
                        let out = vRegBytes((rd + k) & 0x1F)
                        try storeValue(address: base &+ UInt64(k * esize), size: esize,
                                       laneGet(out, index, esize))
                    }
                }
            }
        }
        if postIndex {
            let delta = rm == 31 ? UInt64(transferBytes) : readReg(rm)
            writeReg(rn, base &+ delta, sp: true)
        }
        return true
    }


    // MARK: - 暗号命令（SHA1 / SHA256 / SHA512 / SHA3 / AES）
    // 意味論は QEMU の crypto_helper.c（ARM ARM 準拠）を移植し、qemu-aarch64 の
    // 実行結果（オラクル）と全命令・複数入力で一致を検証済み（tests/crypto）。

    static let aesSBox: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
    ]
    static let aesInvSBox: [UInt8] = [
        0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
        0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
        0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
        0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
        0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
        0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
        0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
        0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
        0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
        0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
        0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
        0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
        0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
        0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
        0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D,
    ]

    func executeCrypto(_ insn: UInt32, rd: Int, rn: Int, rm: Int) -> Bool {
        func w32(_ r: Int, _ i: Int) -> UInt32 {
            let v = i < 2 ? fpRegisters[r * 2] : fpRegisters[r * 2 + 1]
            return UInt32(truncatingIfNeeded: v >> (32 * (i & 1)))
        }
        func setW(_ r: Int, _ w: [UInt32]) {
            fpRegisters[r * 2] = UInt64(w[0]) | (UInt64(w[1]) << 32)
            fpRegisters[r * 2 + 1] = UInt64(w[2]) | (UInt64(w[3]) << 32)
        }
        func rol32(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
        func ror32(_ v: UInt32, _ n: UInt32) -> UInt32 { (v >> n) | (v << (32 - n)) }
        func rol64(_ v: UInt64, _ n: UInt64) -> UInt64 { (v << n) | (v >> (64 - n)) }
        func ror64(_ v: UInt64, _ n: UInt64) -> UInt64 { (v >> n) | (v << (64 - n)) }
        func cho(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & (y ^ z)) ^ z }
        func par(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        func maj(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | ((x | y) & z) }

        // AES: (insn & 0xFFFF8C00) == 0x4E280800、opcode = bits[14:12]
        if (insn & 0xFFFF_8C00) == 0x4E28_0800 {
            let opc = Int((insn >> 12) & 0x7)
            switch opc {
            case 4, 5:  // AESE / AESD: Rd ^= Rn の後に 1 ラウンド（MixColumns なし）
                var b = vRegBytes(rd)
                let k = vRegBytes(rn)
                for i in 0..<16 { b[i] ^= k[i] }
                if opc == 4 {
                    for i in 0..<16 { b[i] = Self.aesSBox[Int(b[i])] }
                    var out = [UInt8](repeating: 0, count: 16)
                    for c in 0..<4 { for r in 0..<4 { out[r + 4 * c] = b[r + 4 * ((c + r) & 3)] } }
                    setVRegBytes(rd, out)
                } else {
                    var sh = [UInt8](repeating: 0, count: 16)
                    for c in 0..<4 { for r in 0..<4 { sh[r + 4 * c] = b[r + 4 * ((c + 4 - r) & 3)] } }
                    for i in 0..<16 { sh[i] = Self.aesInvSBox[Int(sh[i])] }
                    setVRegBytes(rd, sh)
                }
                return true
            case 6, 7:  // AESMC / AESIMC: Rn に対する MixColumns / InvMixColumns のみ
                let b = vRegBytes(rn)
                func mul(_ a: UInt8, _ f: UInt8) -> UInt8 {
                    var x = a, r: UInt8 = 0, f = f
                    for _ in 0..<8 {
                        if f & 1 != 0 { r ^= x }
                        x = (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)
                        f >>= 1
                    }
                    return r
                }
                var out = [UInt8](repeating: 0, count: 16)
                for c in 0..<4 {
                    let a0 = b[4 * c], a1 = b[4 * c + 1], a2 = b[4 * c + 2], a3 = b[4 * c + 3]
                    if opc == 6 {
                        out[4 * c] = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3
                        out[4 * c + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3
                        out[4 * c + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3)
                        out[4 * c + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2)
                    } else {
                        out[4 * c] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9)
                        out[4 * c + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13)
                        out[4 * c + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11)
                        out[4 * c + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14)
                    }
                }
                setVRegBytes(rd, out)
                return true
            default:
                return false
            }
        }

        // SHA1 / SHA256 3 レジスタ: (insn & 0xFF208C00) == 0x5E000000、opcode = bits[14:12]
        if (insn & 0xFF20_8C00) == 0x5E00_0000 {
            let opc = Int((insn >> 12) & 0x7)
            switch opc {
            case 0, 1, 2:  // SHA1C / SHA1P / SHA1M
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                var e = w32(rn, 0)
                let m = [w32(rm, 0), w32(rm, 1), w32(rm, 2), w32(rm, 3)]
                let f: (UInt32, UInt32, UInt32) -> UInt32 = opc == 0 ? cho : (opc == 1 ? par : maj)
                for i in 0..<4 {
                    var t = f(d[1], d[2], d[3])
                    t = t &+ rol32(d[0], 5) &+ e &+ m[i]
                    e = d[3]
                    d[3] = d[2]
                    d[2] = ror32(d[1], 2)
                    d[1] = d[0]
                    d[0] = t
                }
                setW(rd, d)
                return true
            case 3:  // SHA1SU0
                let dLo = fpRegisters[rd * 2], dHi = fpRegisters[rd * 2 + 1]
                let nLo = fpRegisters[rn * 2]
                let mLo = fpRegisters[rm * 2], mHi = fpRegisters[rm * 2 + 1]
                fpRegisters[rd * 2] = dHi ^ dLo ^ mLo
                fpRegisters[rd * 2 + 1] = nLo ^ dHi ^ mHi
                return true
            case 4:  // SHA256H
                func s1(_ x: UInt32) -> UInt32 { ror32(x, 6) ^ ror32(x, 11) ^ ror32(x, 25) }
                func s0(_ x: UInt32) -> UInt32 { ror32(x, 2) ^ ror32(x, 13) ^ ror32(x, 22) }
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                var n = [w32(rn, 0), w32(rn, 1), w32(rn, 2), w32(rn, 3)]
                let m = [w32(rm, 0), w32(rm, 1), w32(rm, 2), w32(rm, 3)]
                for i in 0..<4 {
                    var t = cho(n[0], n[1], n[2]) &+ n[3] &+ s1(n[0]) &+ m[i]
                    n[3] = n[2]; n[2] = n[1]; n[1] = n[0]
                    n[0] = d[3] &+ t
                    t = t &+ maj(d[0], d[1], d[2]) &+ s0(d[0])
                    d[3] = d[2]; d[2] = d[1]; d[1] = d[0]; d[0] = t
                }
                setW(rd, d)
                return true
            case 5:  // SHA256H2
                func s1(_ x: UInt32) -> UInt32 { ror32(x, 6) ^ ror32(x, 11) ^ ror32(x, 25) }
                func s0(_ x: UInt32) -> UInt32 { ror32(x, 2) ^ ror32(x, 13) ^ ror32(x, 22) }
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                let n = [w32(rn, 0), w32(rn, 1), w32(rn, 2), w32(rn, 3)]
                let m = [w32(rm, 0), w32(rm, 1), w32(rm, 2), w32(rm, 3)]
                for i in 0..<4 {
                    var t = cho(d[0], d[1], d[2]) &+ d[3] &+ s1(d[0]) &+ m[i]
                    d[3] = d[2]; d[2] = d[1]; d[1] = d[0]
                    d[0] = n[3 - i] &+ t
                }
                setW(rd, d)
                return true
            case 6:  // SHA256SU1
                func s1(_ x: UInt32) -> UInt32 { ror32(x, 17) ^ ror32(x, 19) ^ (x >> 10) }
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                let n = [w32(rn, 0), w32(rn, 1), w32(rn, 2), w32(rn, 3)]
                let m = [w32(rm, 0), w32(rm, 1), w32(rm, 2), w32(rm, 3)]
                d[0] = d[0] &+ s1(m[2]) &+ n[1]
                d[1] = d[1] &+ s1(m[3]) &+ n[2]
                d[2] = d[2] &+ s1(d[0]) &+ n[3]
                d[3] = d[3] &+ s1(d[1]) &+ m[0]
                setW(rd, d)
                return true
            default:
                return false
            }
        }

        // SHA1 / SHA256 2 レジスタ: (insn & 0xFF208C00) == 0x5E200800、opcode = bits[14:12]
        if (insn & 0xFF20_8C00) == 0x5E20_0800 {
            let opc = Int((insn >> 12) & 0x7)
            switch opc {
            case 0:  // SHA1H: Rd.w0 = ror(Rn.w0, 2)、他は 0
                setW(rd, [ror32(w32(rn, 0), 2), 0, 0, 0])
                return true
            case 1:  // SHA1SU1
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                let m = [w32(rn, 0), w32(rn, 1), w32(rn, 2), w32(rn, 3)]
                d[0] = rol32(d[0] ^ m[1], 1)
                d[1] = rol32(d[1] ^ m[2], 1)
                d[2] = rol32(d[2] ^ m[3], 1)
                d[3] = rol32(d[3] ^ d[0], 1)
                setW(rd, d)
                return true
            case 2:  // SHA256SU0
                func s0(_ x: UInt32) -> UInt32 { ror32(x, 7) ^ ror32(x, 18) ^ (x >> 3) }
                var d = [w32(rd, 0), w32(rd, 1), w32(rd, 2), w32(rd, 3)]
                d[0] = d[0] &+ s0(d[1])
                d[1] = d[1] &+ s0(d[2])
                d[2] = d[2] &+ s0(d[3])
                d[3] = d[3] &+ s0(w32(rn, 0))
                setW(rd, d)
                return true
            default:
                return false
            }
        }

        // SHA512 3 レジスタ: (insn & 0xFFE0F000) == 0xCE608000、opcode = bits[11:10]
        if (insn & 0xFFE0_F000) == 0xCE60_8000 {
            let opc = Int((insn >> 10) & 0x3)
            var d0 = fpRegisters[rd * 2], d1 = fpRegisters[rd * 2 + 1]
            let n0 = fpRegisters[rn * 2], n1 = fpRegisters[rn * 2 + 1]
            let m0 = fpRegisters[rm * 2], m1 = fpRegisters[rm * 2 + 1]
            func cho512(_ x: UInt64, _ y: UInt64, _ z: UInt64) -> UInt64 { (x & (y ^ z)) ^ z }
            func maj512(_ x: UInt64, _ y: UInt64, _ z: UInt64) -> UInt64 { (x & y) | ((x | y) & z) }
            func bigS1(_ x: UInt64) -> UInt64 { ror64(x, 14) ^ ror64(x, 18) ^ ror64(x, 41) }
            func bigS0(_ x: UInt64) -> UInt64 { ror64(x, 28) ^ ror64(x, 34) ^ ror64(x, 39) }
            func smallS1(_ x: UInt64) -> UInt64 { ror64(x, 19) ^ ror64(x, 61) ^ (x >> 6) }
            switch opc {
            case 0:  // SHA512H
                d1 = d1 &+ bigS1(m1) &+ cho512(m1, n0, n1)
                d0 = d0 &+ bigS1(d1 &+ m0) &+ cho512(d1 &+ m0, m1, n0)
            case 1:  // SHA512H2
                d1 = d1 &+ bigS0(m0) &+ maj512(n0, m1, m0)
                d0 = d0 &+ bigS0(d1) &+ maj512(d1, m0, m1)
            case 2:  // SHA512SU1
                d0 = d0 &+ smallS1(n0) &+ m0
                d1 = d1 &+ smallS1(n1) &+ m1
            case 3:  // RAX1（FEAT_SHA3）: QEMU a64.decode では SHA512 3 レジスタ
                // グループ内 bits[15:10] = 100011 に配置され、aa64_sha3 でゲート。
                // 意味論は QEMU crypto_helper.c の crypto_rax1:
                //   Vd.d[i] = Vn.d[i] ^ rol64(Vm.d[i], 1)
                d0 = n0 ^ rol64(m0, 1)
                d1 = n1 ^ rol64(m1, 1)
            default:
                return false
            }
            fpRegisters[rd * 2] = d0
            fpRegisters[rd * 2 + 1] = d1
            return true
        }

        // SHA3 4 レジスタ（FEAT_SHA3）: QEMU a64.decode の
        //   EOR3  1100 1110 000 rm 0 ra rn rd
        //   BCAX  1100 1110 001 rm 0 ra rn rd
        // 意味論は QEMU gengvec64.c の gen_gvec_eor3 / gen_gvec_bcax
        // （do_gvec_fn4 の引数順 rd, rn, rm, ra）:
        //   EOR3: Vd = Vn ^ Vm ^ Va
        //   BCAX: Vd = Vn ^ (Vm & ~Va)   （いずれも 128 ビット全体のビット演算）
        // qemu-aarch64 オラクルとの差分で全ケース一致を検証済み（tests/sha3）。
        if (insn & 0xFFE0_8000) == 0xCE00_0000 || (insn & 0xFFE0_8000) == 0xCE20_0000 {
            let ra = Int((insn >> 10) & 0x1F)
            let isBCAX = (insn & 0x0020_0000) != 0
            for lane in 0..<2 {
                let n = fpRegisters[rn * 2 + lane]
                let m = fpRegisters[rm * 2 + lane]
                let a = fpRegisters[ra * 2 + lane]
                fpRegisters[rd * 2 + lane] = isBCAX ? (n ^ (m & ~a)) : (n ^ m ^ a)
            }
            return true
        }

        // SHA3 XAR（FEAT_SHA3）: QEMU a64.decode の
        //   XAR  1100 1110 100 rm imm6 rn rd
        // 意味論は QEMU vec_helper.c の gvec_xar_d:
        //   Vd.d[i] = ror64(Vn.d[i] ^ Vm.d[i], imm6)
        if (insn & 0xFFE0_0000) == 0xCE80_0000 {
            let imm = UInt64((insn >> 10) & 0x3F)
            for lane in 0..<2 {
                let v = fpRegisters[rn * 2 + lane] ^ fpRegisters[rm * 2 + lane]
                fpRegisters[rd * 2 + lane] = imm == 0 ? v : ror64(v, imm)
            }
            return true
        }

        // SHA512SU0 2 レジスタ: (insn & 0xFFE0FC00) == 0xCEC08000
        if (insn & 0xFFE0_FC00) == 0xCEC0_8000 {
            func smallS0(_ x: UInt64) -> UInt64 { ror64(x, 1) ^ ror64(x, 8) ^ (x >> 7) }
            let d0 = fpRegisters[rd * 2], d1 = fpRegisters[rd * 2 + 1]
            fpRegisters[rd * 2] = d0 &+ smallS0(d1)
            fpRegisters[rd * 2 + 1] = d1 &+ smallS0(fpRegisters[rn * 2])
            return true
        }

        return false
    }

    func executeSIMDVector(_ insn: UInt32, rd: Int, rn: Int, rm: Int) throws -> Bool {
        // 暗号命令（SHA1/SHA256/SHA512/AES）: 他のデコード空間と衝突し得るため最優先で判定
        if executeCrypto(insn, rd: rd, rn: rn, rm: rm) { return true }
        // 構造体ロード / ストア（LD1〜LD4 / ST1〜ST4）
        if try executeStructLoadStore(insn, rd: rd, rn: rn, rm: rm) { return true }
        // テーブル参照（TBL / TBX）: QEMU a64.decode の TBL_TBX パターン
        // `0 q 00 1110 000 rm 0 len tbx 00 rn rd` 通り、bits 23:21 = 000
        // （bit21 = 0）まで含めて判定する。bit21 を落とすと bit21 = 1 の
        // 3 ソース異なる幅グループ（SADDL / SADDW / SSUBL / SSUBW / SABAL /
        // SABDL の B/H/S 全サイズ、opc bit3 = 0 のもの）を TBL と誤読する
        // （根本原因 #24 と同型の過小マスク。実測: SADDL が TBL として実行された）。
        if (insn & 0xBFE0_8000) == 0x0E00_0000 && (insn & 0x0000_0C00) == 0 {
            let q = insn & 0x4000_0000 != 0
            let len = Int((insn >> 13) & 0x3)
            let isTBX = insn & 0x0000_1000 != 0
            var table: [UInt8] = []
            for k in 0...len { table += vRegBytes((rn + k) & 0x1F) }
            let idx = vRegBytes(rm)
            let orig = vRegBytes(rd)
            var out = [UInt8](repeating: 0, count: 16)
            let total = q ? 16 : 8
            for i in 0..<total {
                let ix = Int(idx[i])
                out[i] = ix < table.count ? table[ix] : (isTBX ? orig[i] : 0)
            }
            setVRegBytes(rd, out, q: q)
            return true
        }
        // 変更即値 / シフト即値 / 要素指定グループ（bit24 = 1）
        //   要素指定（by-element）グループは bit10 = 0 で、bit23 は要素サイズの
        //   一部になる。一方シフト即値グループは bits 28–23 = 011110（bit23 = 0）
        //   かつ bit10 = 1 が固定、変更即値も bit23 = 0 かつ bit10 = 1 が固定。
        //   bit24 だけで振り分けると要素指定形式をシフト即値と誤読する
        //   （根本原因 #24: UMULL / MLS by element が USHLL 等に化けた）。
        if insn & 0x0100_0000 != 0 {
            if insn & 0x0000_0400 == 0 {
                return executeSIMDByElement(insn, rd: rd, rn: rn)
            }
            if insn & 0x0080_0000 == 0 {
                if ((insn >> 19) & 0xF) == 0 {
                    return executeModifiedImmediate(insn, rd: rd)
                }
                return executeShiftImmediate(insn, rd: rd, rn: rn)
            }
            // bit24 = 1、bit10 = 1、bit23 = 1 は予約空間（未定義命令として落とす）
            return false
        }
        // コピーグループ
        if executeSIMDCopy(insn, rd: rd, rn: rn, rm: rm) { return true }
        let bit10 = insn & 0x0000_0400 != 0
        if !bit10 {
            if insn & 0x0020_0000 == 0 {
                // 並べ替え（EXT / ZIP / UZP / TRN）: bit21 = 0
                return executeSIMDPermute(insn, rd: rd, rn: rn, rm: rm)
            }
            if insn & 0x0000_0800 == 0 {
                // 3 ソース（異なる幅、ロング / ワイド）: bit21 = 1、bit11 = 0
                return executeSIMDThreeDifferent(insn, rd: rd, rn: rn, rm: rm)
            }
            // 2 レジスタ雑多: bit21 = 1、bit11 = 1
            return executeSIMDTwoRegMisc(insn, rd: rd, rn: rn)
        }
        // 3 ソース
        return try executeSIMDThreeSame(insn, rd: rd, rn: rn, rm: rm,
                                        scalar: (insn & 0x1E00_0000) == 0x1E00_0000)
    }

    // MARK: 変更即値（MOVI / MVNI / ORR / BIC 即値）

    func executeModifiedImmediate(_ insn: UInt32, rd: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let op = insn & 0x2000_0000 != 0
        let cmode = Int((insn >> 12) & 0xF)
        let imm8 = ((insn >> 16) & 0x7) << 5 | ((insn >> 5) & 0x1F)
        var out = [UInt8](repeating: 0, count: 16)
        let total = q ? 16 : 8
        // cmode の偶奇が命令形を分ける（clang の出力で実証）:
        //   LSL 形: 偶数 cmode = MOVI/MVNI（代入）、奇数 cmode = ORR/BIC（宛先との読み替え合成）
        //   MSL 形（12/13）とバイト形（14）は MOVI/MVNI のみで、ORR/BIC には存在しない。
        //   cmode 9 は「16 ビット MSL」ではなく ORR/BIC の 16 ビット LSL #0、
        //   cmode 11 は ORR/BIC の 16 ビット LSL #8（AVPBooter が使用。未対応だと未定義命令になる）。
        let rmw = (cmode % 2 == 1) && cmode <= 11
        func apply(laneBytes: Int, value: UInt64) {
            let mask: UInt64 = laneBytes >= 8 ? UInt64.max : (UInt64(1) << UInt64(laneBytes * 8)) - 1
            if rmw {
                let d = vRegBytes(rd)
                for i in 0..<(total / laneBytes) {
                    let cur = laneGet(d, i, laneBytes)
                    laneSet(&out, i, laneBytes, (op ? cur & ~value : cur | value) & mask)
                }
            } else {
                let v = (op ? ~value : value) & mask
                for i in 0..<(total / laneBytes) { laneSet(&out, i, laneBytes, v) }
            }
        }
        switch cmode {
        case 0, 1, 2, 3, 4, 5, 6, 7:
            // 32 ビットレーン LSL（シフト量は cmode<2:1> * 8）
            apply(laneBytes: 4, value: UInt64(UInt32(imm8) << UInt32((cmode >> 1) * 8)))
        case 8, 9:
            // 16 ビットレーン LSL #0（8 = MOVI/MVNI、9 = ORR/BIC）
            apply(laneBytes: 2, value: UInt64(imm8))
        case 10, 11:
            // 16 ビットレーン LSL #8（10 = MOVI/MVNI、11 = ORR/BIC）
            apply(laneBytes: 2, value: UInt64(imm8) << 8)
        case 12:
            // 32 ビットレーン MSL #8（MOVI/MVNI のみ）
            apply(laneBytes: 4, value: UInt64((UInt32(imm8) << 8) | 0xFF))
        case 13:
            // 32 ビットレーン MSL #16（MOVI/MVNI のみ）
            apply(laneBytes: 4, value: UInt64((UInt32(imm8) << 16) | 0xFFFF))
        case 14:
            if op {
                // 64 ビット: 各ビットをバイトへ展開（MOVI のみ）
                var value: UInt64 = 0
                for i in 0..<8 where (imm8 >> i) & 1 != 0 {
                    value |= UInt64(0xFF) << (8 * i)
                }
                laneSet(&out, 0, 8, value)
                if q { laneSet(&out, 1, 8, value) }
            } else {
                // バイト複製
                for i in 0..<total { out[i] = UInt8(imm8) }
            }
        case 15:
            // FMOV (vector, immediate): cmode=15 は浮動小数点即値（fsck の SIGILL の原因となった命令）。
            //   op=0 → 32 ビット FP 即値を全 32 ビットレーンへ複製（.2S/.4S）
            //   op=1, q=1 → 64 ビット FP 即値を全 64 ビットレーンへ複製（.2D）
            //   op=1, q=0 → 未割り当て（QEMU trans_Vimm (translate-a64.c:7422) も false）
            // bits11:10==11 は FMOVI_v_h（半精度）で、FP16 未実装のため未対応のまま落とす
            //   （32 ビット FP として誤デコードしないこと）。
            // 即値展開は QEMU asimd_imm_const (translate.c:83) と同一（ARM ARM AdvSIMDExpandImm）。
            // 注意: 既存の apply() は op を MVNI の反転と解釈するため、cmode=15 では使えない
            // （op は 64 ビット選択であって反転ではない）。レーンは直接書く。
            guard (insn & 0xC00) == 0x400 else { return false }  // bits11:10 == 01
            if op {
                guard q else { return false }  // 未割り当て
                let imm64: UInt64 = (UInt64(imm8 & 0x3F) << 48)
                    | ((imm8 & 0x80) != 0 ? 0x8000_0000_0000_0000 : 0)
                    | ((imm8 & 0x40) != 0 ? 0x3FC0_0000_0000_0000 : 0x4000_0000_0000_0000)
                laneSet(&out, 0, 8, imm64)
                laneSet(&out, 1, 8, imm64)
            } else {
                let imm32: UInt32 = (UInt32(imm8 & 0x80) << 24)
                    | (UInt32(imm8 & 0x3F) << 19)
                    | ((imm8 & 0x40) != 0 ? 0x3E00_0000 : 0x4000_0000)  // 0x1F<<25 = 0x3E000000
                for i in 0..<(total / 4) { laneSet(&out, i, 4, UInt64(imm32)) }
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: q)
        return true
    }

    // MARK: シフト即値

    func executeShiftImmediate(_ insn: UInt32, rd: Int, rn: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let immh = Int((insn >> 19) & 0xF)
        let combined = Int((insn >> 16) & 0x7F)
        let opc = Int((insn >> 11) & 0x1F)
        let elemBits = immh >= 8 ? 64 : immh >= 4 ? 32 : immh >= 2 ? 16 : 8
        let elemBytes = elemBits / 8
        let scalar = (insn & 0x1E00_0000) == 0x1E00_0000
        let n = vRegBytes(rn)
        var out = [UInt8](repeating: 0, count: 16)

        // ナローイング（SHRN 系）: 要素幅は宛先幅、ソースは 2 倍幅
        if opc == 16 || opc == 18 {
            // 宛先要素幅 destBits に対し combined は [destBits, 2*destBits) の範囲。
            // 下限ちょうど（例: 8 ビット宛先でシフト 8）も正規の符号化なので含める。
            // 範囲外は未割り当て符号化として弾く（無限ループでのオーバーフロー trap 回避）。
            guard combined >= 8 && combined <= 127 else { return false }
            var destBits = 8
            while !(combined >= destBits && combined < 2 * destBits) { destBits *= 2 }
            let elemBits = destBits
            let elemBytes = destBits / 8
            let shift = 2 * elemBits - combined
            let srcBytes = elemBytes * 2
            let count = 8 / elemBytes
            for i in 0..<count {
                let r: UInt64
                if opc == 16 {
                    // SHRN: 論理シフトして下位を取る
                    let sv = laneGet(n, i, srcBytes)
                    r = (shift >= 64 ? 0 : (sv >> shift)) & ((UInt64(1) << elemBits) - 1)
                } else if !u {
                    // SQSHRN
                    let sv = laneSigned(n, i, srcBytes)
                    let shifted = shift >= 64 ? (sv < 0 ? Int64(-1) : 0) : (sv >> shift)
                    r = saturateSigned(shifted, bits: elemBits)
                } else {
                    // UQSHRN
                    let sv = laneSigned(n, i, srcBytes)
                    let shifted = shift >= 64 ? (sv < 0 ? Int64(-1) : 0) : (sv >> shift)
                    r = saturateUnsigned(shifted, bits: elemBits)
                }
                laneSet(&out, i, elemBytes, r)
            }
            setVRegBytes(rd, out, q: false)
            return true
        }

        // ロングシフト（SSHLL / USHLL）: 宛先要素はソースの 2 倍幅、宛先は常に 128 ビット
        if opc == 20 {
            let shift = combined - elemBits
            guard shift >= 0 && shift < elemBits else { return false }   // 範囲外は未割り当て符号化
            let srcLanes = 8 / elemBytes
            let baseLane = q ? srcLanes : 0
            let destMask: UInt64 = elemBits * 2 >= 64 ? UInt64.max : ((UInt64(1) << (elemBits * 2)) - 1)
            for i in 0..<srcLanes {
                let v: UInt64 = u ? laneGet(n, baseLane + i, elemBytes)
                                  : UInt64(bitPattern: laneSigned(n, baseLane + i, elemBytes))
                laneSet(&out, i, elemBytes * 2, (shift >= 64 ? 0 : (v << shift)) & destMask)
            }
            setVRegBytes(rd, out)
            return true
        }

        let total = scalar ? elemBytes : (q ? 16 : 8)
        let lanes = total / elemBytes
        let elemMask: UInt64 = elemBits >= 64 ? UInt64.max : (UInt64(1) << elemBits) - 1
        switch (opc, u) {
        case (10, false):
            // SHL
            let shift = combined - elemBits
            guard shift >= 0 && shift < elemBits else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, elemBytes, (laneGet(n, i, elemBytes) << shift) & elemMask)
            }
        case (10, true):
            // SLI: シフト結果の下位ビットへ元の宛先を挿入
            let shift = combined - elemBits
            guard shift >= 0 && shift < elemBits else { return false }
            let d = vRegBytes(rd)
            let keepMask: UInt64 = shift == 0 ? 0 : ((shift >= 64 ? UInt64.max : (UInt64(1) << shift) - 1) & elemMask)
            for i in 0..<lanes {
                laneSet(&out, i, elemBytes, ((laneGet(n, i, elemBytes) << shift) & elemMask) | (laneGet(d, i, elemBytes) & keepMask))
            }
        case (0, false), (0, true):
            // SSHR / USHR
            let shift = 2 * elemBits - combined
            for i in 0..<lanes {
                if u {
                    laneSet(&out, i, elemBytes, shift >= 64 ? 0 : (laneGet(n, i, elemBytes) >> shift))
                } else if shift >= 64 {
                    laneSet(&out, i, elemBytes, laneSigned(n, i, elemBytes) < 0 ? elemMask : 0)
                } else {
                    laneSet(&out, i, elemBytes, UInt64(bitPattern: laneSigned(n, i, elemBytes) >> shift) & elemMask)
                }
            }
        case (2, false), (2, true):
            // SSRA / USRA（宛先へ累算）
            let shift = 2 * elemBits - combined
            let d = vRegBytes(rd)
            for i in 0..<lanes {
                let shifted: UInt64
                if u {
                    shifted = shift >= 64 ? 0 : (laneGet(n, i, elemBytes) >> shift)
                } else if shift >= 64 {
                    shifted = laneSigned(n, i, elemBytes) < 0 ? elemMask : 0
                } else {
                    shifted = UInt64(bitPattern: laneSigned(n, i, elemBytes) >> shift) & elemMask
                }
                laneSet(&out, i, elemBytes, (laneGet(d, i, elemBytes) &+ shifted) & elemMask)
            }
        case (8, true):
            // SRI: シフト結果の上位ビットへ元の宛先を残す
            let shift = 2 * elemBits - combined
            let d = vRegBytes(rd)
            for i in 0..<lanes {
                let lowMask: UInt64 = shift >= elemBits ? elemMask : ((UInt64(1) << (elemBits - shift)) - 1)
                let keep = laneGet(d, i, elemBytes) & ~lowMask & elemMask
                let shifted = shift >= 64 ? 0 : (laneGet(n, i, elemBytes) >> shift)
                laneSet(&out, i, elemBytes, (shifted | keep) & elemMask)
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: scalar ? false : q)
        return true
    }

    // MARK: コピーグループ（DUP / INS / UMOV / SMOV）

    func executeSIMDCopy(_ insn: UInt32, rd: Int, rn: Int, rm: Int) -> Bool {
        guard insn & 0x0020_0000 == 0, insn & 0x0000_0400 != 0 else { return false }
        // スカラ DUP（DUP <Vd>.<T>, <Vn>.<T>[index]）はベクタ空間（0x0E）では
        // なくスカラ空間（0x5E）にある: QEMU a64.decode の DUP_element_s
        // パターン `0101 1110 000 imm5 0 0000 1 rn rd`。意味論は要素を
        // レーン 0 へコピーし、宛先の残りビットを全てゼロにする（コンパイラは
        // `mov b1, v3.b[0]` の別名でゼロ埋めコピーとして多用する）。
        // この空間を通さないと命令が 3 ソース（スカラ）へ落ちて誤実行され、
        // corecrypto の AES 鍵スケジュール（ccaes_arm_encrypt_key128）が
        // 破壊されて FIPS POST の AES-ECB KAT が失敗する（根本原因 #25）。
        let scalarDup = (insn & 0xFFE0_FC00) == 0x5E00_0400
        guard scalarDup || (insn & 0x9F00_0000) == 0x0E00_0000 else { return false }
        let q = insn & 0x4000_0000 != 0
        let imm5 = Int((insn >> 16) & 0x1F)
        // U=1 は INS（要素間）専用空間。それ以外は bits[14:11] がオプコード
        let copyOp = insn & 0x2000_0000 != 0 ? -1 : Int((insn >> 11) & 0xF)
        func decodeImm5(_ v: Int) -> (size: Int, index: Int)? {
            for s in 0...3 where v & (1 << s) != 0 {
                return (s, v >> (s + 1))
            }
            return nil
        }
        if scalarDup {
            guard let (sz, idx) = decodeImm5(imm5) else { return false }
            var out = [UInt8](repeating: 0, count: 16)
            laneSet(&out, 0, 1 << sz, laneGet(vRegBytes(rn), idx, 1 << sz))
            setVRegBytes(rd, out)
            return true
        }
        switch copyOp {
        case -1:
            // INS（要素間）: imm5 = 宛先、imm4 = ソース（index << size）
            guard let (sz, dstIdx) = decodeImm5(imm5) else { return false }
            let elemBytes = 1 << sz
            let srcIdx = Int((insn >> 11) & 0xF) >> sz
            var d = vRegBytes(rd)
            let s = vRegBytes(rn)
            laneSet(&d, dstIdx, elemBytes, laneGet(s, srcIdx, elemBytes))
            setVRegBytes(rd, d)
            return true
        case 0b0101:
            // SMOV
            guard let (sz, idx) = decodeImm5(imm5) else { return false }
            let signed = laneSigned(vRegBytes(rn), idx, 1 << sz)
            writeReg(rd, UInt64(bitPattern: signed), width64: q)
            return true
        case 0b0111:
            // UMOV
            guard let (sz, idx) = decodeImm5(imm5) else { return false }
            writeReg(rd, laneGet(vRegBytes(rn), idx, 1 << sz), width64: q)
            return true
        case 0b0011:
            // INS（汎用レジスタから）
            guard let (sz, dstIdx) = decodeImm5(imm5) else { return false }
            var d = vRegBytes(rd)
            laneSet(&d, dstIdx, 1 << sz, readReg(rn))
            setVRegBytes(rd, d)
            return true
        case 0b0000, 0b0001:
            // DUP（要素 / 汎用レジスタ）: bit11 で区別
            guard let (sz, idx) = decodeImm5(imm5) else { return false }
            let elemBytes = 1 << sz
            let total = q ? 16 : 8
            var out = [UInt8](repeating: 0, count: 16)
            if insn & 0x0000_0800 != 0 {
                // DUP（汎用レジスタから）
                let value = readReg(rn)
                for i in 0..<(total / elemBytes) { laneSet(&out, i, elemBytes, value) }
            } else {
                // DUP（要素）
                let value = laneGet(vRegBytes(rn), idx, elemBytes)
                for i in 0..<(total / elemBytes) { laneSet(&out, i, elemBytes, value) }
            }
            setVRegBytes(rd, out, q: q)
            return true
        default:
            return false
        }
    }

    // MARK: 並べ替え（EXT / ZIP / UZP / TRN）

    func executeSIMDPermute(_ insn: UInt32, rd: Int, rn: Int, rm: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let size = Int((insn >> 22) & 0x3)
        let elemBytes = 1 << size
        let total = q ? 16 : 8
        let lanes = total / elemBytes
        let n = vRegBytes(rn)
        let m = vRegBytes(rm)
        var out = [UInt8](repeating: 0, count: 16)
        if u && (insn & 0x0000_8000) == 0 {
            // EXT
            let imm4 = Int((insn >> 11) & 0xF)
            let concat = n + m
            for i in 0..<total { out[i] = concat[imm4 + i] }
            setVRegBytes(rd, out, q: q)
            return true
        }
        let opc = Int((insn >> 11) & 0x1F)
        switch opc {
        case 0b00111, 0b01111:
            // ZIP1 / ZIP2
            let half = lanes / 2
            let base = opc == 0b00111 ? 0 : half
            for i in 0..<half {
                laneSet(&out, 2 * i, elemBytes, laneGet(n, base + i, elemBytes))
                laneSet(&out, 2 * i + 1, elemBytes, laneGet(m, base + i, elemBytes))
            }
        case 0b00011, 0b01011:
            // UZP1 / UZP2
            let odd = opc == 0b01011 ? 1 : 0
            let half = lanes / 2
            for i in 0..<lanes {
                let src = i < half
                    ? laneGet(n, 2 * i + odd, elemBytes)
                    : laneGet(m, 2 * (i - half) + odd, elemBytes)
                laneSet(&out, i, elemBytes, src)
            }
        case 0b00101, 0b01101:
            // TRN1 / TRN2
            let odd = opc == 0b01101 ? 1 : 0
            for i in 0..<lanes {
                let src = i % 2 == 0
                    ? laneGet(n, i + odd, elemBytes)
                    : laneGet(m, i - 1 + odd, elemBytes)
                laneSet(&out, i, elemBytes, src)
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: q)
        return true
    }

    // MARK: 2 レジスタ雑多

    func executeSIMDTwoRegMisc(_ insn: UInt32, rd: Int, rn: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let size = Int((insn >> 22) & 0x3)
        let hi = Int((insn >> 16) & 0x1F)
        let opc = Int((insn >> 11) & 0x1F)
        let scalar = (insn & 0x1E00_0000) == 0x1E00_0000
        let n = vRegBytes(rn)
        var out = [UInt8](repeating: 0, count: 16)
        let total = scalar ? 8 : (q ? 16 : 8)
        // スカラペアワイズ（結果は Vn の隣接 2 レーンから作る）
        if scalar && hi == 17 && opc == 23 && !u {
            // ADDP（整数、D のみ）
            let elemBytes = 1 << size
            laneSet(&out, 0, elemBytes, laneGet(n, 0, elemBytes) &+ laneGet(n, 1, elemBytes))
            setVRegBytes(rd, out)
            return true
        }
        if scalar && hi == 16 && u && (opc == 27 || opc == 31) {
            // FADDP (opc=27) / FMAXP・FMINP (opc=31, bit23 で区別)
            let isDouble = size == 1 || size == 3
            let a = fpScalarFromBytes(n, lane: 0, isDouble: isDouble)
            let b = fpScalarFromBytes(n, lane: 1, isDouble: isDouble)
            let r: Double
            if opc == 27 { r = a + b }
            else if insn & 0x0080_0000 != 0 { r = fpMin(a, b) }
            else { r = fpMax(a, b) }
            setFPScalar(rd, r, isDouble: isDouble)
            return true
        }
        // リダクション（ベクタ全体 → スカラ 1 要素）
        if !scalar && opc == 21 && (hi == 16 || hi == 17) {
            // MAXV (hi=16) / MINV (hi=17)、U で符号を選択
            let elemBytes = 1 << size
            let lanes = total / elemBytes
            func signedVal(_ raw: UInt64) -> Int64 {
                let bits = elemBytes * 8
                if bits >= 64 { return Int64(bitPattern: raw) }
                let shift = 64 - bits
                return (Int64(bitPattern: raw << shift)) >> shift
            }
            var best = laneGet(n, 0, elemBytes)
            for i in 1..<lanes {
                let v = laneGet(n, i, elemBytes)
                let take: Bool
                if u {
                    take = hi == 16 ? v > best : v < best
                } else {
                    take = hi == 16 ? signedVal(v) > signedVal(best) : signedVal(v) < signedVal(best)
                }
                if take { best = v }
            }
            laneSet(&out, 0, elemBytes, best)
            setVRegBytes(rd, out)
            return true
        }
        if !scalar && hi == 16 && opc == 7 && u {
            // UADDLV（全レーンの符号なし和、結果は 2 倍幅）
            let elemBytes = 1 << size
            var sum: UInt64 = 0
            for i in 0..<(total / elemBytes) { sum &+= laneGet(n, i, elemBytes) }
            laneSet(&out, 0, elemBytes * 2, sum)
            setVRegBytes(rd, out)
            return true
        }
        if !scalar && hi == 17 && opc == 23 && !u {
            // ADDV（全レーンの和）
            let elemBytes = 1 << size
            var sum: UInt64 = 0
            for i in 0..<(total / elemBytes) { sum &+= laneGet(n, i, elemBytes) }
            laneSet(&out, 0, elemBytes, sum)
            setVRegBytes(rd, out)
            return true
        }
        if !scalar && hi == 16 && opc == 25 && u {
            // FMAXNMV (bit23=0) / FMINNMV (bit23=1)、S のみ対応
            if size == 0 || size == 2 {
                let isMin = insn & 0x0080_0000 != 0
                var best = fpScalarFromBytes(n, lane: 0, isDouble: false)
                for i in 1..<(total / 4) {
                    let v = fpScalarFromBytes(n, lane: i, isDouble: false)
                    best = isMin ? fpMin(best, v) : fpMax(best, v)
                }
                setFPScalar(rd, best, isDouble: false)
                return true
            }
            return false
        }
        // ゼロとの比較（整数）: CMEQ / CMLE / CMGT / CMGE / CMLT
        if hi == 0 && (opc == 17 || opc == 19 || opc == 21) {
            let elemBytes = 1 << size
            for i in 0..<(total / elemBytes) {
                let sv = laneSigned(n, i, elemBytes)
                let r: Bool
                switch (opc, u) {
                case (19, false): r = sv == 0
                case (19, true): r = sv <= 0
                case (17, false): r = sv > 0
                case (17, true): r = sv >= 0
                default: r = sv < 0
                }
                laneSet(&out, i, elemBytes, r ? UInt64.max : 0)
            }
            setVRegBytes(rd, out)
            return true
        }
        // ゼロとの比較（浮動小数点）: FCMEQ / FCMLE / FCMGT / FCMGE
        if hi == 0 && (opc == 25 || opc == 27) {
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            for i in 0..<(total / elemBytes) {
                let v = fpScalarFromBytes(n, lane: i, isDouble: isDouble)
                let r: Bool
                switch (opc, u) {
                case (27, false): r = v == 0
                case (27, true): r = v <= 0
                case (25, false): r = v > 0
                default: r = v >= 0
                }
                laneSet(&out, i, elemBytes, r ? UInt64.max : 0)
            }
            setVRegBytes(rd, out)
            return true
        }
        switch (hi, opc) {
        case (0, 1):
            // REV64 (U=0) / REV32 (U=1)
            // どちらも size は 0 固定で、反転粒度はコンテナ全体（REV64=8 バイト、REV32=4 バイト）。
            // 以前は 1<<size バイト単位の反転だったため size=0 で恒等写像（無反転）になっていた。
            let container = u ? 4 : 8
            for c in stride(from: 0, to: total, by: container) {
                for j in 0..<container {
                    out[c + j] = n[c + (container - 1 - j)]
                }
            }
        case (0, 3):
            // REV16
            for i in 0..<(total / 2) {
                out[2 * i] = n[2 * i + 1]
                out[2 * i + 1] = n[2 * i]
            }
        case (0, 9):
            // CLS (U=0) / CLZ (U=1)
            let elemBytes = 1 << size
            let bits = elemBytes * 8
            for i in 0..<(total / elemBytes) {
                let v = laneGet(n, i, elemBytes)
                let r: UInt64
                if u {
                    r = UInt64(v.leadingZeroBitCount - (64 - bits))
                } else {
                    let signBit = (v >> (bits - 1)) & 1
                    var count = 0
                    var j = bits - 2
                    while j >= 0 && ((v >> j) & 1) == signBit {
                        count += 1
                        j -= 1
                    }
                    r = UInt64(count)
                }
                laneSet(&out, i, elemBytes, r)
            }
        case (0, 11):
            if u {
                // MVN / NOT（バイト反転）
                for i in 0..<total { out[i] = ~n[i] }
            } else {
                // CNT（バイト単位ポップカウント）
                for i in 0..<total { out[i] = UInt8(n[i].nonzeroBitCount) }
            }
        case (0, 5), (0, 13):
            // ADDLP (opc=5) / ADALP (opc=13)、U が符号を選択。
            // QEMU a64.decode の SADDLP_v / UADDLP_v / SADALP_v / UADALP_v
            // （@qrr_e: `0.00/0.10 1110..1 00000 00101/01101 0 rn rd`）。
            // 意味論は gengvec.c の gen_gvec_addlp / gen_gvec_sadalp /
            // gen_gvec_uadalp: 隣接 2 要素を符号 / ゼロ拡張して加算し、
            // 2 倍幅の宛先要素へ書く。ADALP は宛先要素へ累積する。
            // translate-a64.c の do_gvec_fn2_bhs は esz == MO_64
            // （size == 3）を未定義として弾くため、ここでも落とす。
            if size == 3 { return false }
            let elemBytes = 1 << size
            let dstBytes = elemBytes * 2
            let d = opc == 13 ? vRegBytes(rd) : nil
            for i in 0..<(total / dstBytes) {
                let sum: UInt64
                if u {
                    sum = laneGet(n, 2 * i, elemBytes) &+ laneGet(n, 2 * i + 1, elemBytes)
                } else {
                    sum = UInt64(bitPattern: laneSigned(n, 2 * i, elemBytes))
                        &+ UInt64(bitPattern: laneSigned(n, 2 * i + 1, elemBytes))
                }
                let r = d != nil ? laneGet(d!, i, dstBytes) &+ sum : sum
                laneSet(&out, i, dstBytes, r)
            }
        case (0, 7):
            // SUQADD (U=0) / USQADD (U=1)（宛先がアキュムレータ）。
            // 意味論は QEMU vec_helper.c の DO_SAT 展開が正本:
            //   gvec_suqadd: 宛先は符号付き、ソースは符号なし、符号付き範囲で飽和
            //   gvec_usqadd: 宛先は符号なし、ソースは符号付き、[0, 最大値] で飽和
            // 以前はこの割り当てが逆だった（U=0 で USQADD の意味論を実行していた。
            // qemu-aarch64 オラクル差分で確定、2026-11-19）。
            let elemBytes = 1 << size
            let bits = elemBytes * 8
            let d = vRegBytes(rd)
            for i in 0..<(total / elemBytes) {
                let dv = laneGet(d, i, elemBytes)
                let nv = laneGet(n, i, elemBytes)
                let r: UInt64
                if !u {
                    // SUQADD: 符号付き宛先 + 符号なしソース、符号付き飽和
                    let ds = laneSigned(d, i, elemBytes)
                    if bits >= 64 {
                        if ds >= 0 {
                            let (s, of) = UInt64(ds).addingReportingOverflow(nv)
                            r = of || s > UInt64(Int64.max) ? UInt64(bitPattern: Int64.max) : s
                        } else {
                            let mag = UInt64(bitPattern: 0 &- ds)
                            if nv >= mag {
                                let v = nv - mag
                                r = v > UInt64(Int64.max) ? UInt64(bitPattern: Int64.max) : v
                            } else {
                                r = (0 as UInt64) &- (mag - nv)
                            }
                        }
                    } else {
                        r = saturateSigned(ds + Int64(nv), bits: bits)
                    }
                } else {
                    // USQADD: 符号なし宛先 + 符号付きソース、符号なし飽和
                    let ns = laneSigned(n, i, elemBytes)
                    if bits >= 64 {
                        if ns >= 0 {
                            let (s, of) = dv.addingReportingOverflow(UInt64(bitPattern: ns))
                            r = of ? UInt64.max : s
                        } else {
                            let mag = UInt64(bitPattern: 0 &- ns)
                            r = dv >= mag ? dv - mag : 0
                        }
                    } else {
                        let t = Int64(dv) + ns
                        r = t < 0 ? 0 : min(UInt64(t), (UInt64(1) << bits) - 1)
                    }
                }
                laneSet(&out, i, elemBytes, r)
            }
        case (0, 15):
            // SQABS (U=0) / SQNEG (U=1)
            let elemBytes = 1 << size
            let bits = elemBytes * 8
            for i in 0..<(total / elemBytes) {
                let v = laneSigned(n, i, elemBytes)
                let minV: Int64 = bits >= 64 ? Int64.min : -(Int64(1) << (bits - 1))
                let maxV: Int64 = bits >= 64 ? Int64.max : (Int64(1) << (bits - 1)) - 1
                let r: Int64 = v == minV ? maxV : (u ? -v : (v < 0 ? -v : v))
                laneSet(&out, i, elemBytes, UInt64(bitPattern: r))
            }
        case (0, 23):
            // ABS (U=0) / NEG (U=1)
            let elemBytes = 1 << size
            for i in 0..<(total / elemBytes) {
                let v = laneSigned(n, i, elemBytes)
                let r = u ? (0 &- v) : (v < 0 ? (0 &- v) : v)
                laneSet(&out, i, elemBytes, UInt64(bitPattern: r))
            }
        case (1, 5), (1, 9):
            // XTN (opc=5, U=0) / SQXTUN (opc=5, U=1) /
            // SQXTN (opc=9, U=0) / UQXTN (opc=9, U=1)
            // QEMU a64.decode の XTN / SQXTUN_v / SQXTN_v / UQXTN_v（@qrr_e）。
            // ソースは常に Vn 全体（128 ビット）で、Q が宛先の半分を選ぶ:
            // Q=0 は下位 64 ビットへ書き上位をゼロにし、Q=1（XTN2 等）は
            // 上位 64 ビットへ書き下位を保持する。以前は Q=1 でも下位へ
            // 書いて上位を消していた（qemu-aarch64 オラクル差分で確定、
            // 2026-11-19）。SQXTUN は切り捨てではなく符号なし飽和。
            let srcBytes = 1 << (size + 1)
            let dstBytes = srcBytes / 2
            let count = 8 / dstBytes
            if q {
                let d = vRegBytes(rd)
                for i in 0..<8 { out[i] = d[i] }
            }
            for i in 0..<count {
                let r: UInt64
                if opc == 5 && !u {
                    // XTN: 下位ビットへの切り捨て
                    r = laneGet(n, i, srcBytes) & ((UInt64(1) << (dstBytes * 8)) - 1)
                } else if opc == 9 && u {
                    // UQXTN: ソースは符号なし（QEMU の neon_narrow_sat_u*）。
                    // 以前は符号付きとして読んでおり、0x8000 以上のレーンで
                    // 結果が 0 に潰れていた（オラクル差分で確定、2026-11-19）。
                    r = min(laneGet(n, i, srcBytes), (UInt64(1) << (dstBytes * 8)) - 1)
                } else if !u {
                    // SQXTN: 符号付き飽和
                    r = saturateSigned(laneSigned(n, i, srcBytes), bits: dstBytes * 8)
                } else {
                    // SQXTUN: 符号付きソースを符号なし範囲へ飽和
                    // （QEMU の neon_unarrow_sat*）
                    r = saturateUnsigned(laneSigned(n, i, srcBytes), bits: dstBytes * 8)
                }
                laneSet(&out, (q ? count : 0) + i, dstBytes, r)
            }
            setVRegBytes(rd, out, q: q)
            return true
        case (0, 31), (1, 31):
            // FABS (hi=0,U=0) / FNEG (hi=0,U=1) / FSQRT (hi=1)
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            for i in 0..<(total / elemBytes) {
                let v = fpLane(n, i, isDouble: isDouble)
                let r = hi == 1 ? v.squareRoot() : (u ? -v : abs(v))
                setFPLane(&out, i, r, isDouble: isDouble)
            }
        case (1, 17):
            // FRINT（ベクタ、最近接偶数）
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            for i in 0..<(total / elemBytes) {
                setFPLane(&out, i, roundToNearestEven(fpLane(n, i, isDouble: isDouble)), isDouble: isDouble)
            }
        case (1, 23):
            // FCVTZS (U=0) / FCVTZU (U=1)（ベクタ）
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            for i in 0..<(total / elemBytes) {
                let r = fpToIntSaturated(fpLane(n, i, isDouble: isDouble), bits: elemBytes * 8, unsigned: u)
                laneSet(&out, i, elemBytes, r)
            }
        case (1, 27):
            // SCVTF (U=0) / UCVTF (U=1)（ベクタ）
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            for i in 0..<(total / elemBytes) {
                let value = u ? Double(laneGet(n, i, elemBytes)) : Double(laneSigned(n, i, elemBytes))
                setFPLane(&out, i, value, isDouble: isDouble)
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: scalar ? false : q)
        return true
    }

    // MARK: 多項式乗算ヘルパ

    /// キャリーレス乗算（8 ビット → 16 ビット）
    func carrylessMultiply8(_ a: UInt8, _ b: UInt8) -> UInt16 {
        var r: UInt16 = 0
        var aa = UInt16(a)
        var bb = b
        while bb != 0 {
            if bb & 1 != 0 { r ^= aa }
            aa <<= 1
            bb >>= 1
        }
        return r
    }

    /// キャリーレス乗算（64 ビット → 128 ビット、(low, high) を返す）
    func carrylessMultiply64(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        var bb = b
        var shift = 0
        while bb != 0 {
            if bb & 1 != 0 {
                if shift == 0 { lo ^= a }
                else if shift < 64 {
                    lo ^= a << shift
                    hi ^= a >> (64 - shift)
                } else {
                    hi ^= a << (shift - 64)
                }
            }
            bb >>= 1
            shift += 1
        }
        return (lo, hi)
    }

    // MARK: 3 ソース（異なる幅: ロング / ワイド）

    // MARK: 要素指定（by-element）乗算グループ
    //
    // 配置（QEMU a64.decode の @qrrx_e / @rrx_e と同一）:
    //   ベクタ形: 0 Q U 01111 size L M Rm<3:0> opcode<3:0> H 0 Rn Rd
    //   スカラ形: bits 28–25 = 1111 で同配置（存在するのは SQD 系と FP 系のみ）。
    //   Rm は 4 ビット（v0–v15 のみ）で、bit20（M）と bit21（L）と bit11（H）が
    //   要素インデックスをなす: H 形 = (H<<2)|(L<<1)|M、S 形 = (H<<1)|L
    //   （インデックスは Vm 全体に対する絶対位置）。
    //   ロング形は Vn の下半分（Q=0）/ 上半分（Q=1）を読み、宛先は常に 128 ビット。
    //   FP 系（FMUL / FMLA / FMLS by element）と DOT 系は未実装として false を返す
    //   （誤実行するより未定義命令として落とす）。
    func executeSIMDByElement(_ insn: UInt32, rd: Int, rn: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let scalar = (insn & 0x1E00_0000) == 0x1E00_0000
        let size = Int((insn >> 22) & 0x3)
        let opc = Int((insn >> 12) & 0xF)
        // 整数形のソース要素は H（size=01）/ S（size=10）のみ
        guard size == 1 || size == 2 else { return false }
        let srcBytes = size == 1 ? 2 : 4
        let srcBits = srcBytes * 8
        let srcMask: UInt64 = (UInt64(1) << srcBits) - 1
        let hBit = insn & 0x0000_0800 != 0
        let lBit = insn & 0x0020_0000 != 0
        let mBit = insn & 0x0010_0000 != 0
        let index = size == 1 ? (hBit ? 4 : 0) + (lBit ? 2 : 0) + (mBit ? 1 : 0)
                              : (hBit ? 2 : 0) + (lBit ? 1 : 0)
        let rm = Int((insn >> 16) & 0xF)
        let n = vRegBytes(rn)
        let m = vRegBytes(rm)
        let d = vRegBytes(rd)
        var out = [UInt8](repeating: 0, count: 16)

        // SQDMULH / SQRDMULH: 2 倍した積の高位半分（要素幅で飽和）。
        // executeSIMDThreeSame の opc=0b10110 と同じ計算。
        func qdmulh(_ a: Int64, _ b: Int64, rounding: Bool) -> UInt64 {
            let prod = a.multipliedFullWidth(by: b)
            var hi = prod.high
            var lo = prod.low
            let newLo = lo << 1
            hi = (hi << 1) | Int64(lo >> 63)
            lo = newLo
            if rounding {
                let (sumLo, carry) = lo.addingReportingOverflow(UInt64(1) << (srcBits - 1))
                lo = sumLo
                if carry { hi &+= 1 }
            }
            let res = (hi << (64 - srcBits)) &+ Int64(bitPattern: lo >> UInt64(srcBits))
            return saturateSigned(res, bits: srcBits)
        }

        switch opc {
        case 0b1010, 0b0010, 0b0110:
            // MULL / MLAL / MLSL（ロング形、符号は U で選択。スカラ形は存在しない）
            guard !scalar else { return false }
            let dstBytes = srcBytes * 2
            let dstBits = srcBits * 2
            let dstMask: UInt64 = dstBits >= 64 ? UInt64.max : (UInt64(1) << dstBits) - 1
            let lanes = 64 / srcBits
            let halfOffset = q ? lanes : 0
            let elem: UInt64 = u ? laneGet(m, index, srcBytes)
                                 : UInt64(bitPattern: laneSigned(m, index, srcBytes)) & dstMask
            for i in 0..<lanes {
                let a: UInt64 = u ? laneGet(n, halfOffset + i, srcBytes)
                                  : UInt64(bitPattern: laneSigned(n, halfOffset + i, srcBytes)) & dstMask
                let prod = (a &* elem) & dstMask
                switch opc {
                case 0b1010:
                    laneSet(&out, i, dstBytes, prod)
                case 0b0010:
                    laneSet(&out, i, dstBytes, (laneGet(d, i, dstBytes) &+ prod) & dstMask)
                default:
                    laneSet(&out, i, dstBytes, (laneGet(d, i, dstBytes) &- prod) & dstMask)
                }
            }
            setVRegBytes(rd, out, q: true)
            return true
        case 0b1011, 0b0011, 0b0111:
            // SQDMULL / SQDMLAL / SQDMLSL（ロング形、符号付きのみ。
            // 積を 2 倍して宛先幅で飽和: executeSIMDThreeDifferent の qdmulSat と同じ）
            guard !u else { return false }
            let dstBytes = srcBytes * 2
            let dstBits = srcBits * 2
            let dstMask: UInt64 = dstBits >= 64 ? UInt64.max : (UInt64(1) << dstBits) - 1
            let lanes = scalar ? 1 : 64 / srcBits
            let halfOffset = scalar ? 0 : (q ? lanes : 0)
            let b = laneSigned(m, index, srcBytes)
            for i in 0..<lanes {
                let a = laneSigned(n, halfOffset + i, srcBytes)
                let p = a &* b
                let satSigned: Int64
                if p > Int64.max / 2 { satSigned = Int64.max }
                else if p < Int64.min / 2 { satSigned = Int64.min }
                else { satSigned = clampSigned(p * 2, bits: dstBits) }
                let sat = UInt64(bitPattern: satSigned) & dstMask
                switch opc {
                case 0b1011:
                    laneSet(&out, i, dstBytes, sat)
                case 0b0011:
                    // SQDMLAL（要素指定）: 累積も飽和（QEMU gen_sqdmlal_h/s）
                    laneSet(&out, i, dstBytes, saturatingAccumulate(acc: laneSigned(d, i, dstBytes), term: satSigned, subtract: false, bits: dstBits))
                default:
                    // SQDMLSL（要素指定）: 累積も飽和（QEMU gen_sqdmlsl_h/s）
                    laneSet(&out, i, dstBytes, saturatingAccumulate(acc: laneSigned(d, i, dstBytes), term: satSigned, subtract: true, bits: dstBits))
                }
            }
            setVRegBytes(rd, out, q: scalar ? false : true)
            return true
        case 0b1000, 0b0000, 0b0100:
            // MUL（U=0）/ MLA（U=1）/ MLS（U=1）（同幅。スカラ形は存在しない）
            guard !scalar else { return false }
            if opc == 0b1000 {
                guard !u else { return false }
            } else {
                guard u else { return false }
            }
            let lanes = (q ? 16 : 8) / srcBytes
            let elem = laneGet(m, index, srcBytes)
            for i in 0..<lanes {
                let prod = (laneGet(n, i, srcBytes) &* elem) & srcMask
                switch opc {
                case 0b1000:
                    laneSet(&out, i, srcBytes, prod)
                case 0b0000:
                    laneSet(&out, i, srcBytes, (laneGet(d, i, srcBytes) &+ prod) & srcMask)
                default:
                    laneSet(&out, i, srcBytes, (laneGet(d, i, srcBytes) &- prod) & srcMask)
                }
            }
            setVRegBytes(rd, out, q: q)
            return true
        case 0b1100, 0b1101, 0b1111:
            // SQDMULH（U=0）/ SQRDMULH（U=0）/ SQRDMLAH（U=1）/ SQRDMLSH（U=1）（同幅）
            if opc == 0b1100 { guard !u else { return false } }
            if opc == 0b1111 { guard u else { return false } }
            let lanes = scalar ? 1 : (q ? 16 : 8) / srcBytes
            let b = laneSigned(m, index, srcBytes)
            for i in 0..<lanes {
                let a = laneSigned(n, i, srcBytes)
                let h = qdmulh(a, b, rounding: opc != 0b1100)
                var v = h
                if opc == 0b1101 && u {
                    // SQRDMLAH: QEMU do_sqrdmlah と同じく、累算込みの広い精度で
                    // 1 回だけシフトし最後に 1 回だけ飽和する（q を途中で飽和させない。
                    // INT_MIN×INT_MIN では q=2^(n-1) が累算に効くため結果が変わる）
                    let acc = laneSigned(d, i, srcBytes)
                    let wide = (acc << (srcBits - 1)) + a * b + (Int64(1) << (srcBits - 2))
                    v = saturateSigned(wide >> (srcBits - 1), bits: srcBits)
                } else if opc == 0b1111 {
                    // SQRDMLSH: 同上（積を減算）
                    let acc = laneSigned(d, i, srcBytes)
                    let wide = (acc << (srcBits - 1)) - a * b + (Int64(1) << (srcBits - 2))
                    v = saturateSigned(wide >> (srcBits - 1), bits: srcBits)
                }
                laneSet(&out, i, srcBytes, v)
            }
            setVRegBytes(rd, out, q: scalar ? false : q)
            return true
        default:
            return false
        }
    }

    func executeSIMDThreeDifferent(_ insn: UInt32, rd: Int, rn: Int, rm: Int) -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let size = Int((insn >> 22) & 0x3)
        let opc = Int((insn >> 12) & 0xF)
        let srcBytes = 1 << size
        let srcBits = srcBytes * 8
        let dstBytes = srcBytes * 2
        let dstBits = srcBits * 2
        let srcLanes = 64 / srcBits
        let halfOffset = q ? srcLanes : 0
        let n = vRegBytes(rn)
        let m = vRegBytes(rm)
        let d = vRegBytes(rd)
        var out = [UInt8](repeating: 0, count: 16)
        let dstMask: UInt64 = dstBits >= 64 ? UInt64.max : (UInt64(1) << dstBits) - 1
        func extN(_ i: Int) -> UInt64 {
            if u { return laneGet(n, halfOffset + i, srcBytes) }
            return UInt64(bitPattern: laneSigned(n, halfOffset + i, srcBytes)) & dstMask
        }
        func extM(_ i: Int) -> UInt64 {
            if u { return laneGet(m, halfOffset + i, srcBytes) }
            return UInt64(bitPattern: laneSigned(m, halfOffset + i, srcBytes)) & dstMask
        }
        func absDiff(_ i: Int) -> UInt64 {
            if u {
                let a = laneGet(n, halfOffset + i, srcBytes)
                let b = laneGet(m, halfOffset + i, srcBytes)
                return a >= b ? a - b : b - a
            }
            let a = laneSigned(n, halfOffset + i, srcBytes)
            let b = laneSigned(m, halfOffset + i, srcBytes)
            let ua = UInt64(bitPattern: a), ub = UInt64(bitPattern: b)
            return a >= b ? ua &- ub : ub &- ua
        }
        func qdmulSat(_ i: Int) -> UInt64 {
            // SQDMULL 系: 符号付き積を 2 倍して宛先幅で飽和（srcBits <= 32 前提）
            let a = laneSigned(n, halfOffset + i, srcBytes)
            let b = laneSigned(m, halfOffset + i, srcBytes)
            let p = a &* b
            if p > Int64.max / 2 { return dstMask >> 1 }
            if p < Int64.min / 2 { return UInt64(1) << (dstBits - 1) }
            return saturateSigned(p * 2, bits: dstBits)
        }
        func qdmulTerm(_ i: Int) -> Int64 {
            // SQDMLAL / SQDMLSL の被累積項: 積の 2 倍を宛先幅で飽和した符号付き値
            let a = laneSigned(n, halfOffset + i, srcBytes)
            let b = laneSigned(m, halfOffset + i, srcBytes)
            let p = a &* b
            if p > Int64.max / 2 { return Int64.max }
            if p < Int64.min / 2 { return Int64.min }
            return clampSigned(p * 2, bits: dstBits)
        }
        switch opc {
        case 0:
            // SADDL / UADDL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (extN(i) &+ extM(i)) & dstMask) }
        case 1:
            // SADDW / UADDW（Rn がワイド側）
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (laneGet(n, i, dstBytes) &+ extM(i)) & dstMask) }
        case 2:
            // SSUBL / USUBL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (extN(i) &- extM(i)) & dstMask) }
        case 3:
            // SSUBW / USUBW（Rn がワイド側）
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (laneGet(n, i, dstBytes) &- extM(i)) & dstMask) }
        case 5:
            // SABAL / UABAL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (laneGet(d, i, dstBytes) &+ absDiff(i)) & dstMask) }
        case 7:
            // SABDL / UABDL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, absDiff(i) & dstMask) }
        case 8:
            // SMLAL / UMLAL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (laneGet(d, i, dstBytes) &+ (extN(i) &* extM(i))) & dstMask) }
        case 9 where !u:
            // SQDMLAL（累積も宛先幅で飽和: QEMU gen_sqdmlal_h/s）
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, saturatingAccumulate(acc: laneSigned(d, i, dstBytes), term: qdmulTerm(i), subtract: false, bits: dstBits)) }
        case 10:
            // SMLSL / UMLSL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (laneGet(d, i, dstBytes) &- (extN(i) &* extM(i))) & dstMask) }
        case 11 where !u:
            // SQDMLSL（累積も宛先幅で飽和: QEMU gen_sqdmlsl_h/s）
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, saturatingAccumulate(acc: laneSigned(d, i, dstBytes), term: qdmulTerm(i), subtract: true, bits: dstBits)) }
        case 12:
            // SMULL / UMULL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, (extN(i) &* extM(i)) & dstMask) }
        case 13 where !u:
            // SQDMULL
            for i in 0..<srcLanes { laneSet(&out, i, dstBytes, qdmulSat(i) & dstMask) }
        case 14 where !u:
            // PMULL / PMULL2（要素サイズは B または D のみ）
            guard size == 0 || size == 3 else { return false }
            if size == 3 {
                let (lo, hi) = carrylessMultiply64(laneGet(n, halfOffset, 8), laneGet(m, halfOffset, 8))
                laneSet(&out, 0, 8, lo)
                laneSet(&out, 1, 8, hi)
            } else {
                for i in 0..<srcLanes {
                    laneSet(&out, i, 2, UInt64(carrylessMultiply8(UInt8(truncatingIfNeeded: laneGet(n, halfOffset + i, 1)), UInt8(truncatingIfNeeded: laneGet(m, halfOffset + i, 1)))))
                }
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: true)
        return true
    }

    // MARK: 3 ソース（ベクタ / スカラ）

    func executeSIMDThreeSame(_ insn: UInt32, rd: Int, rn: Int, rm: Int, scalar: Bool) throws -> Bool {
        let q = insn & 0x4000_0000 != 0
        let u = insn & 0x2000_0000 != 0
        let size = Int((insn >> 22) & 0x3)
        let opc = Int((insn >> 11) & 0x1F)
        let n = vRegBytes(rn)
        let m = vRegBytes(rm)
        var out = [UInt8](repeating: 0, count: 16)

        // 論理演算（opc = 00011、演算は size で選択）
        if opc == 0b00011 {
            let total = q ? 16 : 8
            let d = vRegBytes(rd)
            for i in 0..<total {
                switch (u, size) {
                case (false, 0): out[i] = n[i] & m[i]        // AND
                case (false, 1): out[i] = n[i] & ~m[i]       // BIC
                case (false, 2): out[i] = n[i] | m[i]        // ORR / MOV
                case (false, 3): out[i] = n[i] | ~m[i]       // ORN
                case (true, 0): out[i] = n[i] ^ m[i]         // EOR
                case (true, 1): out[i] = (d[i] & n[i]) | (~d[i] & m[i])   // BSL: 選択子は宛先レジスタ自身（QEMU do_bitsel 準拠）
                case (true, 2): out[i] = (n[i] & m[i]) | (d[i] & ~m[i])   // BIT
                case (true, 3): out[i] = (m[i] & d[i]) | (~m[i] & n[i])   // BIF: マスク 1 で宛先を保持、0 で Rn を取る（BIT と逆）
                default: return false
                }
            }
            setVRegBytes(rd, out, q: q)
            return true
        }

        // ベクタ FP（opc >= 11001）
        if opc >= 0b11001 {
            let isDouble = insn & 0x0040_0000 != 0
            let elemBytes = isDouble ? 8 : 4
            let lanes = (q ? 16 : 8) / elemBytes
            let sub = insn & 0x0080_0000 != 0   // bit23
            let d = vRegBytes(rd)
            for i in 0..<lanes {
                let a = fpLane(n, i, isDouble: isDouble)
                let b = fpLane(m, i, isDouble: isDouble)
                switch opc {
                case 0b11010 where u:
                    // FABD
                    setFPLane(&out, i, abs(a - b), isDouble: isDouble)
                case 0b11010:
                    // FADD / FSUB
                    setFPLane(&out, i, sub ? a - b : a + b, isDouble: isDouble)
                case 0b11011 where !u:
                    // FMULX（0 × ∞ のとき符号付き 2.0）
                    if (a == 0 && b.isInfinite) || (b == 0 && a.isInfinite) {
                        let s: Double = (a.sign == .minus) != (b.sign == .minus) ? -2.0 : 2.0
                        setFPLane(&out, i, s, isDouble: isDouble)
                    } else {
                        setFPLane(&out, i, a * b, isDouble: isDouble)
                    }
                case 0b11011 where u:
                    // FMUL
                    setFPLane(&out, i, a * b, isDouble: isDouble)
                case 0b11111 where u:
                    // FDIV
                    setFPLane(&out, i, a / b, isDouble: isDouble)
                case 0b11001:
                    // FMLA (bit23=0) / FMLS (bit23=1)
                    let acc = fpLane(d, i, isDouble: isDouble)
                    setFPLane(&out, i, sub ? acc - a * b : acc + a * b, isDouble: isDouble)
                case 0b11100:
                    // FCMEQ (U=0) / FCMGE (U=1, bit23=0) / FCMGT (U=1, bit23=1)
                    let result: Bool
                    if !u { result = a == b }
                    else if sub { result = a > b }
                    else { result = a >= b }
                    laneSet(&out, i, elemBytes, result ? UInt64.max : 0)
                case 0b11110:
                    // FMAX (bit23=0) / FMIN (bit23=1)
                    setFPLane(&out, i, sub ? fpMin(a, b) : fpMax(a, b), isDouble: isDouble)
                default:
                    return false
                }
            }
            setVRegBytes(rd, out, q: q)
            return true
        }

        // 整数
        let elemBytes = 1 << size
        let elemBits = elemBytes * 8
        let elemMask: UInt64 = elemBits >= 64 ? UInt64.max : (UInt64(1) << elemBits) - 1
        let lanes = scalar ? 1 : (q ? 16 : 8) / elemBytes
        func pairOp(_ f: (UInt64, UInt64) -> UInt64) {
            // ペアワイズ: 結果の前半は Vn の隣接ペア、後半は Vm の隣接ペア
            let half = lanes / 2
            for i in 0..<half {
                laneSet(&out, i, elemBytes, f(laneGet(n, 2 * i, elemBytes), laneGet(n, 2 * i + 1, elemBytes)))
                laneSet(&out, half + i, elemBytes, f(laneGet(m, 2 * i, elemBytes), laneGet(m, 2 * i + 1, elemBytes)))
            }
        }
        switch (opc, u) {
        case (0b10000, false):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, (laneGet(n, i, elemBytes) &+ laneGet(m, i, elemBytes)) & elemMask) }
        case (0b10000, true):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, (laneGet(n, i, elemBytes) &- laneGet(m, i, elemBytes)) & elemMask) }
        case (0b10011, false):
            // MUL
            for i in 0..<lanes { laneSet(&out, i, elemBytes, (laneGet(n, i, elemBytes) &* laneGet(m, i, elemBytes)) & elemMask) }
        case (0b10010, false), (0b10010, true):
            // MLA / MLS（宛先がアキュムレータ）
            let d = vRegBytes(rd)
            for i in 0..<lanes {
                let product = laneGet(n, i, elemBytes) &* laneGet(m, i, elemBytes)
                let base = laneGet(d, i, elemBytes)
                laneSet(&out, i, elemBytes, (u ? base &- product : base &+ product) & elemMask)
            }
        case (0b10001, true):
            // CMEQ
            for i in 0..<lanes { laneSet(&out, i, elemBytes, laneGet(n, i, elemBytes) == laneGet(m, i, elemBytes) ? elemMask : 0) }
        case (0b00110, false):
            // CMGT（符号付き）
            for i in 0..<lanes { laneSet(&out, i, elemBytes, laneSigned(n, i, elemBytes) > laneSigned(m, i, elemBytes) ? elemMask : 0) }
        case (0b00110, true):
            // CMHI（符号なし）
            for i in 0..<lanes { laneSet(&out, i, elemBytes, laneGet(n, i, elemBytes) > laneGet(m, i, elemBytes) ? elemMask : 0) }
        case (0b00111, false):
            // CMGE（符号付き）
            for i in 0..<lanes { laneSet(&out, i, elemBytes, laneSigned(n, i, elemBytes) >= laneSigned(m, i, elemBytes) ? elemMask : 0) }
        case (0b00111, true):
            // CMHS（符号なし）
            for i in 0..<lanes { laneSet(&out, i, elemBytes, laneGet(n, i, elemBytes) >= laneGet(m, i, elemBytes) ? elemMask : 0) }
        case (0b00001, false):
            // SQADD
            for i in 0..<lanes {
                let r = laneSigned(n, i, elemBytes) &+ laneSigned(m, i, elemBytes)
                if elemBits == 64 {
                    let (sum, overflow) = laneSigned(n, i, elemBytes).addingReportingOverflow(laneSigned(m, i, elemBytes))
                    laneSet(&out, i, elemBytes, overflow ? (laneSigned(n, i, elemBytes) < 0 ? 0x8000_0000_0000_0000 : 0x7FFF_FFFF_FFFF_FFFF) : UInt64(bitPattern: sum))
                } else {
                    laneSet(&out, i, elemBytes, saturateSigned(r, bits: elemBits))
                }
            }
        case (0b00001, true):
            // UQADD
            for i in 0..<lanes {
                let (sum, overflow) = laneGet(n, i, elemBytes).addingReportingOverflow(laneGet(m, i, elemBytes))
                laneSet(&out, i, elemBytes, overflow ? elemMask : (sum & elemMask))
            }
        case (0b00101, false):
            // SQSUB
            for i in 0..<lanes {
                if elemBits == 64 {
                    let (diff, overflow) = laneSigned(n, i, elemBytes).subtractingReportingOverflow(laneSigned(m, i, elemBytes))
                    laneSet(&out, i, elemBytes, overflow ? (laneSigned(n, i, elemBytes) < 0 ? 0x8000_0000_0000_0000 : 0x7FFF_FFFF_FFFF_FFFF) : UInt64(bitPattern: diff))
                } else {
                    laneSet(&out, i, elemBytes, saturateSigned(laneSigned(n, i, elemBytes) &- laneSigned(m, i, elemBytes), bits: elemBits))
                }
            }
        case (0b00101, true):
            // UQSUB
            for i in 0..<lanes {
                let a = laneGet(n, i, elemBytes)
                let b = laneGet(m, i, elemBytes)
                laneSet(&out, i, elemBytes, a >= b ? a - b : 0)
            }
        case (0b01100, false):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, UInt64(bitPattern: max(laneSigned(n, i, elemBytes), laneSigned(m, i, elemBytes))) & elemMask) }
        case (0b01100, true):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, max(laneGet(n, i, elemBytes), laneGet(m, i, elemBytes))) }
        case (0b01101, false):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, UInt64(bitPattern: min(laneSigned(n, i, elemBytes), laneSigned(m, i, elemBytes))) & elemMask) }
        case (0b01101, true):
            for i in 0..<lanes { laneSet(&out, i, elemBytes, min(laneGet(n, i, elemBytes), laneGet(m, i, elemBytes))) }
        case (0b10111, false):
            // ADDP
            if scalar {
                laneSet(&out, 0, elemBytes, (laneGet(n, 0, elemBytes) &+ laneGet(n, 1, elemBytes)) & elemMask)
            } else {
                pairOp { ($0 &+ $1) & elemMask }
            }
        case (0b10100, false):
            pairOp { UInt64(bitPattern: max(Int64(bitPattern: signExtend($0, bits: elemBits)), Int64(bitPattern: signExtend($1, bits: elemBits)))) & elemMask }
        case (0b10100, true):
            pairOp { max($0, $1) }
        case (0b10101, false):
            pairOp { UInt64(bitPattern: min(Int64(bitPattern: signExtend($0, bits: elemBits)), Int64(bitPattern: signExtend($1, bits: elemBits)))) & elemMask }
        case (0b10101, true):
            pairOp { min($0, $1) }
        case (0b00000, false), (0b00000, true):
            // SHADD / UHADD: (n + m) >> 1
            for i in 0..<lanes {
                if elemBits == 64 {
                    if u {
                        let a = laneGet(n, i, 8), b = laneGet(m, i, 8)
                        laneSet(&out, i, 8, (a >> 1) &+ (b >> 1) &+ ((a & b) & 1))
                    } else {
                        let a = laneSigned(n, i, 8), b = laneSigned(m, i, 8)
                        let carry = Int64((UInt64(bitPattern: a) & UInt64(bitPattern: b)) & 1)
                        laneSet(&out, i, 8, UInt64(bitPattern: (a >> 1) &+ (b >> 1) &+ carry))
                    }
                } else if u {
                    laneSet(&out, i, elemBytes, ((laneGet(n, i, elemBytes) + laneGet(m, i, elemBytes)) >> 1) & elemMask)
                } else {
                    laneSet(&out, i, elemBytes, UInt64(bitPattern: (laneSigned(n, i, elemBytes) + laneSigned(m, i, elemBytes)) >> 1) & elemMask)
                }
            }
        case (0b00010, false), (0b00010, true):
            // SRHADD / URHADD: (n + m + 1) >> 1
            for i in 0..<lanes {
                if elemBits == 64 {
                    if u {
                        let a = laneGet(n, i, 8), b = laneGet(m, i, 8)
                        laneSet(&out, i, 8, (a >> 1) &+ (b >> 1) &+ (((a & 1) + (b & 1) + 1) >> 1))
                    } else {
                        let a = laneSigned(n, i, 8), b = laneSigned(m, i, 8)
                        let carry = Int64(((UInt64(bitPattern: a) & 1) + (UInt64(bitPattern: b) & 1) + 1) >> 1)
                        laneSet(&out, i, 8, UInt64(bitPattern: (a >> 1) &+ (b >> 1) &+ carry))
                    }
                } else if u {
                    laneSet(&out, i, elemBytes, ((laneGet(n, i, elemBytes) + laneGet(m, i, elemBytes) + 1) >> 1) & elemMask)
                } else {
                    laneSet(&out, i, elemBytes, UInt64(bitPattern: (laneSigned(n, i, elemBytes) + laneSigned(m, i, elemBytes) + 1) >> 1) & elemMask)
                }
            }
        case (0b00100, false), (0b00100, true):
            // SHSUB / UHSUB: (n - m) >> 1（中間値は符号付き）
            for i in 0..<lanes {
                if elemBits == 64 {
                    let aU = laneGet(n, i, 8), bU = laneGet(m, i, 8)
                    let borrow = (bU & 1) & (~aU & 1)
                    if u {
                        laneSet(&out, i, 8, (aU >> 1) &- (bU >> 1) &- borrow)
                    } else {
                        let a = laneSigned(n, i, 8), b = laneSigned(m, i, 8)
                        laneSet(&out, i, 8, UInt64(bitPattern: (a >> 1) &- (b >> 1) &- Int64(borrow)))
                    }
                } else {
                    let diff = Int64(laneGet(n, i, elemBytes)) - Int64(laneGet(m, i, elemBytes))
                    let sd = u ? diff : laneSigned(n, i, elemBytes) - laneSigned(m, i, elemBytes)
                    laneSet(&out, i, elemBytes, UInt64(bitPattern: sd >> 1) & elemMask)
                }
            }
        case (0b01000, false), (0b01000, true), (0b01001, false), (0b01001, true), (0b01010, false), (0b01010, true):
            // SSHL / USHL (opc=8)、SQSHL / UQSHL (9)、SRSHL / URSHL (10)
            let saturating = opc == 0b01001
            let rounding = opc == 0b01010
            for i in 0..<lanes {
                let shiftRaw = laneSigned(m, i, elemBytes)
                let aU = laneGet(n, i, elemBytes)
                let aS = laneSigned(n, i, elemBytes)
                var r: UInt64 = 0
                if shiftRaw >= 0 {
                    let s = Int(shiftRaw)
                    if saturating {
                        if u {
                            if s >= elemBits { r = aU == 0 ? 0 : elemMask }
                            else {
                                let v = aU << s
                                r = (v >> s) == aU ? v & elemMask : elemMask
                            }
                        } else if s >= elemBits {
                            r = aS == 0 ? 0 : (aS > 0 ? (elemMask >> 1) : (UInt64(1) << (elemBits - 1)))
                        } else if elemBits == 64 {
                            let v = aS &<< s
                            r = (v &>> s) == aS ? UInt64(bitPattern: v) : (aS > 0 ? 0x7FFF_FFFF_FFFF_FFFF : 0x8000_0000_0000_0000)
                        } else {
                            r = saturateSigned(aS << s, bits: elemBits)
                        }
                    } else {
                        r = s >= 64 ? 0 : (aU << s) & elemMask
                    }
                } else {
                    let s = shiftRaw == Int64.min ? 1000 : Int(-shiftRaw)
                    if rounding {
                        if s >= 65 { r = 0 }
                        else if u { r = ((aU >> s) &+ ((aU >> (s - 1)) & 1)) & elemMask }
                        else { r = UInt64(bitPattern: (aS >> s) &+ Int64((UInt64(bitPattern: aS) >> UInt64(s - 1)) & 1)) & elemMask }
                    } else if u {
                        r = s >= 64 ? 0 : (aU >> s) & elemMask
                    } else {
                        r = s >= 64 ? (aS < 0 ? elemMask : 0) : UInt64(bitPattern: aS >> s) & elemMask
                    }
                }
                laneSet(&out, i, elemBytes, r)
            }
        case (0b01110, false), (0b01110, true):
            // SABD / UABD
            for i in 0..<lanes {
                if u {
                    let a = laneGet(n, i, elemBytes), b = laneGet(m, i, elemBytes)
                    laneSet(&out, i, elemBytes, a >= b ? a - b : b - a)
                } else if elemBits == 64 {
                    let a = laneSigned(n, i, 8), b = laneSigned(m, i, 8)
                    laneSet(&out, i, 8, a >= b ? UInt64(bitPattern: a &- b) : UInt64(bitPattern: b &- a))
                } else {
                    let diff = laneSigned(n, i, elemBytes) - laneSigned(m, i, elemBytes)
                    laneSet(&out, i, elemBytes, UInt64(bitPattern: diff < 0 ? -diff : diff) & elemMask)
                }
            }
        case (0b10001, false):
            // CMTST
            for i in 0..<lanes { laneSet(&out, i, elemBytes, (laneGet(n, i, elemBytes) & laneGet(m, i, elemBytes)) != 0 ? elemMask : 0) }
        case (0b10011, true):
            // PMUL（バイト多項式乗算の下位 8 ビット）
            guard size == 0 else { return false }
            let total = scalar ? 8 : (q ? 16 : 8)
            for i in 0..<total { out[i] = UInt8(truncatingIfNeeded: carrylessMultiply8(n[i], m[i])) }
        case (0b10110, false), (0b10110, true):
            // SQDMULH (U=0) / SQRDMULH (U=1)、要素は H / S のみ
            guard elemBits == 16 || elemBits == 32 else { return false }
            for i in 0..<lanes {
                let a = laneSigned(n, i, elemBytes)
                let b = laneSigned(m, i, elemBytes)
                let prod = a.multipliedFullWidth(by: b)
                var hi = prod.high
                var lo = prod.low
                let newLo = lo << 1
                hi = (hi << 1) | Int64(lo >> 63)
                lo = newLo
                if u {
                    let (sumLo, carry) = lo.addingReportingOverflow(UInt64(1) << (elemBits - 1))
                    lo = sumLo
                    if carry { hi &+= 1 }
                }
                let res = (hi << (64 - elemBits)) &+ Int64(bitPattern: lo >> UInt64(elemBits))
                laneSet(&out, i, elemBytes, saturateSigned(res, bits: elemBits))
            }
        default:
            return false
        }
        setVRegBytes(rd, out, q: scalar ? false : q)
        return true
    }
}

// MARK: - bdif ディスク（メモリ / ファイルのどちらでも裏付けできる）

/// bdif に接続するディスク。ファイル裏付けではスパースファイルを使い、
/// 容量の大きな root ディスク（数十 GiB）でも RAM を消費しない。
final class BdifDisk {
    let size: Int
    private var memory: [UInt8]?
    private var handle: FileHandle?

    init(memory: [UInt8]) {
        self.memory = memory
        self.size = memory.count
    }

    /// ファイルを開く（なければ作る）。size に切り詰め/拡張する（スパース）。
    init?(fileAt path: String, size: Int) {
        self.size = size
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil) else { return nil }
        }
        guard let h = FileHandle(forUpdatingAtPath: path) else { return nil }
        h.truncateFile(atOffset: UInt64(size))
        handle = h
    }

    func read(offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset + count <= size else { return nil }
        if let memory {
            return [UInt8](memory[offset..<offset + count])
        }
        guard let handle else { return nil }
        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readData(ofLength: count)
        guard data.count == count else { return nil }
        return [UInt8](data)
    }

    @discardableResult
    func write(offset: Int, bytes: [UInt8]) -> Bool {
        guard offset >= 0, offset + bytes.count <= size else { return false }
        if memory != nil {
            memory!.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            return true
        }
        guard let handle else { return false }
        handle.seek(toFileOffset: UInt64(offset))
        handle.write(Data(bytes))
        return true
    }
}
