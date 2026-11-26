import Foundation

/// ARM GICv3（VMAPPLE プラットフォーム用）。
///
/// XNU の AppleARMGIC ドライバが要求する最小限のモデル:
/// - ディストリビュータ（GICD）: SPI 1024 本分の有効 / 保留 / グループ / 優先度 / ルーティング
/// - 再配布器（GICR）: 単一 CPU 分。SGI / PPI の有効 / 保留 / グループ / 優先度
/// - CPU インタフェース（ICC システムレジスタ）: IAR / EOIR / DIR / PMR / IGRPEN / SRE / SGI 生成
///
/// グループ 0 は FIQ、グループ 1 は IRQ として配送する（Apple プラットフォームの慣例）。
/// 優先度は数値が小さいほど高い。アクティブ化は IAR 読み取り時、優先度降下は EOIR、
/// 非アクティブ化は DIR（EOImode = 1 前提。0 の場合は EOIR でも非アクティブ化する）。
final class GICv3 {
    static let spuriousINTID: UInt64 = 1023

    // MARK: ディストリビュータ状態

    /// GICD_CTLR: bit0 EnableGrp0, bit1 EnableGrp1, bit4 ARE_NS, bit5 ARE_S, bit6 DS, bit7 EnableGrp1A
    var distCtlr: UInt32 = 0
    private var spiEnable = [Bool](repeating: false, count: 1024)
    private var spiPending = [Bool](repeating: false, count: 1024)
    private var spiActive = [Bool](repeating: false, count: 1024)
    private var spiGroup1 = [Bool](repeating: false, count: 1024)      // false = グループ 0
    private var spiGroupMod = [Bool](repeating: false, count: 1024)
    private var spiPriority = [UInt8](repeating: 0, count: 1024)
    private var spiLevel = [Bool](repeating: false, count: 1024)       // レベルライン（デバイス駆動）
    private var spiICFGR = [UInt8](repeating: 0, count: 1024)           // 2 ビット / INTID

    // MARK: 再配布器状態（CPU 0 のみ）

    var redistCtlr: UInt32 = 0
    var redistWaker: UInt32 = 0x6        // リセット時: ProcessorSleep(bit1) | ChildrenAsleep(bit2)（QEMU gicv3_internal.h 準拠）
    private var sgiPpiEnable = [Bool](repeating: false, count: 32)
    private var sgiPpiPending = [Bool](repeating: false, count: 32)
    private var sgiPpiActive = [Bool](repeating: false, count: 32)
    private var sgiPpiGroup1 = [Bool](repeating: false, count: 32)
    private var sgiPpiGroupMod = [Bool](repeating: false, count: 32)
    private var sgiPpiPriority = [UInt8](repeating: 0, count: 32)
    /// PPI のハードウェアライン（タイマなど、CPU が駆動する）
    var ppiLine = [Bool](repeating: false, count: 16)    // PPI 16...31 → index 0...15

    // MARK: CPU インタフェース状態

    var iccPMR: UInt32 = 0
    var iccBPR0: UInt32 = 0
    var iccBPR1: UInt32 = 0
    var iccCtlr: UInt32 = 0              // bit1 = EOImode
    var iccSRE: UInt32 = 0               // bit0 SRE, bit3 DIB, bit1 DFB...
    var iccIGRPEN0: UInt32 = 0
    var iccIGRPEN1: UInt32 = 0
    private var runningPriority: UInt32? = nil
    private var activeStack: [(intid: Int, group: Int)] = []

    // MARK: - 保留判定

    private func isPending(_ intid: Int) -> Bool {
        if intid < 32 {
            if sgiPpiPending[intid] { return true }
            if intid >= 16 { return ppiLine[intid - 16] && sgiPpiEnable[intid] }
            return false
        }
        return spiPending[intid] || spiLevel[intid]
    }

    private func isEnabled(_ intid: Int) -> Bool {
        intid < 32 ? sgiPpiEnable[intid] : spiEnable[intid]
    }

