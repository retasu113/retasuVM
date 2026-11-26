import Foundation

/// ATA ディスクイメージ（BIOS の INT 13h と IDE コントローラで共有する）。
final class X86DiskImage {
    var data: [UInt8]

    init(data: [UInt8]) {
        self.data = data
    }

    var sectorCount: Int { data.count / 512 }
}

/// PC の周辺デバイス群をまとめる I/O バス。
///
/// 割り込みコントローラ（8259A ×2）、タイマ（8254）、RTC / CMOS、
/// キーボードコントローラ（8042）、PCI ホストブリッジ、IDE（ATA）
/// コントローラ、シリアル（16550 相当）、VGA レジスタなどを実装し、
/// CPU のポート I/O を各デバイスへ振り分ける。割り込み要求は PIC に
/// 集約され、CPU が命令境界で配送する。
final class X86DeviceBus {
    weak var cpu: X86CPU?

    let pic = X86PIC()
    let pit = X86PIT()
    let lapic = X86LAPIC()
    let ioapic = X86IOAPIC()
    /// MMIO 書き込み時の時刻（updateDevices で更新）。
    private var lastNow: UInt64 = 0
    let rtc = X86RTC()
    let keyboard = X86KeyboardController()
    let pci = X86PCIHost()
    let ide = X86IDEController()
    let hpet = X86HPET()
    let smc = X86SMC()
    let ahci = X86AHCIController()

    private var ppiPort61: UInt8 = 0
    private var port92: UInt8 = 0
    private var cmosIndex: UInt8 = 0

    // シリアル（COM1）レジスタ
    private var serialIER: UInt8 = 0
    private var serialLCR: UInt8 = 0
    private var serialDivisor: UInt16 = 1
    private var serialScratch: UInt8 = 0

    // VGA レジスタ（値の保持のみ。画面表示はテキストメモリ経由）
    private var vgaSequencer: [UInt8] = [UInt8](repeating: 0, count: 5)
    private var vgaSequencerIndex: UInt8 = 0
    private var vgaGraphics: [UInt8] = [UInt8](repeating: 0, count: 9)
    private var vgaGraphicsIndex: UInt8 = 0
    private var vgaCRTC: [UInt8] = [UInt8](repeating: 0, count: 25)
    private var vgaCRTCIndex: UInt8 = 0
    private var vgaAttribute: [UInt8] = [UInt8](repeating: 0, count: 21)
    private var vgaAttributeIndex = 0
    private var vgaAttributeFlipFlop = false
    private var vgaMiscOutput: UInt8 = 0x67
    // DAC パレット（256 色 × RGB、各 6 ビット）と読み書きインデックス
    private var vgaDACPalette = [UInt8](repeating: 0, count: 256 * 3)
    private var vgaDACWriteIndex = 0
    private var vgaDACWriteComponent = 0
    private var vgaDACReadIndex = 0
    private var vgaDACReadComponent = 0
    /// BIOS で最後に設定されたビデオモード。
    private(set) var biosVideoMode: UInt8 = 0x03
    /// チェーン 4 グラフィックス（モード 13h 相当のメモリ配置）かどうか。
    var vgaChain4Graphics: Bool {
        vgaSequencer[4] & 0x08 != 0 && vgaAttribute[0x10] & 0x01 != 0
    }
    var vgaPalette: [UInt8] { vgaDACPalette }