    private func isActive(_ intid: Int) -> Bool {
        intid < 32 ? sgiPpiActive[intid] : spiActive[intid]
    }

    private func groupOf(_ intid: Int) -> Int {
        // IGRPMOD との組み合わせで実効グループを決める（Secure 状態なしモデル:
        // IGROUPR = 1 かつ IGRPMOD = 0 → グループ 1、それ以外はグループ 0 として扱う）
        let g = intid < 32 ? sgiPpiGroup1[intid] : spiGroup1[intid]
        let m = intid < 32 ? sgiPpiGroupMod[intid] : spiGroupMod[intid]
        return (g && !m) ? 1 : 0
    }

    private func priorityOf(_ intid: Int) -> UInt8 {
        intid < 32 ? sgiPpiPriority[intid] : spiPriority[intid]
    }

    private func groupEnabled(_ group: Int) -> Bool {
        if group == 0 {
            return (distCtlr & 0x1) != 0 && iccIGRPEN0 != 0
        }
        return ((distCtlr & 0x2) != 0 || (distCtlr & 0x80) != 0) && iccIGRPEN1 != 0
    }

    /// 指定グループで配送可能な最高優先 INTID（なければ nil）。
    private func highestPending(group: Int) -> Int? {
        guard groupEnabled(group) else { return nil }
        var best: Int? = nil
        var bestPriority: UInt8 = 0xFF
        for intid in 0..<1024 {
            guard isEnabled(intid), !isActive(intid), isPending(intid) else { continue }
            guard groupOf(intid) == group else { continue }
            let priority = priorityOf(intid)
            // PMR: 優先度値が PMR 未満のものだけが信号される（PMR=0 は全マスクが実機仕様）
            guard UInt32(priority) < (iccPMR & 0xFF) else { continue }
            // ランニング優先度より高くなければ割り込めない
            if let running = runningPriority, UInt32(priority) >= running { continue }
            if best == nil || priority < bestPriority {
                best = intid
                bestPriority = priority
            }
        }
        return best
    }

    /// ICC_RPR_EL1 用: 現在のランニング優先度（なければ 0xFF）。
    var currentRunningPriority: UInt64 {
        runningPriority.map { UInt64($0) } ?? 0xFF
    }

    /// CPU 側（step ループ）が見る保留状態。
    func pendingGroup(_ group: Int) -> Bool {
        highestPending(group: group) != nil
    }

    /// ICC_IAR 読み取り: 応答してアクティブ化する。
    func acknowledge(group: Int) -> UInt64 {
        guard let intid = highestPending(group: group) else { return Self.spuriousINTID }
        if intid < 32 {
            sgiPpiActive[intid] = true
            if intid < 16 { sgiPpiPending[intid] = false }   // SGI の保留は応答で消える
        } else {
            spiActive[intid] = true
            spiPending[intid] = false
        }
        activeStack.append((intid, group))
        runningPriority = UInt32(priorityOf(intid))
        return UInt64(intid)
    }

    /// ICC_HPPIR 読み取り（副作用なし）。
    func highestPriorityPending(group: Int) -> UInt64 {
        guard let intid = highestPending(group: group) else { return Self.spuriousINTID }
        return UInt64(intid)
    }

    /// ICC_EOIR 書き込み: 優先度降下（EOImode = 0 なら非アクティブ化も行う）。
    func endOfInterrupt(group: Int, intid: Int) {
        guard let top = activeStack.last, top.intid == intid else {
            // スタック不一致でも該当 INTID の降下は試みる
            if let idx = activeStack.lastIndex(where: { $0.intid == intid }) {
                activeStack.remove(at: idx)
            }
            recomputeRunning()
            if iccCtlr & 0x2 == 0 { deactivate(intid: intid) }
            return
        }
        activeStack.removeLast()
        recomputeRunning()
        if iccCtlr & 0x2 == 0 { deactivate(intid: intid) }
    }