    /// BIOS モード設定: 標準レジスタ表を読み込み、モード 13h では
    /// 既定パレット（16 色 + カラーキューブ + グレースケール）も設定する。
    func loadVideoModeRegisters(_ mode: UInt8) {
        let selected = mode & 0x7F
        biosVideoMode = selected
        let tables: [UInt8: (misc: UInt8, seq: [UInt8], crtc: [UInt8], gfx: [UInt8], attr: [UInt8])] = [
            0x03: (0x67, [0x03, 0x00, 0x03, 0x00, 0x02],
                   [0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F, 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x0E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3, 0xFF],
                   [0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF],
                   [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x0C, 0x00, 0x0F, 0x08, 0x00]),
            0x12: (0xE3, [0x03, 0x01, 0x0F, 0x00, 0x06],
                   [0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x0E, 0x8F, 0x28, 0x40, 0x96, 0xB9, 0xA3, 0xFF],
                   [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x0F, 0xFF],
                   [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x01, 0x00, 0x0F, 0x00, 0x00]),
            0x13: (0x63, [0x03, 0x01, 0x0F, 0x00, 0x0E],
                   [0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x0E, 0x8F, 0x28, 0x40, 0x96, 0xB9, 0xA3, 0xFF],
                   [0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0F, 0xFF],
                   [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x41, 0x00, 0x0F, 0x00, 0x00]),
        ]
        guard let table = tables[selected] ?? tables[0x03] else { return }
        vgaMiscOutput = table.misc
        vgaSequencer = table.seq
        vgaCRTC = table.crtc
        vgaGraphics = table.gfx
        vgaAttribute = table.attr
        vgaAttributeFlipFlop = false
        if selected == 0x13 {
            let base16: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (0, 0, 42), (0, 42, 0), (0, 42, 42), (42, 0, 0), (42, 0, 42), (42, 21, 0), (42, 42, 42),
                (21, 21, 21), (21, 21, 63), (21, 63, 21), (21, 63, 63), (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63),
            ]
            for (index, rgb) in base16.enumerated() {
                vgaDACPalette[index * 3] = rgb.0
                vgaDACPalette[index * 3 + 1] = rgb.1
                vgaDACPalette[index * 3 + 2] = rgb.2
            }
            let levels: [UInt8] = [0, 23, 33, 43, 53, 63] // 8 ビット値 0/95/135/175/215/255 の 6 ビット換算
            var index = 16
            for red in levels { for green in levels { for blue in levels {
                vgaDACPalette[index * 3] = red
                vgaDACPalette[index * 3 + 1] = green
                vgaDACPalette[index * 3 + 2] = blue
                index += 1
            } } }
            for step in 0..<24 {
                let gray = UInt8(2 + step * 2) // 8 ビット値 8〜238（10 刻み）の 6 ビット換算近似
                vgaDACPalette[(232 + step) * 3] = gray
                vgaDACPalette[(232 + step) * 3 + 1] = gray
                vgaDACPalette[(232 + step) * 3 + 2] = gray
            }
        }
    }

    init() {
        ide.bus = self
        keyboard.bus = self
        hpet.bus = self
        ahci.bus = self
    }

    func reset() {
        pic.reset()
        pit.reset()
        lapic.reset()
        ioapic.reset()
        keyboard.reset()
        ide.reset()
        hpet.reset()
        smc.reset()
        ahci.reset()
        serialIER = 0
        serialLCR = 0
    }

    // MARK: - デバイス更新（CPU が命令ごとに呼ぶ）

    /// 時間で変化するデバイス（PIT・キーボード・シリアル）の IRQ を PIC と
    /// IOAPIC へ伝え、LAPIC タイマを進める。
    func updateDevices(now: UInt64) {
        lastNow = now
        if pit.update(now: now) {
            pic.pulse(line: 0)
            ioapic.pulsePin(2) // 実機では PIT は IOAPIC のピン 2 に接続される
        }
        pic.setLine(1, keyboard.hasData)
        ioapic.setPinLevel(1, keyboard.hasData)
        hpet.update(now: now)
        let serialAsserted = serialIER & 0x01 != 0 && (cpu?.hasInput ?? false)
        pic.setLine(4, serialAsserted)
        ioapic.setPinLevel(4, serialAsserted)
        lapic.update(now: now)
        ioapic.service(lapic: lapic)
    }

    /// IDE などエッジ型デバイスからの割り込み（PIC と IOAPIC の両方へ）。
    func pulseInterruptLine(_ irq: Int) {
        pic.pulse(line: irq)
        ioapic.pulsePin(irq)
    }

    // MARK: - MMIO（LAPIC / IOAPIC）

    /// MMIO 領域（LAPIC / IOAPIC / HPET / AHCI）かどうか。
    static func isMMIOAddress(_ physical: UInt64) -> Bool {
        (physical >= 0xFEE00000 && physical < 0xFEE01000)
            || (physical >= 0xFEC00000 && physical < 0xFEC01000)
            || (physical >= X86HPET.baseAddress && physical < X86HPET.baseAddress + 0x400)
            || (physical >= X86AHCIController.abarAddress && physical < X86AHCIController.abarAddress + 0x1000)
    }

    /// MMIO 読み取り。レジスタは 32 ビット単位で、バイトレーンを切り出す。
    func readMMIO(physical: UInt64, size: Int) -> UInt64 {
        if physical >= X86HPET.baseAddress && physical < X86HPET.baseAddress + 0x400 {
            return hpet.read(offset: Int(physical - X86HPET.baseAddress), size: size, now: lastNow)
        }
        if physical >= X86AHCIController.abarAddress && physical < X86AHCIController.abarAddress + 0x1000 {
            return ahci.read(offset: Int(physical - X86AHCIController.abarAddress), size: size)
        }
        let isLAPIC = physical >= 0xFEE00000
        let offset = Int(physical - (isLAPIC ? 0xFEE00000 : 0xFEC00000))
        let registerOffset = offset & ~3
        let lane = offset & 3
        let raw: UInt32
        if isLAPIC {
            raw = lapic.readRegister(registerOffset)
        } else if registerOffset == 0 {
            raw = ioapic.selectedRegister
        } else if registerOffset == 0x10 {
            raw = ioapic.readRegister()
        } else {
            raw = 0
        }
        let shifted = UInt64(raw) >> (lane * 8)
        if size >= 4 { return UInt64(raw) }
        return shifted & ((UInt64(1) << (size * 8)) - 1)
    }

    /// MMIO 書き込み。部分書き込みはレジスタ値へマージする。
    func writeMMIO(physical: UInt64, size: Int, _ value: UInt64) {
        if physical >= X86HPET.baseAddress && physical < X86HPET.baseAddress + 0x400 {
            hpet.write(offset: Int(physical - X86HPET.baseAddress), size: size, value, now: lastNow)
            return
        }
        if physical >= X86AHCIController.abarAddress && physical < X86AHCIController.abarAddress + 0x1000 {
            ahci.write(offset: Int(physical - X86AHCIController.abarAddress), size: size, value)
            return
        }
        let isLAPIC = physical >= 0xFEE00000
        let offset = Int(physical - (isLAPIC ? 0xFEE00000 : 0xFEC00000))
        let registerOffset = offset & ~3
        let lane = offset & 3
        func merged(_ current: UInt32) -> UInt32 {
            if size >= 4 { return UInt32(value & 0xFFFFFFFF) }
            let laneMask: UInt32 = UInt32((UInt64(1) << (size * 8)) - 1) << (lane * 8)
            return (current & ~laneMask) | (UInt32(value) << (lane * 8))
        }
        if isLAPIC {
            lapic.writeRegister(registerOffset, merged(lapic.readRegister(registerOffset)), now: lastNow)
        } else if registerOffset == 0 {
            ioapic.selectedRegister = merged(ioapic.selectedRegister)
        } else if registerOffset == 0x10 {
            ioapic.writeRegister(merged(ioapic.readRegister()))
        }
    }

    // MARK: - ポート読み取り

    func readPort(_ port: UInt16, size: Int) -> UInt32 {
        // IDE データポートと PCI はサイズを持つ読み取りを直接処理する
        if port == 0x1F0 {
            return ide.readData(size: size)
        }
        if port >= 0xCF8 && port <= 0xCFF {
            return pci.readPort(port, size: size)
        }
        var value: UInt32 = 0
        for i in 0..<size {
            value |= UInt32(readByte(port &+ UInt16(i))) << (8 * i)
        }
        return value
    }

    private func readByte(_ port: UInt16) -> UInt8 {
        switch port {
        case 0x20, 0x21, 0xA0, 0xA1:
            return pic.read(port: port)
        case 0x40, 0x41, 0x42, 0x43:
            return pit.read(port: port, now: cpu?.nowNanos ?? 0)
        case 0x60:
            return keyboard.readData()
        case 0x64:
            return keyboard.readStatus()
        case 0x70:
            return cmosIndex
        case 0x71:
            return rtc.read(index: cmosIndex)
        case 0x61:
            return ppiPort61 | (pit.channel2Output(now: cpu?.nowNanos ?? 0) ? 0x20 : 0)
        case 0x92:
            return port92
        case 0x3F8:
            if serialLCR & 0x80 != 0 { return UInt8(serialDivisor & 0xFF) }
            return cpu?.nextInputByte() ?? 0
        case 0x3F9:
            if serialLCR & 0x80 != 0 { return UInt8(serialDivisor >> 8) }
            return serialIER
        case 0x3FA: // IIR
            return (serialIER & 0x01 != 0 && (cpu?.hasInput ?? false)) ? 0x04 : 0x01
        case 0x3FB:
            return serialLCR
        case 0x3FC, 0x3FD:
            if port == 0x3FC { return 0 }
            return 0x60 | ((cpu?.hasInput ?? false) ? 0x01 : 0) // LSR: 送信空き + 受信データ
        case 0x3FE:
            return 0
        case 0x3FF:
            return serialScratch
        case 0x2F8, 0x2FD: // COM2（スタブ）
            return port == 0x2FD ? 0x60 : 0
        case 0x1F1, 0x1F2, 0x1F3, 0x1F4, 0x1F5, 0x1F6, 0x1F7:
            return ide.readRegister(port)
        case 0xC000...0xC00F: // バスマスタ IDE（BAR4 = 0xC000 固定）
            return UInt8(ide.readBusMaster(offset: Int(port - 0xC000), size: 1) & 0xFF)
        case 0x3F6:
            return ide.readStatus()
        case 0x170, 0x177: // セカンダリ IDE（デバイスなし）
            return 0
        case 0x3C1:
            return vgaAttribute[vgaAttributeIndex % vgaAttribute.count]
        case 0x3C4:
            return vgaSequencerIndex
        case 0x3C5:
            return vgaSequencer[Int(vgaSequencerIndex) % vgaSequencer.count]
        case 0x3C7:
            return UInt8(vgaDACReadIndex)
        case 0x3C8:
            return UInt8(vgaDACWriteIndex)
        case 0x3C9: // DAC データ（読み出し）
            let value = vgaDACPalette[vgaDACReadIndex * 3 + vgaDACReadComponent]
            vgaDACReadComponent += 1
            if vgaDACReadComponent == 3 {
                vgaDACReadComponent = 0
                vgaDACReadIndex = (vgaDACReadIndex + 1) & 0xFF
            }
            return value
        case 0x3CC:
            return vgaMiscOutput
        case 0x3CE:
            return vgaGraphicsIndex
        case 0x3CF:
            return vgaGraphics[Int(vgaGraphicsIndex) % vgaGraphics.count]
        case 0x3D4:
            return vgaCRTCIndex
        case 0x3D5:
            return vgaCRTC[Int(vgaCRTCIndex) % vgaCRTC.count]
        case 0x3DA: // 入力ステータス 1（帰線期間ビットを時間で切り替えてポーリングを抜けさせる）
            let phase = ((cpu?.nowNanos ?? 0) / 11_000_000) & 1
            return phase == 0 ? 0x01 : 0x08
        case 0x300: // SMC データポート
            return smc.readData()
        case 0x304: // SMC コマンド / ステータスポート
            return smc.readStatus()
        case 0x00...0x1F, 0xC0...0xDF: // DMA コントローラ（スタブ）
            return 0xFF
        default:
            return 0xFF
        }
    }

    // MARK: - ポート書き込み

    func writePort(_ port: UInt16, value: UInt32, size: Int) {
        if port == 0x1F0 {
            ide.writeData(value, size: size)
            return
        }
        if port >= 0xCF8 && port <= 0xCFF {
            pci.writePort(port, value: value, size: size)
            return
        }
        for i in 0..<size {
            writeByte(port &+ UInt16(i), UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private func writeByte(_ port: UInt16, _ value: UInt8) {
        switch port {
        case 0x20, 0x21, 0xA0, 0xA1:
            pic.write(port: port, value: value)
        case 0x40, 0x41, 0x42, 0x43:
            pit.write(port: port, value: value, now: cpu?.nowNanos ?? 0)
        case 0x60:
            keyboard.writeData(value)
        case 0x64:
            keyboard.writeCommand(value)
        case 0x70:
            cmosIndex = value & 0x7F
        case 0x71:
            rtc.write(index: cmosIndex, value: value)
        case 0x61:
            ppiPort61 = value
        case 0x92:
            port92 = value
        case 0x3F8:
            if serialLCR & 0x80 != 0 {
                serialDivisor = (serialDivisor & 0xFF00) | UInt16(value)
            } else {
                cpu?.onChar?(value)
            }
        case 0x3F9:
            if serialLCR & 0x80 != 0 {
                serialDivisor = (serialDivisor & 0x00FF) | (UInt16(value) << 8)
            } else {
                serialIER = value
            }
        case 0x3FB:
            serialLCR = value
        case 0x3FF:
            serialScratch = value
        case 0xE9: // デバッグコンソール（Bochs / QEMU の debugcon 互換）
            cpu?.onChar?(value)
        case 0x300: // SMC データポート
            smc.writeData(value)
        case 0x304: // SMC コマンドポート
            smc.writeCommand(value)
        case 0x1F1, 0x1F2, 0x1F3, 0x1F4, 0x1F5, 0x1F6, 0x1F7:
            ide.writeRegister(port, value)
        case 0xC000...0xC00F: // バスマスタ IDE（BAR4 = 0xC000 固定）
            ide.writeBusMaster(offset: Int(port - 0xC000), value: UInt32(value), size: 1)
        case 0x3F6:
            ide.writeControl(value)
        case 0x3C0:
            if !vgaAttributeFlipFlop {
                vgaAttributeIndex = Int(value & 0x1F)
            } else {
                vgaAttribute[vgaAttributeIndex % vgaAttribute.count] = value
            }
            vgaAttributeFlipFlop.toggle()
        case 0x3C2:
            vgaMiscOutput = value
        case 0x3C7: // DAC 読み出しインデックス設定
            vgaDACReadIndex = Int(value)
            vgaDACReadComponent = 0
        case 0x3C8: // DAC 書き込みインデックス設定
            vgaDACWriteIndex = Int(value)
            vgaDACWriteComponent = 0
        case 0x3C9: // DAC データ書き込み
            vgaDACPalette[vgaDACWriteIndex * 3 + vgaDACWriteComponent] = value & 0x3F
            vgaDACWriteComponent += 1
            if vgaDACWriteComponent == 3 {
                vgaDACWriteComponent = 0
                vgaDACWriteIndex = (vgaDACWriteIndex + 1) & 0xFF
            }
        case 0x3C4:
            vgaSequencerIndex = value
        case 0x3C5:
            vgaSequencer[Int(vgaSequencerIndex) % vgaSequencer.count] = value
        case 0x3CE:
            vgaGraphicsIndex = value
        case 0x3CF:
            vgaGraphics[Int(vgaGraphicsIndex) % vgaGraphics.count] = value
        case 0x3D4:
            vgaCRTCIndex = value
        case 0x3D5:
            vgaCRTC[Int(vgaCRTCIndex) % vgaCRTC.count] = value
        default:
            break
        }
    }
}

// MARK: - 8259A PIC（マスタ + スレーブ）

/// 割り込みコントローラ。IRQ ラインの要求を集約し、優先順位に従って
/// CPU へ配送するベクタを決める。スレーブはマスタの IRQ2 にカスケード
/// 接続され、配送順は 0, 1, 8〜15, 3〜7。
final class X86PIC {
    private var irr: UInt16 = 0
    private var isr: UInt16 = 0
    private var imr: UInt16 = 0xFFFF
    private var baseMaster: UInt8 = 0x08
    private var baseSlave: UInt8 = 0x70
    private var initStepMaster = 0 // 0=通常, 1=ICW2待ち, 2=ICW3待ち, 3=ICW4待ち
    private var initStepSlave = 0
    private var needICW4Master = false
    private var needICW4Slave = false
    private var singleMaster = false
    private var singleSlave = false
    private var readISRMaster = false
    private var readISRSlave = false

    /// 配送優先順（先頭ほど高優先）。
    private static let priorityOrder = [0, 1, 8, 9, 10, 11, 12, 13, 14, 15, 3, 4, 5, 6, 7]

    func reset() {
        irr = 0
        isr = 0
        imr = 0xFFFF
        baseMaster = 0x08
        baseSlave = 0x70
        initStepMaster = 0
        initStepSlave = 0
    }

    /// レベル型デバイス用: ライン状態をそのまま IRR に反映する。
    func setLine(_ irq: Int, _ asserted: Bool) {
        guard irq >= 0, irq < 16, irq != 2 else { return }
        if asserted {
            irr |= UInt16(1) << irq
        } else {
            irr &= ~(UInt16(1) << irq)
        }
    }

    /// エッジ型デバイス用: 1 回だけ IRR を立てる。
    func pulse(line irq: Int) {
        guard irq >= 0, irq < 16, irq != 2 else { return }
        irr |= UInt16(1) << irq
    }

    private func effectiveMask(for irq: Int) -> Bool {
        if imr & (UInt16(1) << irq) != 0 { return true }
        if irq >= 8 && imr & (UInt16(1) << 2) != 0 { return true } // カスケードがマスクされていれば届かない
        return false
    }

    /// 配送可能な割り込みがあれば（IRQ 番号, ベクタ）を返す。
    func pendingInterrupt() -> (irq: Int, vector: UInt8)? {
        // 処理中の最優先 IRQ より高いものだけ配送する（完全ネスト）
        var inServiceLimit = Self.priorityOrder.count
        for (index, irq) in Self.priorityOrder.enumerated() where isr & (UInt16(1) << irq) != 0 {
            inServiceLimit = index
            break
        }
        for (index, irq) in Self.priorityOrder.enumerated() {
            if index >= inServiceLimit { break }
            if irr & (UInt16(1) << irq) != 0 && !effectiveMask(for: irq) {
                let vector = irq < 8 ? baseMaster + UInt8(irq) : baseSlave + UInt8(irq - 8)
                return (irq, vector)
            }
        }
        return nil
    }

    /// CPU が割り込みを受け付けたときに呼ぶ（IRR → ISR へ移す）。
    func acknowledge(irq: Int) {
        irr &= ~(UInt16(1) << irq)
        isr |= UInt16(1) << irq
        if irq >= 8 {
            isr |= UInt16(1) << 2
        }
    }

    func read(port: UInt16) -> UInt8 {
        switch port {
        case 0x20: return readISRMaster ? UInt8(isr & 0xFF) : UInt8(irr & 0xFF)
        case 0x21: return UInt8(imr & 0xFF)
        case 0xA0: return readISRSlave ? UInt8((isr >> 8) & 0xFF) : UInt8((irr >> 8) & 0xFF)
        case 0xA1: return UInt8((imr >> 8) & 0xFF)
        default: return 0xFF
        }
    }

    func write(port: UInt16, value: UInt8) {
        let isMaster = port == 0x20 || port == 0x21
        switch port {
        case 0x20, 0xA0: // コマンドポート
            if value & 0x10 != 0 {
                // ICW1: 初期化開始
                if isMaster {
                    initStepMaster = 1
                    needICW4Master = value & 0x01 != 0
                    singleMaster = value & 0x02 != 0
                    imr &= 0xFF00
                } else {
                    initStepSlave = 1
                    needICW4Slave = value & 0x01 != 0
                    singleSlave = value & 0x02 != 0
                    imr &= 0x00FF
                }
            } else if value & 0x08 != 0 {
                // OCW3: 読み出し対象の選択
                if value & 0x03 == 0x03 {
                    if isMaster { readISRMaster = true } else { readISRSlave = true }
                } else if value & 0x03 == 0x02 {
                    if isMaster { readISRMaster = false } else { readISRSlave = false }
                }
            } else {
                // OCW2: EOI
                if value & 0x20 != 0 {
                    endOfInterrupt(master: isMaster, specific: value & 0x40 != 0, level: Int(value & 0x07))
                }
            }
        case 0x21, 0xA1: // データポート
            if isMaster {
                switch initStepMaster {
                case 1:
                    baseMaster = value & 0xF8
                    initStepMaster = singleMaster ? (needICW4Master ? 3 : 0) : 2
                case 2:
                    initStepMaster = needICW4Master ? 3 : 0
                case 3:
                    initStepMaster = 0
                default:
                    imr = (imr & 0xFF00) | UInt16(value)
                }
            } else {
                switch initStepSlave {
                case 1:
                    baseSlave = value & 0xF8
                    initStepSlave = singleSlave ? (needICW4Slave ? 3 : 0) : 2
                case 2:
                    initStepSlave = needICW4Slave ? 3 : 0
                case 3:
                    initStepSlave = 0
                default:
                    imr = (imr & 0x00FF) | (UInt16(value) << 8)
                }
            }
        default:
            break
        }
    }

    private func endOfInterrupt(master: Bool, specific: Bool, level: Int) {
        if master {
            if specific {
                isr &= ~(UInt16(1) << level)
            } else {
                // 最優先の処理中ビットを落とす
                for irq in Self.priorityOrder where irq < 8 {
                    if isr & (UInt16(1) << irq) != 0 {
                        isr &= ~(UInt16(1) << irq)
                        break
                    }
                }
            }
        } else {
            if specific {
                isr &= ~(UInt16(1) << (8 + level))
            } else {
                for irq in Self.priorityOrder where irq >= 8 {
                    if isr & (UInt16(1) << irq) != 0 {
                        isr &= ~(UInt16(1) << irq)
                        break
                    }
                }
            }
            if isr & 0xFF00 == 0 {
                isr &= ~(UInt16(1) << 2)
            }
        }
    }
}

// MARK: - 8254 PIT

/// プログラマブルタイマ。入力クロック 1.193182 MHz。チャンネル 0 が
/// IRQ0 を周期的に発生させる。時刻は CPU の時計（`nowNanos`）で進む。
final class X86PIT {
    private struct Channel {
        var divisor = 65536
        var mode = 0
        var accessMode = 3
        var startNanos: UInt64 = 0
        var startCount = 65536
        var firedPeriods: UInt64 = 0
        var firedOnce = false
        var latchedValue: Int?
        var readHighNext = false
        var writeHighNext = false
        var pendingLow: UInt8 = 0
        var active = false
    }

    private var channels = [Channel(), Channel(), Channel()]
    private static let clockHz: UInt64 = 1_193_182

    func reset() {
        channels = [Channel(), Channel(), Channel()]
    }

    private func elapsedCycles(_ channel: Channel, now: UInt64) -> UInt64 {
        guard now >= channel.startNanos else { return 0 }
        return (now - channel.startNanos) * Self.clockHz / 1_000_000_000
    }

    /// チャンネル 0 の割り込みが発生したら true（1 回の呼び出しで最大 1 回）。
    func update(now: UInt64) -> Bool {
        let channel = channels[0]
        guard channel.active else { return false }
        let elapsed = elapsedCycles(channel, now: now)
        switch channel.mode {
        case 0: // 端数カウントで 1 回だけ
            if !channel.firedOnce && elapsed >= UInt64(channel.startCount) {
                channels[0].firedOnce = true
                return true
            }
        case 2, 3: // 周期モード
            let periods = elapsed / UInt64(max(1, channel.divisor))
            if periods > channel.firedPeriods {
                channels[0].firedPeriods = periods
                return true
            }
        default:
            break
        }
        return false
    }

    func channel2Output(now: UInt64) -> Bool {
        let channel = channels[2]
        guard channel.active else { return false }
        let elapsed = elapsedCycles(channel, now: now)
        return elapsed % UInt64(max(1, channel.divisor)) < UInt64(max(1, channel.divisor)) / 2
    }

    private func currentCount(_ index: Int, now: UInt64) -> Int {
        let channel = channels[index]
        if let latched = channel.latchedValue { return latched }
        guard channel.active else { return channel.divisor & 0xFFFF }
        let elapsed = elapsedCycles(channel, now: now)
        switch channel.mode {
        case 0:
            let remaining = Int64(channel.startCount) - Int64(elapsed)
            return Int(max(0, remaining)) & 0xFFFF
        default:
            let divisor = max(1, channel.divisor)
            let remainder = Int(elapsed % UInt64(divisor))
            let value = remainder == 0 ? divisor : divisor - remainder
            return value & 0xFFFF
        }
    }

    func read(port: UInt16, now: UInt64) -> UInt8 {
        guard port != 0x43 else { return 0xFF }
        let index = Int(port - 0x40)
        let value = currentCount(index, now: now)
        switch channels[index].accessMode {
        case 1:
            channels[index].latchedValue = nil
            return UInt8(value & 0xFF)
        case 2:
            channels[index].latchedValue = nil
            return UInt8((value >> 8) & 0xFF)
        default:
            if channels[index].readHighNext {
                channels[index].readHighNext = false
                channels[index].latchedValue = nil
                return UInt8((value >> 8) & 0xFF)
            }
            channels[index].readHighNext = true
            return UInt8(value & 0xFF)
        }
    }

    func write(port: UInt16, value: UInt8, now: UInt64) {
        if port == 0x43 {
            let index = Int((value >> 6) & 0x03)
            guard index < 3 else { return }
            let access = Int((value >> 4) & 0x03)
            if access == 0 {
                // カウントラッチコマンド
                channels[index].latchedValue = currentCount(index, now: now)
                channels[index].readHighNext = false
                return
            }
            channels[index].accessMode = access
            let rawMode = Int((value >> 1) & 0x07)
            channels[index].mode = rawMode == 6 ? 2 : rawMode == 7 ? 3 : rawMode // モード 6 / 7 は 2 / 3 の別名
            channels[index].writeHighNext = false
            return
        }
        let index = Int(port - 0x40)
        switch channels[index].accessMode {
        case 1:
            startChannel(index, divisor: Int(value), now: now)
        case 2:
            startChannel(index, divisor: Int(value) << 8, now: now)
        default:
            if channels[index].writeHighNext {
                channels[index].writeHighNext = false
                startChannel(index, divisor: (Int(value) << 8) | Int(channels[index].pendingLow), now: now)
            } else {
                channels[index].pendingLow = value
                channels[index].writeHighNext = true
            }
        }
    }

    private func startChannel(_ index: Int, divisor: Int, now: UInt64) {
        let effective = divisor == 0 ? 65536 : divisor
        channels[index].divisor = effective
        channels[index].startCount = effective
        channels[index].startNanos = now
        channels[index].firedPeriods = 0
        channels[index].firedOnce = false
        channels[index].active = true
        channels[index].latchedValue = nil
        channels[index].readHighNext = false
    }
}

// MARK: - RTC / CMOS

/// リアルタイムクロック。ホストの現在時刻を BCD（既定）で返す。
final class X86RTC {
    private var storage: [UInt8] = [UInt8](repeating: 0, count: 128)
    private var registerB: UInt8 = 0x02 // 24 時間制、BCD

    func read(index: UInt8) -> UInt8 {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second, .day, .month, .year, .weekday], from: now)
        func format(_ value: Int) -> UInt8 {
            if registerB & 0x04 != 0 { return UInt8(value) } // バイナリ形式
            return UInt8(((value / 10) << 4) | (value % 10))
        }
        switch index {
        case 0x00: return format(components.second ?? 0)
        case 0x02: return format(components.minute ?? 0)
        case 0x04:
            var hour = components.hour ?? 0
            if registerB & 0x02 == 0 {
                // 12 時間制（午後は 0x80 を立てる）
                let pm = hour >= 12
                hour = hour % 12 == 0 ? 12 : hour % 12
                return format(hour) | (pm ? 0x80 : 0)
            }
            return format(hour)
        case 0x06: return format(components.weekday ?? 1)
        case 0x07: return format(components.day ?? 1)
        case 0x08: return format(components.month ?? 1)
        case 0x09: return format((components.year ?? 2026) % 100)
        case 0x32: return format((components.year ?? 2026) / 100)
        case 0x0A: return storage[0x0A] & 0x7F // UIP は常に 0
        case 0x0B: return registerB
        case 0x0C: return 0 // 割り込みフラグなし（読み取りでクリアされる前提の値）
        case 0x0D: return 0x80
        default: return storage[Int(index) & 0x7F]
        }
    }

    func write(index: UInt8, value: UInt8) {
        if index == 0x0B {
            registerB = value
        }
        storage[Int(index) & 0x7F] = value
    }
}