    /// ICC_DIR 書き込み: 非アクティブ化。
    func deactivate(intid: Int) {
        if intid < 32 {
            sgiPpiActive[intid] = false
        } else if intid < 1024 {
            spiActive[intid] = false
        }
        if let idx = activeStack.firstIndex(where: { $0.intid == intid }) {
            activeStack.remove(at: idx)
        }
        recomputeRunning()
    }

    private func recomputeRunning() {
        runningPriority = activeStack.map { UInt32(priorityOf($0.intid)) }.min()
    }

    /// ICC_SGI1R / SGI0R / ASGI1R 書き込み: 自分宛て SGI を保留にする（単一 CPU）。
    func generateSGI(register value: UInt64) {
        let intid = Int((value >> 24) & 0xF)
        // TargetList はビットマップ。Aff フィールドは自 CPU（すべて 0）に一致するものだけ配送する。
        let targetList = value & 0xFFFF
        let irm = (value >> 40) & 1
        if irm == 1 || (targetList & 1) != 0 {
            sgiPpiPending[intid] = true
        }
    }

    /// SPI のレベルラインをデバイスから駆動する。
    func setSPILevel(_ intid: Int, _ level: Bool) {
        guard intid >= 32 && intid < 1024 else { return }
        spiLevel[intid] = level
    }

    /// SPI をエッジ保留する（MSI ドアベル用。Henge hv_gicv3_pend 相当:
    /// ラッチを立て、IAR 読み取りでクリアされる）。
    func pendSPI(_ intid: Int) {
        guard intid >= 32 && intid < 1024 else { return }
        spiPending[intid] = true
    }

    // MARK: - ディストリビュータ MMIO