// MARK: - 8042 キーボードコントローラ

/// PS/2 キーボードコントローラ。コンソール入力をスキャンコード
/// （セット 1）へ変換して保持し、データがあれば IRQ1 を要求する。
final class X86KeyboardController {
    weak var bus: X86DeviceBus?

    private var queue: [UInt8] = []
    private var commandByte: UInt8 = 0x47
    private var keyboardEnabled = true
    private var expectingCommandByte = false
    private var expectingOutputPort = false
    private var expectingLEDData = false
    private var lastWriteWasCommand = false

    var hasData: Bool { !queue.isEmpty }

    func reset() {
        queue = []
        keyboardEnabled = true
        expectingCommandByte = false
        expectingOutputPort = false
        expectingLEDData = false
    }

    /// コンソールからのテキスト入力をスキャンコード化して受け取る。
    func receiveText(_ bytes: [UInt8]) {
        for byte in bytes {
            enqueueScancodes(for: byte)
        }
    }

    private func enqueueScancodes(for byte: UInt8) {
        guard let (code, needsShift) = Self.makeCode(for: byte) else { return }
        if needsShift { queue.append(0x2A) } // 左 Shift 押下
        queue.append(code)
        queue.append(code | 0x80)
        if needsShift { queue.append(0xAA) } // 左 Shift 開放
    }

    func readData() -> UInt8 {
        guard !queue.isEmpty else { return 0 }
        return queue.removeFirst()
    }

    func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if !queue.isEmpty { status |= 0x01 } // 出力バッファフル
        if lastWriteWasCommand { status |= 0x08 }
        if keyboardEnabled { status |= 0x10 }
        return status
    }

    func writeData(_ value: UInt8) {
        lastWriteWasCommand = false
        if expectingCommandByte {
            commandByte = value
            expectingCommandByte = false
            return
        }
        if expectingOutputPort {
            expectingOutputPort = false // A20 などは受け取るだけ（常時有効）
            return
        }
        if expectingLEDData {
            expectingLEDData = false
            queue.append(0xFA) // ACK
            return
        }
        switch value {
        case 0xED: // LED 設定（次バイトがデータ）
            expectingLEDData = true
            queue.append(0xFA)
        case 0xF4: // スキャン有効
            keyboardEnabled = true
            queue.append(0xFA)
        case 0xF5: // スキャン無効
            keyboardEnabled = false
            queue.append(0xFA)
        case 0xFF: // リセット
            queue.append(0xFA)
            queue.append(0xAA) // 自己診断 OK
        default:
            queue.append(0xFA)
        }
    }

    func writeCommand(_ value: UInt8) {
        lastWriteWasCommand = true
        switch value {
        case 0x20: // コマンドバイト読み取り
            queue.append(commandByte)
        case 0x60: // コマンドバイト書き込み（次バイト）
            expectingCommandByte = true
        case 0xA7:
            keyboardEnabled = false
        case 0xAE:
            keyboardEnabled = true
        case 0xD1: // 出力ポート書き込み（次バイト）
            expectingOutputPort = true
        case 0xD0: // 出力ポート読み取り（A20 有効として 0x02 を含む値を返す）
            queue.append(0xDF)
        default:
            break
        }
    }

    /// ASCII からセット 1 のメイクコードと Shift 要否を返す。
    private static func makeCode(for byte: UInt8) -> (code: UInt8, shift: Bool)? {
        switch byte {
        case 0x1B: return (0x01, false)
        case 0x08, 0x7F: return (0x0E, false)
        case 0x09: return (0x0F, false)
        case 0x0D, 0x0A: return (0x1C, false)
        case 0x20: return (0x39, false)
        default: break
        }
        let plain: [Character: UInt8] = [
            "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06, "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
            "-": 0x0C, "=": 0x0D,
            "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
            "[": 0x1A, "]": 0x1B,
            "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
            ";": 0x27, "'": 0x28, "`": 0x29, "\\": 0x2B,
            "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30, "n": 0x31, "m": 0x32,
            ",": 0x33, ".": 0x34, "/": 0x35,
        ]
        let shifted: [Character: UInt8] = [
            "!": 0x02, "@": 0x03, "#": 0x04, "$": 0x05, "%": 0x06, "^": 0x07, "&": 0x08, "*": 0x09, "(": 0x0A, ")": 0x0B,
            "_": 0x0C, "+": 0x0D, "{": 0x1A, "}": 0x1B, ":": 0x27, "\"": 0x28, "~": 0x29, "|": 0x2B,
            "<": 0x33, ">": 0x34, "?": 0x35,
        ]
        let scalar = UnicodeScalar(byte)
        let char = Character(scalar)
        if let code = plain[char] { return (code, false) }
        if char.isLetter, let code = plain[Character(char.lowercased())] {
            return (code, char.isUppercase)
        }
        if let code = shifted[char] { return (code, true) }
        return nil
    }
}

// MARK: - PCI ホストブリッジ

/// PCI コンフィギュレーション機構 #1（0xCF8 / 0xCFC）。
/// ホストブリッジ、ISA ブリッジ、IDE コントローラ、VGA の 4 デバイスを置く。
final class X86PCIHost {
    private var configAddress: UInt32 = 0
    private var devices: [Int: [UInt8]] = [:]

    init() {
        devices[0x00] = Self.makeDevice(vendor: 0x8086, device: 0x1237, classCode: 0x060000, revision: 0x02, headerType: 0x00)
        devices[0x08] = Self.makeDevice(vendor: 0x8086, device: 0x7000, classCode: 0x060100, revision: 0x00, headerType: 0x80)
        var ide = Self.makeDevice(vendor: 0x8086, device: 0x7010, classCode: 0x010180, revision: 0x00, headerType: 0x00)
        // BAR4: バスマスタ IDE の I/O ベース（0xC000）
        ide[0x20] = 0x01
        ide[0x21] = 0xC0
        devices[0x09] = ide
        devices[0x10] = Self.makeDevice(vendor: 0x1234, device: 0x1111, classCode: 0x030000, revision: 0x02, headerType: 0x00)
        var ahci = Self.makeDevice(vendor: 0x8086, device: 0x2922, classCode: 0x010601, revision: 0x00, headerType: 0x00)
        // BAR5 (ABAR): MMIO 0xFEB00000（4 KiB）
        ahci[0x24] = 0x00
        ahci[0x25] = 0x00
        ahci[0x26] = 0xB0
        ahci[0x27] = 0xFE
        ahci[0x3C] = 11 // Interrupt Line: IRQ11
        ahci[0x3D] = 1  // Interrupt Pin: INTA
        devices[0x18] = ahci
    }

    private static func makeDevice(vendor: UInt16, device: UInt16, classCode: UInt32, revision: UInt8, headerType: UInt8) -> [UInt8] {
        var config = [UInt8](repeating: 0, count: 256)
        config[0] = UInt8(vendor & 0xFF)
        config[1] = UInt8(vendor >> 8)
        config[2] = UInt8(device & 0xFF)
        config[3] = UInt8(device >> 8)
        config[8] = revision
        config[9] = UInt8(classCode & 0xFF)         // プログラミング I/F
        config[10] = UInt8((classCode >> 8) & 0xFF) // サブクラス
        config[11] = UInt8((classCode >> 16) & 0xFF) // ベースクラス
        config[14] = headerType
        return config
    }

    private func selectedDevice() -> Int? {
        guard configAddress & 0x80000000 != 0 else { return nil }
        let bus = Int((configAddress >> 16) & 0xFF)
        guard bus == 0 else { return nil }
        let device = Int((configAddress >> 11) & 0x1F)
        let function = Int((configAddress >> 8) & 0x07)
        let key = (device << 3) | function
        return devices[key] != nil ? key : nil
    }

    func readPort(_ port: UInt16, size: Int) -> UInt32 {
        if (0xCF8...0xCFB).contains(port) {
            // CONFIG_ADDRESS のバイトレーン読み（書き込み側のマージと対称）
            var value: UInt32 = 0
            let lane = Int(port - 0xCF8)
            for i in 0..<size where lane + i < 4 {
                value |= ((configAddress >> (8 * (lane + i))) & 0xFF) << (8 * i)
            }
            return value
        }
        guard port >= 0xCFC, let key = selectedDevice(), let config = devices[key] else {
            return 0xFFFFFFFF
        }
        let baseRegister = Int(configAddress & 0xFC)
        var value: UInt32 = 0
        for i in 0..<size {
            let offset = baseRegister + Int(port - 0xCFC) + i
            if offset < 256 {
                value |= UInt32(config[offset]) << (8 * i)
            }
        }
        return value
    }

    func writePort(_ port: UInt16, value: UInt32, size: Int) {
        if (0xCF8...0xCFB).contains(port) {
            // バイトレーン単位でマージする（部分書き込み対応）
            var merged = configAddress
            let lane = Int(port - 0xCF8)
            for i in 0..<size where lane + i < 4 {
                let shift = 8 * (lane + i)
                merged = (merged & ~(0xFF << shift)) | (((value >> (8 * i)) & 0xFF) << shift)
            }
            configAddress = merged
            return
        }
        guard port >= 0xCFC, let key = selectedDevice() else { return }
        let baseRegister = Int(configAddress & 0xFC)
        for i in 0..<size {
            let offset = baseRegister + Int(port - 0xCFC) + i
            // ベンダ / デバイス（0x00〜0x03）とクラス / リビジョン
            // （0x08〜0x0B）は読み取り専用。コマンド（0x04）は書き込み可。
            if offset >= 4, !(8...11).contains(offset), offset < 256 {
                devices[key]?[offset] = UInt8((value >> (8 * i)) & 0xFF)
            }
        }
    }
}

// MARK: - IDE（ATA）コントローラ

/// プライマリ IDE バスの ATA コントローラ（PIO 転送 + バスマスタ DMA）。
/// ディスクは BIOS と共有する `X86DiskImage` を使う。
final class X86IDEController {
    weak var bus: X86DeviceBus?

    private var sectorCount: UInt8 = 0
    private var lbaLow: UInt8 = 0
    private var lbaMid: UInt8 = 0
    private var lbaHigh: UInt8 = 0
    private var driveHead: UInt8 = 0
    private var errorRegister: UInt8 = 0
    private var hasError = false
    private var dataReady = false
    private var receiveMode = false // true = 書き込みデータ待ち
    private var buffer: [UInt8] = []
    private var bufferIndex = 0
    private var noInterrupt = false

    func reset() {
        hasError = false
        dataReady = false
        receiveMode = false
        buffer = []
        bufferIndex = 0
    }

    private var disk: X86DiskImage? { bus?.cpu?.attachedDisk }
    private var masterSelected: Bool { driveHead & 0x10 == 0 }

    func readStatus() -> UInt8 {
        guard disk != nil, masterSelected else { return 0 }
        var status: UInt8 = 0x40 // DRDY
        if hasError { status |= 0x01 }
        if dataReady { status |= 0x08 } // DRQ
        return status
    }

    func readRegister(_ port: UInt16) -> UInt8 {
        switch port {
        case 0x1F1: return hasError ? errorRegister : 0
        case 0x1F2: return sectorCount
        case 0x1F3: return lbaLow
        case 0x1F4: return lbaMid
        case 0x1F5: return lbaHigh
        case 0x1F6: return driveHead
        case 0x1F7: return readStatus()
        default: return 0
        }
    }