    func distRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x0000: return UInt64(distCtlr)
        case 0x0004: // GICD_TYPER: ITLinesNumber=31（1024 SPI）, CPUNumber=0, IDbits=15 [23:19]
            return 31 | (0 << 5) | (15 << 19)
        case 0x0008: return 0x0000_010B   // GICD_IIDR（実装者 = ARM 風の仮値）
        case 0x0010: return 0             // STATUSR
        case 0xFFE8: return 0x0200_143B   // PIDR2: GICv3
        case 0x0084...0x00FC:            // IGROUPR（SPI 分。0x0080 は SGI/PPI で再配布器側）
            return UInt64(readBitfield32(offset: offset - 0x0084, values: spiGroup1, base: 32))
        case 0x0104...0x017C:            // ISENABLER
            return UInt64(readBitfield32(offset: offset - 0x0104, values: spiEnable, base: 32))
        case 0x0184...0x01FC:            // ICENABLER（読みは現在の有効状態）
            return UInt64(readBitfield32(offset: offset - 0x0184, values: spiEnable, base: 32))
        case 0x0204...0x027C:            // ISPENDR
            return UInt64(spiPendingBits(offset: offset - 0x0204))
        case 0x0284...0x02FC:            // ICPENDR（読みは現在の保留状態）
            return UInt64(spiPendingBits(offset: offset - 0x0284))
        case 0x0304...0x037C:            // ISACTIVER
            return UInt64(readBitfield32(offset: offset - 0x0304, values: spiActive, base: 32))
        case 0x0384...0x03FC:            // ICACTIVER（読みは現在のアクティブ状態）
            return UInt64(readBitfield32(offset: offset - 0x0384, values: spiActive, base: 32))
        case 0x0400...0x07FC:            // IPRIORITYR（バイト単位、4 本分）
            var v: UInt32 = 0
            for i in 0..<4 {
                let intid = Int(offset - 0x0400) + i
                if intid < 1024 { v |= UInt32(spiPriority[intid]) << (8 * i) }
            }
            return UInt64(v)
        case 0x0D04...0x0D7C:            // IGRPMODR
            return UInt64(readBitfield32(offset: offset - 0x0D04, values: spiGroupMod, base: 32))
        case 0x6000...0x7FFC:            // IROUTER（64 ビット / SPI）
            return 0 // 単一 CPU（Affinity = 0）
        case 0x0C00...0x0CFC:            // ICFGR（2 ビット / INTID）
            var bits: UInt32 = 0
            let base = Int(offset - 0x0C00) * 4
            for i in 0..<16 where base + i < 1024 {
                bits |= UInt32(spiICFGR[base + i] & 3) << (2 * i)
            }
            return UInt64(bits)
        default:
            return 0
        }
    }

    /// SPI の保留ビット列（ISPENDR / ICPENDR の読み出し用）。
    private func spiPendingBits(offset: UInt64) -> UInt32 {
        var bits: UInt32 = 0
        let base = 32 + Int(offset) * 8
        for i in 0..<32 where base + i < 1024 {
            if isPending(base + i) { bits |= UInt32(1) << i }
        }
        return bits
    }

    private func readBitfield32(offset: UInt64, values: [Bool], base: Int) -> UInt32 {
        var bits: UInt32 = 0
        let start = base + Int(offset) * 8
        for i in 0..<32 where start + i < values.count {
            if values[start + i] { bits |= UInt32(1) << i }
        }
        return bits
    }

    private func writeBitfield32(offset: UInt64, value: UInt32, values: inout [Bool], base: Int, setOnly: Bool) {
        let start = base + Int(offset) * 8
        for i in 0..<32 where start + i < values.count {
            if (value >> i) & 1 == 1 {
                values[start + i] = true
            } else if !setOnly {
                values[start + i] = false
            }
        }
    }

    private func clearBitfield32(offset: UInt64, value: UInt32, values: inout [Bool], base: Int) {
        let start = base + Int(offset) * 8
        for i in 0..<32 where start + i < values.count {
            if (value >> i) & 1 == 1 { values[start + i] = false }
        }
    }

    func distWrite(offset: UInt64, value: UInt64, size: Int) {
        let v32 = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x0000: distCtlr = v32
        case 0x0084...0x00FC:
            writeBitfield32(offset: offset - 0x0084, value: v32, values: &spiGroup1, base: 32, setOnly: false)
        case 0x0104...0x017C:
            writeBitfield32(offset: offset - 0x0104, value: v32, values: &spiEnable, base: 32, setOnly: true)
        case 0x0184...0x01FC:
            clearBitfield32(offset: offset - 0x0184, value: v32, values: &spiEnable, base: 32)
        case 0x0204...0x027C:
            writeBitfield32(offset: offset - 0x0204, value: v32, values: &spiPending, base: 32, setOnly: true)
        case 0x0284...0x02FC:
            clearBitfield32(offset: offset - 0x0284, value: v32, values: &spiPending, base: 32)
        case 0x0304...0x037C:
            writeBitfield32(offset: offset - 0x0304, value: v32, values: &spiActive, base: 32, setOnly: true)
        case 0x0384...0x03FC:
            clearBitfield32(offset: offset - 0x0384, value: v32, values: &spiActive, base: 32)
        case 0x0400...0x07FC:
            for i in 0..<4 {
                let intid = Int(offset - 0x0400) + i
                if intid < 1024 { spiPriority[intid] = UInt8((value >> (8 * i)) & 0xFF) }
            }
        case 0x0D04...0x0D7C:
            writeBitfield32(offset: offset - 0x0D04, value: v32, values: &spiGroupMod, base: 32, setOnly: false)
        case 0x0C00...0x0CFC:
            let base = Int(offset - 0x0C00) * 4
            for i in 0..<16 where base + i < 1024 {
                spiICFGR[base + i] = UInt8((v32 >> (2 * i)) & 3)
            }
        default:
            // IROUTER など他は単一 CPU では無視
            break
        }
    }

    // MARK: - 再配布器 MMIO（RD_base 0x0000... / SGI_base 0x10000...）

    func redistRead(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x0000: return UInt64(redistCtlr)
        case 0x0004: return 0x0000_010B   // GICR_IIDR
        case 0x0008: // GICR_TYPER: Last=1（bit4）, Processor_Number=0, Affinity=0
            return (1 << 4)
        case 0x0010: return 0             // GICR_STATUSR
        case 0x0014: return UInt64(redistWaker)
        case 0xFFE8: return 0x0200_143B   // PIDR2: GICv3
        case 0x10000 + 0x0080:           // IGROUPR0
            return UInt64(readBitfield32(offset: 0, values: sgiPpiGroup1, base: 0))
        case 0x10000 + 0x0100:           // ISENABLER0
            return UInt64(readBitfield32(offset: 0, values: sgiPpiEnable, base: 0))
        case 0x10000 + 0x0180:           // ICENABLER0（読みは現在の有効状態）
            return UInt64(readBitfield32(offset: 0, values: sgiPpiEnable, base: 0))
        case 0x10000 + 0x0200:           // ISPENDR0
            var bits: UInt32 = 0
            for i in 0..<32 where isPending(i) { bits |= UInt32(1) << i }
            return UInt64(bits)
        case 0x10000 + 0x0280:           // ICPENDR0（読みは現在の保留状態）
            var bits: UInt32 = 0
            for i in 0..<32 where isPending(i) { bits |= UInt32(1) << i }
            return UInt64(bits)
        case 0x10000 + 0x0300:           // ISACTIVER0
            return UInt64(readBitfield32(offset: 0, values: sgiPpiActive, base: 0))
        case 0x10000 + 0x0380:           // ICACTIVER0（読みは現在のアクティブ状態）
            return UInt64(readBitfield32(offset: 0, values: sgiPpiActive, base: 0))
        case 0x10000 + 0x0D00:           // IGRPMODR0
            return UInt64(readBitfield32(offset: 0, values: sgiPpiGroupMod, base: 0))
        default:
            if offset >= 0x10000 + 0x0400 && offset < 0x10000 + 0x0800 {
                // IPRIORITYR（SGI/PPI 分、バイト単位）
                var v: UInt32 = 0
                for i in 0..<4 {
                    let intid = Int(offset - (0x10000 + 0x0400)) + i
                    if intid < 32 { v |= UInt32(sgiPpiPriority[intid]) << (8 * i) }
                }
                return UInt64(v)
            }
            if offset >= 0x10000 + 0x0C00 && offset < 0x10000 + 0x0E00 {
                return 0 // ICFGR0/1
            }
            return 0
        }
    }

    func redistWrite(offset: UInt64, value: UInt64, size: Int) {
        let v32 = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x0000: redistCtlr = v32
        case 0x0014:  // WAKER: 書けるのは ProcessorSleep(bit1) のみ。ChildrenAsleep(bit2) は即時に追従（QEMU 準拠）
            redistWaker = (v32 & 0x2) != 0 ? 0x6 : 0x0
        case 0x10000 + 0x0080:
            writeBitfield32(offset: 0, value: v32, values: &sgiPpiGroup1, base: 0, setOnly: false)
        case 0x10000 + 0x0100:
            writeBitfield32(offset: 0, value: v32, values: &sgiPpiEnable, base: 0, setOnly: true)
        case 0x10000 + 0x0180:
            clearBitfield32(offset: 0, value: v32, values: &sgiPpiEnable, base: 0)
        case 0x10000 + 0x0200:
            writeBitfield32(offset: 0, value: v32, values: &sgiPpiPending, base: 0, setOnly: true)
        case 0x10000 + 0x0280:
            clearBitfield32(offset: 0, value: v32, values: &sgiPpiPending, base: 0)
        case 0x10000 + 0x0300:
            writeBitfield32(offset: 0, value: v32, values: &sgiPpiActive, base: 0, setOnly: true)
        case 0x10000 + 0x0380:
            clearBitfield32(offset: 0, value: v32, values: &sgiPpiActive, base: 0)
        case 0x10000 + 0x0D00:
            writeBitfield32(offset: 0, value: v32, values: &sgiPpiGroupMod, base: 0, setOnly: false)
        default:
            if offset >= 0x10000 + 0x0400 && offset < 0x10000 + 0x0800 {
                for i in 0..<4 {
                    let intid = Int(offset - (0x10000 + 0x0400)) + i
                    if intid < 32 { sgiPpiPriority[intid] = UInt8((value >> (8 * i)) & 0xFF) }
                }
            }
        }
    }
}