    func readData(size: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<size {
            value |= UInt32(readDataByte()) << (8 * i)
        }
        return value
    }

    private func readDataByte() -> UInt8 {
        guard dataReady, !receiveMode, bufferIndex < buffer.count else { return 0xFF }
        let byte = buffer[bufferIndex]
        bufferIndex += 1
        if bufferIndex >= buffer.count {
            dataReady = false
        }
        return byte
    }

    func writeData(_ value: UInt32, size: Int) {
        for i in 0..<size {
            writeDataByte(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private func writeDataByte(_ byte: UInt8) {
        guard dataReady, receiveMode, bufferIndex < buffer.count else { return }
        buffer[bufferIndex] = byte
        bufferIndex += 1
        if bufferIndex >= buffer.count {
            commitWrite()
        }
    }

    func writeRegister(_ port: UInt16, _ value: UInt8) {
        switch port {
        case 0x1F2: sectorCount = value
        case 0x1F3: lbaLow = value
        case 0x1F4: lbaMid = value
        case 0x1F5: lbaHigh = value
        case 0x1F6: driveHead = value
        case 0x1F7: executeCommand(value)
        default: break
        }
    }

    func writeControl(_ value: UInt8) {
        noInterrupt = value & 0x02 != 0
        if value & 0x04 != 0 { // SRST（ソフトリセット）
            reset()
        }
    }

    private func raiseInterrupt() {
        if !noInterrupt {
            bus?.pulseInterruptLine(14)
        }
    }

    private func fail(abort: Bool = true) {
        hasError = true
        errorRegister = abort ? 0x04 : 0x00
        dataReady = false
        raiseInterrupt()
    }

    private var currentLBA: Int {
        if driveHead & 0x40 != 0 {
            return Int(lbaLow) | (Int(lbaMid) << 8) | (Int(lbaHigh) << 16) | (Int(driveHead & 0x0F) << 24)
        }
        // CHS（16 ヘッド / 63 セクタとして換算）
        let cylinder = (Int(lbaMid) ) | (Int(lbaHigh) << 8)
        let head = Int(driveHead & 0x0F)
        let sector = max(1, Int(lbaLow))
        return ((cylinder * 16) + head) * 63 + (sector - 1)
    }

    private var transferCount: Int {
        sectorCount == 0 ? 256 : Int(sectorCount)
    }

    private func executeCommand(_ command: UInt8) {
        hasError = false
        guard let disk, masterSelected else {
            fail()
            return
        }
        switch command {
        case 0x20, 0x21: // READ SECTORS
            guard currentLBA + transferCount <= disk.sectorCount else { fail(); return }
            let start = currentLBA * 512
            let length = transferCount * 512
            buffer = [UInt8](repeating: 0, count: length)
            if start < disk.data.count {
                let available = min(length, disk.data.count - start)
                buffer.replaceSubrange(0..<available, with: disk.data[start..<(start + available)])
            }
            bufferIndex = 0
            receiveMode = false
            dataReady = true
            raiseInterrupt()
        case 0x30, 0x31: // WRITE SECTORS
            guard currentLBA + transferCount <= disk.sectorCount else { fail(); return }
            buffer = [UInt8](repeating: 0, count: transferCount * 512)
            bufferIndex = 0
            receiveMode = true
            dataReady = true
        case 0xEC: // IDENTIFY DEVICE
            buffer = Self.identifyBlock(disk: disk)
            bufferIndex = 0
            receiveMode = false
            dataReady = true
            raiseInterrupt()
        case 0xC8, 0xC9: // READ DMA（ディスク → メモリ）
            pendingDMARead = true
            runDMAIfReady()
        case 0xCA, 0xCB: // WRITE DMA（メモリ → ディスク）
            pendingDMARead = false
            runDMAIfReady()
        case 0xE7, 0xEA: // FLUSH CACHE
            raiseInterrupt()
        case 0x91, 0xEF, 0x00: // INITIALIZE / SET FEATURES / NOP
            raiseInterrupt()
        default:
            fail()
        }
    }

    private func commitWrite() {
        dataReady = false
        receiveMode = false
        guard let disk else { return }
        let start = currentLBA * 512
        if start + buffer.count <= disk.data.count {
            disk.data.replaceSubrange(start..<(start + buffer.count), with: buffer)
        } else if start < disk.data.count {
            let available = disk.data.count - start
            disk.data.replaceSubrange(start..<(start + available), with: buffer[0..<available])
        }
        raiseInterrupt()
    }

    // MARK: バスマスタ DMA

    /// バスマスタ コマンドレジスタ（bit0 = 開始、bit3 = 方向）。
    private var busMasterCommand: UInt8 = 0
    /// バスマスタ ステータス（bit0 = アクティブ、bit2 = 割り込み、
    /// bit5/6 = DMA 対応チャネル）。
    private var busMasterStatus: UInt8 = 0x60
    /// PRDT（物理領域ディスクリプタテーブル）のアドレス。
    private var prdtAddress: UInt32 = 0
    /// 実行待ちの DMA 方向（true = READ DMA、false = WRITE DMA）。
    private var pendingDMARead: Bool?

    func readBusMaster(offset: Int, size: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<size {
            value |= UInt32(busMasterByte(at: offset + i)) << (8 * i)
        }
        return value
    }

    private func busMasterByte(at offset: Int) -> UInt8 {
        switch offset {
        case 0: return busMasterCommand
        case 2: return busMasterStatus
        case 4...7: return UInt8((prdtAddress >> UInt32(8 * (offset - 4))) & 0xFF)
        default: return 0
        }
    }

    func writeBusMaster(offset: Int, value: UInt32, size: Int) {
        for i in 0..<size {
            writeBusMasterByte(at: offset + i, byte: UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private func writeBusMasterByte(at offset: Int, byte: UInt8) {
        switch offset {
        case 0:
            busMasterCommand = byte & 0x09
            if byte & 0x01 != 0 { runDMAIfReady() }
        case 2:
            // 割り込みビットは write-1-to-clear
            if byte & 0x04 != 0 { busMasterStatus &= ~0x04 }
        case 4...7:
            let shift = UInt32(8 * (offset - 4))
            prdtAddress = (prdtAddress & ~(0xFF << shift)) | (UInt32(byte) << shift)
        default:
            break
        }
    }

    private func guestReadBytes(_ address: Int, count: Int) -> [UInt8] {
        guard let cpu = bus?.cpu else { return [UInt8](repeating: 0, count: count) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        var offset = 0
        while offset < count {
            let chunk = min(4, count - offset)
            let value = (try? cpu.readMemoryValue(at: address + offset, size: chunk)) ?? 0
            for i in 0..<chunk { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
            offset += chunk
        }
        return bytes
    }

    private func guestWriteBytes(_ address: Int, bytes: [UInt8]) {
        guard let cpu = bus?.cpu else { return }
        var offset = 0
        while offset < bytes.count {
            let chunk = min(4, bytes.count - offset)
            var value: UInt64 = 0
            for i in 0..<chunk { value |= UInt64(bytes[offset + i]) << (8 * i) }
            try? cpu.writeMemoryValue(at: address + offset, size: chunk, value)
            offset += chunk
        }
    }

    /// DMA コマンドが発行済みで開始ビットが立っていれば転送を実行する。
    /// 転送は同期的に完了し、IRQ14 と ステータスの割り込みビットで通知する。
    private func runDMAIfReady() {
        guard busMasterCommand & 0x01 != 0, let isRead = pendingDMARead,
              let disk, bus?.cpu != nil else { return }
        pendingDMARead = nil
        if currentLBA + transferCount > disk.sectorCount {
            busMasterStatus |= 0x02 // エラービット
            fail()
            return
        }
        busMasterStatus |= 0x01 // アクティブ
        var remaining = transferCount * 512
        var diskOffset = currentLBA * 512
        var entryAddress = Int(prdtAddress)
        var entries = 0
        while remaining > 0, entries < 1024 {
            entries += 1
            guard let cpu = bus?.cpu,
                  let base = try? cpu.readMemoryValue(at: entryAddress, size: 4),
                  let info = try? cpu.readMemoryValue(at: entryAddress + 4, size: 4) else { break }
            var count = Int(info & 0xFFFF)
            if count == 0 { count = 0x10000 }
            let transfer = min(count, remaining)
            if isRead {
                var bytes = [UInt8](repeating: 0, count: transfer)
                if diskOffset < disk.data.count {
                    let available = min(transfer, disk.data.count - diskOffset)
                    bytes.replaceSubrange(0..<available, with: disk.data[diskOffset..<(diskOffset + available)])
                }
                guestWriteBytes(Int(base), bytes: bytes)
            } else {
                let bytes = guestReadBytes(Int(base), count: transfer)
                if diskOffset < disk.data.count {
                    let available = min(transfer, disk.data.count - diskOffset)
                    disk.data.replaceSubrange(diskOffset..<(diskOffset + available), with: bytes[0..<available])
                }
            }
            diskOffset += transfer
            remaining -= transfer
            if info & 0x80000000 != 0 { break } // EOT
            entryAddress += 8
        }
        busMasterStatus = (busMasterStatus & ~0x01) | 0x04 // 完了 + 割り込み
        raiseInterrupt()
    }

    /// IDENTIFY DEVICE の 512 バイトブロックを組み立てる。
    private static func identifyBlock(disk: X86DiskImage) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func word(_ index: Int, _ value: UInt16) {
            block[index * 2] = UInt8(value & 0xFF)
            block[index * 2 + 1] = UInt8(value >> 8)
        }
        func text(_ wordIndex: Int, _ string: String, _ wordCount: Int) {
            var bytes = [UInt8](string.utf8)
            while bytes.count < wordCount * 2 { bytes.append(0x20) }
            for i in 0..<wordCount {
                block[(wordIndex + i) * 2] = bytes[i * 2 + 1]
                block[(wordIndex + i) * 2 + 1] = bytes[i * 2]
            }
        }
        let totalSectors = disk.sectorCount
        word(0, 0x0040)
        word(1, UInt16(min(16383, max(1, totalSectors / (16 * 63)))))
        word(3, 16)
        word(6, 63)
        text(10, "retasuVM-0001", 10) // シリアル
        text(23, "1.0", 4)            // ファームウェア
        text(27, "retasuVM ATA Disk", 20) // モデル
        word(47, 0x8000)
        word(49, 0x0300) // LBA + DMA サポート
        word(60, UInt16(totalSectors & 0xFFFF))
        word(61, UInt16((totalSectors >> 16) & 0xFFFF))
        return block
    }
}


/// ローカル APIC（MMIO 0xFEE00000）。タイマ割り込み、TPR、EOI、
/// 割り込み保留（IRR）/ 処理中（ISR）の管理を行う。
/// バスクロックは 100 MHz 相当として時間を数える。
final class X86LAPIC {
    private(set) var id: UInt32 = 0
    var tpr: UInt32 = 0
    private(set) var svr: UInt32 = 0x000000FF // リセット時: ベクタ 0xFF、無効
    private var isr: [UInt32] = [UInt32](repeating: 0, count: 8)
    private var irr: [UInt32] = [UInt32](repeating: 0, count: 8)
    private var lvtTimer: UInt32 = 0x00010000
    private var lvtLint0: UInt32 = 0x00010000
    private var lvtLint1: UInt32 = 0x00010000
    private var lvtError: UInt32 = 0x00010000
    private var icrLow: UInt32 = 0
    private var icrHigh: UInt32 = 0
    private var timerDivide: UInt32 = 0
    private var timerInitial: UInt32 = 0
    private var timerDeadline: UInt64 = 0
    private var timerArmed = false
    private var currentNow: UInt64 = 0

    var enabled: Bool { svr & 0x100 != 0 }

    func reset() {
        id = 0
        tpr = 0
        svr = 0x000000FF
        isr = [UInt32](repeating: 0, count: 8)
        irr = [UInt32](repeating: 0, count: 8)
        lvtTimer = 0x00010000
        lvtLint0 = 0x00010000
        lvtLint1 = 0x00010000
        lvtError = 0x00010000
        icrLow = 0
        icrHigh = 0
        timerDivide = 0
        timerInitial = 0
        timerArmed = false
    }

    /// 分周値（Divide Configuration のエンコーディング → 分周比）。
    private var timerDivisor: UInt64 {
        let table: [UInt64] = [2, 4, 8, 16, 32, 64, 128, 1]
        let index = Int(((timerDivide >> 1) & 0x6) | (timerDivide & 0x1))
        return table[index]
    }

    /// 1 カウントの長さ（ナノ秒）。バス 100 MHz（10 ns）× 分周比。
    private var timerPeriodNanos: UInt64 { timerDivisor * 10 }

    func update(now: UInt64) {
        currentNow = now
        guard timerArmed, timerInitial > 0, now >= timerDeadline else { return }
        let periodic = (lvtTimer >> 17) & 0x3 == 1
        if lvtTimer & 0x10000 == 0 && enabled {   // ソフトウェア無効中は実機同様ラッチしない
            requestInterrupt(vector: UInt8(lvtTimer & 0xFF))
        }
        if periodic {
            let period = timerPeriodNanos * UInt64(timerInitial)
            let steps = (now - timerDeadline) / period + 1
            timerDeadline += steps * period
        } else {
            timerArmed = false
        }
    }

    /// 割り込みを保留する（IRR ビットを立てる）。
    func requestInterrupt(vector: UInt8) {
        irr[Int(vector) / 32] |= UInt32(1) << (vector % 32)
    }

    private func highestSetBit(_ registers: [UInt32]) -> Int? {
        for index in stride(from: 7, through: 0, by: -1) where registers[index] != 0 {
            return index * 32 + (31 - registers[index].leadingZeroBitCount)
        }
        return nil
    }

    /// 配送可能な割り込みベクタ（優先度と TPR を考慮）。
    func pendingInterrupt() -> UInt8? {
        guard enabled, let candidate = highestSetBit(irr) else { return nil }
        let candidatePriority = candidate >> 4
        if let inService = highestSetBit(isr), candidatePriority <= (inService >> 4) { return nil }
        if candidatePriority <= (Int(tpr) >> 4) { return nil }
        return UInt8(candidate)
    }

    /// CPU が受け付けたときに呼ぶ（IRR → ISR）。
    func acknowledge(vector: UInt8) {
        irr[Int(vector) / 32] &= ~(UInt32(1) << (vector % 32))
        isr[Int(vector) / 32] |= UInt32(1) << (vector % 32)
    }

    private var processorPriority: UInt32 {
        var priority = Int(tpr) >> 4
        if let inService = highestSetBit(isr) {
            priority = max(priority, inService >> 4)
        }
        return UInt32(priority << 4)
    }

    func readRegister(_ offset: Int) -> UInt32 {
        switch offset {
        case 0x020: return id << 24
        case 0x030: return 0x00050014 // バージョン 0x14、LVT 数 5
        case 0x080: return tpr
        case 0x0A0: return processorPriority
        case 0x0D0: return 0 // LDR
        case 0x0E0: return 0xFFFFFFFF // DFR（フラットモデル）
        case 0x0F0: return svr
        case 0x100...0x170 where (offset & 0xF) == 0: return isr[(offset - 0x100) / 16]
        case 0x200...0x270 where (offset & 0xF) == 0: return irr[(offset - 0x200) / 16]
        case 0x300: return icrLow
        case 0x310: return icrHigh
        case 0x320: return lvtTimer
        case 0x350: return lvtLint0
        case 0x360: return lvtLint1
        case 0x370: return lvtError
        case 0x380: return timerInitial
        case 0x390:
            guard timerArmed, timerInitial > 0, timerDeadline > currentNow else { return 0 }
            let remaining = (timerDeadline - currentNow + timerPeriodNanos - 1) / timerPeriodNanos
            return UInt32(min(remaining, UInt64(timerInitial)))
        case 0x3E0: return timerDivide
        default: return 0
        }
    }

    func writeRegister(_ offset: Int, _ value: UInt32, now: UInt64) {
        switch offset {
        case 0x020: id = (value >> 24) & 0xFF
        case 0x080: tpr = value & 0xFF
        case 0x0B0: // EOI: 最上位の ISR ビットを落とす
            if let inService = highestSetBit(isr) {
                isr[inService / 32] &= ~(UInt32(1) << (inService % 32))
            }
        case 0x0F0: svr = value
        case 0x300: icrLow = value // IPI は単一 CPU のため配送先なし（値のみ保持）
        case 0x310: icrHigh = value
        case 0x320: lvtTimer = value
        case 0x350: lvtLint0 = value
        case 0x360: lvtLint1 = value
        case 0x370: lvtError = value
        case 0x380:
            timerInitial = value
            currentNow = now
            if value > 0 {
                timerDeadline = now + timerPeriodNanos * UInt64(value)
                timerArmed = true
            } else {
                timerArmed = false
            }
        case 0x3E0: timerDivide = value & 0xB
        default: break
        }
    }
}

/// I/O APIC（MMIO 0xFEC00000）。IOREGSEL / IOWIN 経由のレジスタ
/// アクセスと、リダイレクションテーブルによる割り込みの LAPIC への
/// 配送を行う。ピンは IRQ 番号に対応し、PIT だけは実機どおりピン 2。
final class X86IOAPIC {
    var selectedRegister: UInt32 = 0
    private(set) var id: UInt32 = 0
    private var redirectionLow: [UInt32] = [UInt32](repeating: 0x00010000, count: 24)
    private var redirectionHigh: [UInt32] = [UInt32](repeating: 0, count: 24)
    private var pinLevels: [Bool] = [Bool](repeating: false, count: 24)
    private var edgeLatch: [Bool] = [Bool](repeating: false, count: 24)

    func reset() {
        selectedRegister = 0
        redirectionLow = [UInt32](repeating: 0x00010000, count: 24)
        redirectionHigh = [UInt32](repeating: 0, count: 24)
        pinLevels = [Bool](repeating: false, count: 24)
        edgeLatch = [Bool](repeating: false, count: 24)
    }

    /// レベル型デバイスのライン状態を伝える。立ち上がりエッジは
    /// エッジトリガ設定のエントリ用にもラッチする。
    func setPinLevel(_ pin: Int, _ asserted: Bool) {
        guard pin >= 0, pin < 24 else { return }
        if asserted && !pinLevels[pin] { edgeLatch[pin] = true }
        pinLevels[pin] = asserted
    }

    /// エッジ型デバイスのパルスを伝える。
    func pulsePin(_ pin: Int) {
        guard pin >= 0, pin < 24 else { return }
        edgeLatch[pin] = true
    }

    /// 保留中の割り込みを LAPIC へ配送する。
    func service(lapic: X86LAPIC) {
        for pin in 0..<24 {
            let low = redirectionLow[pin]
            guard low & 0x10000 == 0 else { continue } // マスク中
            let levelTriggered = low & 0x8000 != 0
            let active = levelTriggered ? pinLevels[pin] : edgeLatch[pin]
            guard active else { continue }
            lapic.requestInterrupt(vector: UInt8(low & 0xFF))
            if !levelTriggered { edgeLatch[pin] = false }
        }
    }

    func readRegister() -> UInt32 {
        switch selectedRegister {
        case 0x00: return id << 24
        case 0x01: return 0x00170011 // バージョン 0x11、エントリ数 24
        case 0x10...0x3F:
            let pin = Int((selectedRegister - 0x10) / 2)
            return selectedRegister & 1 == 0 ? redirectionLow[pin] : redirectionHigh[pin]
        default: return 0
        }
    }

    func writeRegister(_ value: UInt32) {
        switch selectedRegister {
        case 0x00: id = (value >> 24) & 0xF
        case 0x10...0x3F:
            let pin = Int((selectedRegister - 0x10) / 2)
            if selectedRegister & 1 == 0 {
                redirectionLow[pin] = value
            } else {
                redirectionHigh[pin] = value
            }
        default: break
        }
    }
}


// MARK: - HPET

/// High Precision Event Timer（MMIO 0xFED00000、タイマ 3 本、64 ビット
/// メインカウンタ、10 MHz = 周期 100 ns）。macOS のカーネル (XNU) が
/// 起動に必須とするタイマ。レガシー置換モード（タイマ 0 → IRQ0、
/// タイマ 1 → IRQ8）と、IOAPIC へのルーティング指定の両方に対応する。
final class X86HPET {
    static let baseAddress: UInt64 = 0xFED00000
    weak var bus: X86DeviceBus?

    private var config: UInt64 = 0          // bit0: ENABLE、bit1: LEG_RT
    private var interruptStatus: UInt64 = 0 // レベル型タイマの状態（W1C）
    private var epochTicks: UInt64 = 0
    private var frozenCounter: UInt64 = 0

    private struct Timer {
        var config: UInt64 = 0
        var comparator: UInt64 = 0
        var armed = false
        var step: UInt64 = 0
        var levelAsserted = false
    }
    private var timers = [Timer](repeating: Timer(), count: 3)

    func reset() {
        config = 0
        interruptStatus = 0
        epochTicks = 0
        frozenCounter = 0
        timers = [Timer](repeating: Timer(), count: 3)
    }

    /// メインカウンタ（10 MHz: 100 ns ごとに 1 進む）。
    private func counter(now: UInt64) -> UInt64 {
        config & 1 != 0 ? (now / 100) &- epochTicks : frozenCounter
    }

    func read(offset: Int, size: Int, now: UInt64) -> UInt64 {
        let register = readRegister(offset & ~7, now: now)
        if size >= 8 { return register }
        let lane = offset & 7
        return (register >> (lane * 8)) & ((UInt64(1) << (size * 8)) - 1)
    }

    func write(offset: Int, size: Int, _ value: UInt64, now: UInt64) {
        let registerOffset = offset & ~7
        let lane = offset & 7
        let current = readRegister(registerOffset, now: now)
        let merged: UInt64
        if size >= 8 {
            merged = value
        } else {
            let mask: UInt64 = ((UInt64(1) << (size * 8)) - 1) << (lane * 8)
            merged = (current & ~mask) | ((value & ((UInt64(1) << (size * 8)) - 1)) << (lane * 8))
        }
        writeRegister(registerOffset, merged, now: now)
    }

    private func readRegister(_ offset: Int, now: UInt64) -> UInt64 {
        switch offset {
        case 0x00: // GCAP_ID: ベンダ 8086 / タイマ 3 / 64 ビット / レガシー置換可 / 周期 100 ns
            return 0x05F5E100_8086A201
        case 0x10:
            return config
        case 0x20:
            return interruptStatus
        case 0xF0:
            return counter(now: now)
        case 0x100, 0x120, 0x140: // タイマ コンフィギュレーション
            let index = (offset - 0x100) / 0x20
            return timers[index].config | (1 << 4) | (1 << 5) | (0x00FFFFFF << 32)
        case 0x108, 0x128, 0x148: // コンパレータ
            let index = (offset - 0x100) / 0x20
            return timers[index].comparator
        default:
            return 0
        }
    }

    private func writeRegister(_ offset: Int, _ value: UInt64, now: UInt64) {
        switch offset {
        case 0x10:
            let wasEnabled = config & 1 != 0
            let isEnabled = value & 1 != 0
            if !wasEnabled && isEnabled {
                epochTicks = (now / 100) &- frozenCounter
            } else if wasEnabled && !isEnabled {
                frozenCounter = counter(now: now)
            }
            config = value & 0x3
        case 0x20: // W1C: レベル型の割り込み線も下げる
            let cleared = interruptStatus & value
            interruptStatus &= ~value
            for i in timers.indices where cleared & (UInt64(1) << i) != 0 && timers[i].levelAsserted {
                timers[i].levelAsserted = false
                let route = Int((timers[i].config >> 9) & 0x1F)
                bus?.ioapic.setPinLevel(route, false)
            }
        case 0xF0:
            if config & 1 != 0 {
                epochTicks = (now / 100) &- value
            } else {
                frozenCounter = value
            }
        case 0x100, 0x120, 0x140:
            let index = (offset - 0x100) / 0x20
            timers[index].config = value & (0x2 | 0x4 | 0x8 | 0x40 | (0x1F << 9))
        case 0x108, 0x128, 0x148:
            let index = (offset - 0x100) / 0x20
            timers[index].comparator = value
            timers[index].armed = true
            let current = counter(now: now)
            timers[index].step = value > current ? value - current : 0
        default:
            break
        }
    }

    /// コンパレータ到達の監視（updateDevices から毎回呼ばれる）。
    func update(now: UInt64) {
        guard config & 1 != 0 else { return }
        let current = counter(now: now)
        for i in timers.indices {
            guard timers[i].armed, timers[i].config & 0x4 != 0,
                  current >= timers[i].comparator else { continue }
            fire(i)
            if timers[i].config & 0x8 != 0 { // 周期モード: 再装填
                let step = timers[i].step == 0 ? 1 : timers[i].step
                var next = timers[i].comparator &+ step
                if next <= current { next = current &+ step }
                timers[i].comparator = next
            } else {
                timers[i].armed = false
            }
        }
    }

    private func fire(_ index: Int) {
        let timerConfig = timers[index].config
        if config & 0x2 != 0 && index <= 1 { // レガシー置換: T0 → IRQ0、T1 → IRQ8
            bus?.pulseInterruptLine(index == 0 ? 0 : 8)
            if timerConfig & 0x2 != 0 { interruptStatus |= UInt64(1) << index }
            return
        }
        let route = Int((timerConfig >> 9) & 0x1F)
        if timerConfig & 0x2 != 0 { // レベル型
            interruptStatus |= UInt64(1) << index
            timers[index].levelAsserted = true
            bus?.ioapic.setPinLevel(route, true)
        } else { // エッジ型
            bus?.ioapic.pulsePin(route)
        }
    }
}

// MARK: - Apple SMC

/// Apple System Management Controller（I/O ポート 0x300 = データ、
/// 0x304 = コマンド / ステータス）の最小エミュレーション。
/// キープロトコル（0x10 読み取り / 0x11 書き込み / 0x12 インデックス
/// 取得 / 0x13 キー情報）を実装し、macOS が要求する OSK0 / OSK1
/// キー（"our hard work by these words guarded, please steal, (c)
/// AppleCom…" の 64 バイト）を返す。
final class X86SMC {
    private struct Key {
        let name: String
        let type: String
        let value: [UInt8]
    }
    private let keys: [Key]

    // プロトコル状態: 0 コマンド待ち / 1 キー名 / 2 長さ / 3 書込データ / 4 インデックス
    private var phase = 0
    private var command: UInt8 = 0
    private var keyBytes: [UInt8] = []
    private var writeLength = 0
    private var writeBytes: [UInt8] = []
    private var indexBytes: [UInt8] = []
    private var response: [UInt8] = []

    init() {
        var list: [Key] = [
            Key(name: "#KEY", type: "ui32", value: []),
            Key(name: "OSK0", type: "ch8*", value: [UInt8]("our hard work by these words gua".utf8)),
            Key(name: "OSK1", type: "ch8*", value: [UInt8]("rded, please steal, (c) AppleCom".utf8)),
            Key(name: "REV ", type: "ch8*", value: [0x02, 0x25, 0x0F, 0x00, 0x00, 0x03]),
            Key(name: "MSLD", type: "ui8 ", value: [0]),
            Key(name: "BNum", type: "ui8 ", value: [1]),
        ]
        let count = list.count
        list[0] = Key(name: "#KEY", type: "ui32", value: [
            UInt8((count >> 24) & 0xFF), UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
        keys = list
    }

    func reset() {
        phase = 0
        keyBytes = []
        writeBytes = []
        indexBytes = []
        response = []
    }

    /// ステータス: bit0 = 応答データあり、bit2 = 入力受付可。
    func readStatus() -> UInt8 {
        response.isEmpty ? 0x04 : 0x01
    }

    func readData() -> UInt8 {
        response.isEmpty ? 0 : response.removeFirst()
    }

    func writeCommand(_ value: UInt8) {
        guard phase == 0, response.isEmpty else { return }
        command = value
        keyBytes = []
        indexBytes = []
        switch value {
        case 0x10, 0x11, 0x13:
            phase = 1
        case 0x12:
            phase = 4
        default:
            break
        }
    }

    func writeData(_ value: UInt8) {
        switch phase {
        case 1:
            keyBytes.append(value)
            guard keyBytes.count == 4 else { return }
            if command == 0x13 {
                response = keyInfo(for: keyBytes)
                phase = 0
            } else {
                phase = 2
            }
        case 2:
            let length = Int(value)
            if command == 0x10 {
                response = readValue(for: keyBytes, length: length)
                phase = 0
            } else {
                writeLength = length
                writeBytes = []
                phase = length == 0 ? 0 : 3
            }
        case 3:
            writeBytes.append(value)
            if writeBytes.count >= writeLength { phase = 0 }
        case 4:
            indexBytes.append(value)
            guard indexBytes.count == 2 else { return }
            let index = (Int(indexBytes[0]) << 8) | Int(indexBytes[1])
            response = index < keys.count ? [UInt8](keys[index].name.utf8) : [0, 0, 0, 0]
            phase = 0
        default:
            break
        }
    }

    private func findKey(_ bytes: [UInt8]) -> Key? {
        let name = String(bytes: bytes, encoding: .ascii) ?? ""
        return keys.first { $0.name == name }
    }

    private func keyInfo(for bytes: [UInt8]) -> [UInt8] {
        guard let key = findKey(bytes) else { return [0, 0, 0, 0, 0, 0] }
        return [UInt8(key.value.count)] + [UInt8](key.type.utf8) + [0]
    }

    private func readValue(for bytes: [UInt8], length: Int) -> [UInt8] {
        guard let key = findKey(bytes) else { return [UInt8](repeating: 0, count: length) }
        var value = key.value
        while value.count < length { value.append(0) }
        return Array(value.prefix(length))
    }
}

// MARK: - AHCI（SATA）コントローラ

/// AHCI 1.3 互換の SATA ホストコントローラ（PCI デバイス 3、BAR5 は
/// 0xFEB00000 固定）。ポート 0 に IDE と共有するディスクを接続し、
/// コマンドリスト / レジスタ FIS / PRDT による DMA 転送（IDENTIFY
/// DEVICE、READ / WRITE DMA (EXT)、FLUSH CACHE）を同期的に実行する。
/// 現在の macOS は IDE (PATA) ドライバを持たないため、SATA が
/// ディスクアクセスの前提になる。
final class X86AHCIController {
    static let abarAddress: UInt64 = 0xFEB00000
    weak var bus: X86DeviceBus?

    private var ghc: UInt32 = 0
    private var globalInterruptStatus: UInt32 = 0
    private var commandListBase: UInt64 = 0
    private var fisBase: UInt64 = 0
    private var portInterruptStatus: UInt32 = 0
    private var portInterruptEnable: UInt32 = 0
    private var portCommand: UInt32 = 0
    private var portSControl: UInt32 = 0
    private var portSActive: UInt32 = 0
    private var portCommandIssue: UInt32 = 0
    private var lastCommandError = false

    private var disk: X86DiskImage? { bus?.cpu?.attachedDisk }
    private var devicePresent: Bool { disk != nil }

    func reset() {
        ghc = 0
        globalInterruptStatus = 0
        commandListBase = 0
        fisBase = 0
        portInterruptStatus = 0
        portInterruptEnable = 0
        portCommand = 0
        portSControl = 0
        portSActive = 0
        portCommandIssue = 0
        lastCommandError = false
    }

    func read(offset: Int, size: Int) -> UInt64 {
        let register = readRegister(offset & ~3)
        if size >= 4 { return UInt64(register) }
        let lane = offset & 3
        return UInt64(register >> (lane * 8)) & ((UInt64(1) << (size * 8)) - 1)
    }

    func write(offset: Int, size: Int, _ value: UInt64) {
        let registerOffset = offset & ~3
        let lane = offset & 3
        let current = readRegister(registerOffset)
        let merged: UInt32
        if size >= 4 {
            merged = UInt32(value & 0xFFFFFFFF)
        } else {
            let mask: UInt32 = UInt32((UInt64(1) << (size * 8)) - 1) << (lane * 8)
            merged = (current & ~mask) | (UInt32(value) << (lane * 8))
        }
        writeRegister(registerOffset, merged)
    }

    private func readRegister(_ offset: Int) -> UInt32 {
        switch offset {
        case 0x00: return 0x80301F00 // CAP: S64A / Gen3 / スロット 32 / ポート 1
        case 0x04: return ghc
        case 0x08: return devicePresent ? 1 : 0 // PI
        case 0x0C: return 0x00010301 // VS: AHCI 1.3.1
        case 0x10: return globalInterruptStatus
        case 0x100: return UInt32(commandListBase & 0xFFFFFFFF)
        case 0x104: return UInt32(commandListBase >> 32)
        case 0x108: return UInt32(fisBase & 0xFFFFFFFF)
        case 0x10C: return UInt32(fisBase >> 32)
        case 0x110: return portInterruptStatus
        case 0x114: return portInterruptEnable
        case 0x118:
            var value = portCommand
            if portCommand & 0x01 != 0 { value |= 0x8000 } // CR = ST
            if portCommand & 0x10 != 0 { value |= 0x4000 } // FR = FRE
            return value
        case 0x120: return devicePresent ? (lastCommandError ? 0x41 : 0x40) : 0 // TFD
        case 0x124: return devicePresent ? 0x00000101 : 0xFFFFFFFF // SIG: ATA デバイス
        case 0x128: return devicePresent ? 0x00000103 : 0 // SSTS: DET=3 / IPM=1
        case 0x12C: return portSControl
        case 0x130: return 0 // SERR
        case 0x134: return portSActive
        case 0x138: return portCommandIssue
        default: return 0
        }
    }

    private func writeRegister(_ offset: Int, _ value: UInt32) {
        switch offset {
        case 0x04:
            if value & 0x01 != 0 { reset(); return } // HR（ホストリセット）
            ghc = value & 0x80000002 // AE + IE
        case 0x10:
            globalInterruptStatus &= ~value
        case 0x100:
            commandListBase = (commandListBase & 0xFFFFFFFF00000000) | UInt64(value & 0xFFFFFC00)
        case 0x104:
            commandListBase = (commandListBase & 0xFFFFFFFF) | (UInt64(value) << 32)
        case 0x108:
            fisBase = (fisBase & 0xFFFFFFFF00000000) | UInt64(value & 0xFFFFFF00)
        case 0x10C:
            fisBase = (fisBase & 0xFFFFFFFF) | (UInt64(value) << 32)
        case 0x110:
            portInterruptStatus &= ~value
        case 0x114:
            portInterruptEnable = value
        case 0x118:
            portCommand = value & 0x1F // ST / SUD / POD / CLO / FRE
        case 0x12C:
            portSControl = value
        case 0x134:
            portSActive = value
        case 0x138:
            let newBits = value & ~portCommandIssue
            portCommandIssue = value
            for slot in 0..<32 where newBits & (UInt32(1) << slot) != 0 {
                executeCommand(slot: slot)
            }
        default:
            break
        }
    }

    // MARK: コマンド実行

    private func executeCommand(slot: Int) {
        defer { portCommandIssue &= ~(UInt32(1) << slot) }
        guard let cpu = bus?.cpu, let disk else { completeWithError(); return }
        let headerAddress = commandListBase + UInt64(slot) * 32
        let header0 = guestRead32(cpu, headerAddress)
        let prdtl = Int((header0 >> 16) & 0xFFFF)
        let tableAddress = UInt64(guestRead32(cpu, headerAddress + 8))
            | (UInt64(guestRead32(cpu, headerAddress + 12)) << 32)
        var fis = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { fis[i] = guestRead8(cpu, tableAddress + UInt64(i)) }
        guard fis[0] == 0x27 else { completeWithError(); return }
        let command = fis[2]
        var lba = UInt64(fis[4]) | (UInt64(fis[5]) << 8) | (UInt64(fis[6]) << 16)
        var count = 0
        if command == 0x25 || command == 0x35 { // LBA48
            lba |= (UInt64(fis[8]) << 24) | (UInt64(fis[9]) << 32) | (UInt64(fis[10]) << 40)
            count = Int(fis[12]) | (Int(fis[13]) << 8)
            if count == 0 { count = 0x10000 }
        } else {
            lba |= UInt64(fis[7] & 0x0F) << 24
            count = Int(fis[12])
            if count == 0 { count = 256 }
        }
        let transferred: Int
        switch command {
        case 0xEC: // IDENTIFY DEVICE
            transferred = transferToGuest(cpu, tableAddress: tableAddress, prdtl: prdtl,
                                          data: Self.identifyData(sectorCount: disk.sectorCount))
        case 0x25, 0xC8: // READ DMA EXT / READ DMA
            guard lba + UInt64(count) <= UInt64(disk.sectorCount) else { completeWithError(); return }
            let start = Int(lba) * 512
            transferred = transferToGuest(cpu, tableAddress: tableAddress, prdtl: prdtl,
                                          data: Array(disk.data[start..<(start + count * 512)]))
        case 0x35, 0xCA: // WRITE DMA EXT / WRITE DMA
            guard lba + UInt64(count) <= UInt64(disk.sectorCount) else { completeWithError(); return }
            let data = transferFromGuest(cpu, tableAddress: tableAddress, prdtl: prdtl, length: count * 512)
            let start = Int(lba) * 512
            disk.data.replaceSubrange(start..<(start + data.count), with: data)
            transferred = data.count
        case 0xE7, 0xEA: // FLUSH CACHE (EXT)
            transferred = 0
        default:
            completeWithError()
            return
        }
        guestWrite32(cpu, headerAddress + 4, UInt32(transferred)) // PRDBC
        lastCommandError = false
        portInterruptStatus |= 0x01 // DHRS
        globalInterruptStatus |= 0x01
        notifyIfEnabled()
    }

    private func completeWithError() {
        lastCommandError = true
        portInterruptStatus |= 0x40000000 // TFES
        globalInterruptStatus |= 0x01
        notifyIfEnabled()
    }

    private func notifyIfEnabled() {
        if portInterruptEnable & portInterruptStatus != 0 && ghc & 0x02 != 0 {
            bus?.pulseInterruptLine(11)
        }
    }

    // MARK: PRDT 転送とゲストメモリアクセス

    private func transferToGuest(_ cpu: X86CPU, tableAddress: UInt64, prdtl: Int, data: [UInt8]) -> Int {
        var written = 0
        for entry in 0..<prdtl where written < data.count {
            let entryAddress = tableAddress + 0x80 + UInt64(entry) * 16
            let base = UInt64(guestRead32(cpu, entryAddress)) | (UInt64(guestRead32(cpu, entryAddress + 4)) << 32)
            let capacity = Int(guestRead32(cpu, entryAddress + 12) & 0x3FFFFF) + 1
            let chunk = min(capacity, data.count - written)
            guestWriteBytes(cpu, base, Array(data[written..<(written + chunk)]))
            written += chunk
        }
        return written
    }

    private func transferFromGuest(_ cpu: X86CPU, tableAddress: UInt64, prdtl: Int, length: Int) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(length)
        for entry in 0..<prdtl where data.count < length {
            let entryAddress = tableAddress + 0x80 + UInt64(entry) * 16
            let base = UInt64(guestRead32(cpu, entryAddress)) | (UInt64(guestRead32(cpu, entryAddress + 4)) << 32)
            let capacity = Int(guestRead32(cpu, entryAddress + 12) & 0x3FFFFF) + 1
            let chunk = min(capacity, length - data.count)
            data += guestReadBytes(cpu, base, count: chunk)
        }
        return data
    }

    private func guestRead8(_ cpu: X86CPU, _ address: UInt64) -> UInt8 {
        UInt8((try? cpu.readMemoryValue(at: Int(address & 0xFFFFFFFF), size: 1)) ?? 0)
    }

    private func guestRead32(_ cpu: X86CPU, _ address: UInt64) -> UInt32 {
        UInt32((try? cpu.readMemoryValue(at: Int(address & 0xFFFFFFFF), size: 4)) ?? 0)
    }

    private func guestReadBytes(_ cpu: X86CPU, _ address: UInt64, count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let chunk = min(4, count - offset)
            let value = (try? cpu.readMemoryValue(at: Int((address + UInt64(offset)) & 0xFFFFFFFF), size: chunk)) ?? 0
            for i in 0..<chunk { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
            offset += chunk
        }
        return bytes
    }

    private func guestWriteBytes(_ cpu: X86CPU, _ address: UInt64, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let chunk = min(4, bytes.count - offset)
            var value: UInt64 = 0
            for i in 0..<chunk { value |= UInt64(bytes[offset + i]) << (8 * i) }
            try? cpu.writeMemoryValue(at: Int((address + UInt64(offset)) & 0xFFFFFFFF), size: chunk, value)
            offset += chunk
        }
    }

    private func guestWrite32(_ cpu: X86CPU, _ address: UInt64, _ value: UInt32) {
        try? cpu.writeMemoryValue(at: Int(address & 0xFFFFFFFF), size: 4, UInt64(value))
    }

    // MARK: IDENTIFY DEVICE

    private static func identifyData(sectorCount: Int) -> [UInt8] {
        var words = [UInt16](repeating: 0, count: 256)
        words[0] = 0x0040
        words[1] = 16383 // シリンダ（旧ジオメトリ）
        words[3] = 16    // ヘッド
        words[6] = 63    // セクタ / トラック
        func setString(_ range: ClosedRange<Int>, _ string: String) {
            var chars = [UInt8](string.utf8)
            while chars.count < (range.upperBound - range.lowerBound + 1) * 2 { chars.append(0x20) }
            for (i, index) in range.enumerated() {
                words[index] = (UInt16(chars[i * 2]) << 8) | UInt16(chars[i * 2 + 1])
            }
        }
        setString(10...19, "RETASU00000000000001")
        setString(23...26, "0.13")
        setString(27...46, "retasuVM AHCI Disk")
        words[47] = 0x8000
        words[49] = 0x0300 // LBA + DMA 対応
        words[53] = 0x0002
        let total28 = min(sectorCount, 0x0FFFFFFF)
        words[60] = UInt16(total28 & 0xFFFF)
        words[61] = UInt16(total28 >> 16)
        words[63] = 0x0407 // マルチワード DMA モード 2 選択
        words[64] = 0x0003 // PIO モード 3 / 4
        words[80] = 0x00F0 // ATA / ATAPI 4〜7
        words[82] = 0x0040
        words[83] = 0x4400 // LBA48 対応
        words[85] = 0x0040
        words[86] = 0x0400
        words[88] = 0x203F // UDMA モード 5 選択
        let total = UInt64(sectorCount)
        words[100] = UInt16(total & 0xFFFF)
        words[101] = UInt16((total >> 16) & 0xFFFF)
        words[102] = UInt16((total >> 32) & 0xFFFF)
        words[103] = UInt16((total >> 48) & 0xFFFF)
        var bytes = [UInt8](repeating: 0, count: 512)
        for i in 0..<256 {
            bytes[i * 2] = UInt8(words[i] & 0xFF)
            bytes[i * 2 + 1] = UInt8(words[i] >> 8)
        }
        bytes[510] = 0xA5
        var sum = 0
        for i in 0..<512 where i != 511 { sum += Int(bytes[i]) }
        bytes[511] = UInt8((256 - (sum % 256)) % 256)
        return bytes
    }
}
