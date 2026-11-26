import Foundation

enum X86BootError: Error, CustomStringConvertible, LocalizedError {
    case imageTooSmall
    case notBootable(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .imageTooSmall:
            return "ディスクイメージが小さすぎます（512 バイト未満）"
        case .notBootable(let detail):
            return detail
        }
    }
}

/// 自作の BIOS サービス層とブート処理。
///
/// 実際の PC ではファームウェア（BIOS / UEFI）が担う役割をホスト側で実装する:
/// ブートデバイスからブートセクタを 0x7C00 へ読み込んで実行を開始し、
/// INT 10h（画面）/ INT 13h（ディスク）/ INT 16h（キーボード）などの
/// BIOS コールに応答する。ISO イメージは El Torito 規格でブートする。
final class X86BIOS {
    private weak var cpu: X86CPU?

    /// IDE コントローラと共有するディスクイメージ。
    private var diskBox: X86DiskImage?
    private var diskData: [UInt8] { diskBox?.data ?? [] }

    /// ディスクイメージを設定し、CPU（IDE コントローラ）へも接続する。
    private func setDisk(_ data: [UInt8]) {
        let box = X86DiskImage(data: data)
        diskBox = box
        cpu?.attachDisk(box)
    }
    private var diskSectorSize = 512
    private var heads = 255
    private var sectorsPerTrack = 63
    private(set) var bootDrive: UInt8 = 0x80
    /// INT 10h カーソル状態（AH=01 で設定した形状、AH=02 で設定した位置）。
    private var cursorShape: UInt16 = 0x0607
    private var cursorPosition: UInt16 = 0
    private let startTime = Date()
    /// INT 1Ah の日付変更フラグ用: 最後に報告した日番号。
    private var lastTickDay: UInt64 = 0

    init(cpu: X86CPU) {
        self.cpu = cpu
    }

    // MARK: - ブート

    /// イメージデータ（ISO または raw ディスクイメージ）からブートする。
    func boot(imageData: [UInt8]) throws {
        guard let cpu else { return }
        if ElTorito.isISO9660(imageData) {
            let image: ElTorito.BootImage
            do {
                image = try ElTorito.bootImage(fromISO: imageData)
            } catch let error as ElToritoError {
                throw X86BootError.notBootable(error.description)
            }
            setDisk(image.diskData)
            diskSectorSize = image.diskSectorSize
            heads = image.heads
            sectorsPerTrack = image.sectorsPerTrack
            bootDrive = image.bootDrive
            cpu.resetForBoot(bootDrive: bootDrive)
            cpu.loadData(image.bytesToLoad, at: image.loadAddress)
            if image.mediaType == .noEmulation {
                cpu.setSegment(1, image.entrySegment)
                cpu.setInstructionPointer(0)
            }
        } else {
            // raw イメージ: 先頭セクタ（MBR / ブートセクタ）を読み込む
            guard imageData.count >= 512 else { throw X86BootError.imageTooSmall }
            setDisk(imageData)
            diskSectorSize = 512
            switch imageData.count {
            case 1_228_800: heads = 2; sectorsPerTrack = 15; bootDrive = 0x00
            case 1_474_560: heads = 2; sectorsPerTrack = 18; bootDrive = 0x00
            case 2_949_120: heads = 2; sectorsPerTrack = 36; bootDrive = 0x00
            default: heads = 255; sectorsPerTrack = 63; bootDrive = 0x80
            }
            cpu.resetForBoot(bootDrive: bootDrive)
            cpu.loadData(Array(imageData.prefix(512)), at: 0x7C00)
        }
    }

    // MARK: - 割り込みディスパッチ

    func handleInterrupt(_ vector: UInt8) -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        switch vector {
        case 0x10: return handleVideo()
        case 0x13: return handleDisk()
        case 0x16: return handleKeyboard()
        case 0x12:
            cpu.setRegister16(0, 640)
            return .handled
        case 0x1A: return handleTimer()
        case 0x15: return handleSystemServices()
        case 0x18, 0x19:
            cpu.halt(exitCode: 0)
            return .handled
        default:
            return .handled
        }
    }

    // MARK: - INT 10h: 画面

    private func handleVideo() -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        let ah = cpu.register8(4)
        switch ah {
        case 0x00: // モード設定（レジスタ表を読み込み、画面をクリア）
            let mode = cpu.register8(0)
            cpu.devices.loadVideoModeRegisters(mode)
            if mode & 0x7F == 0x13, mode & 0x80 == 0 {
                cpu.loadData([UInt8](repeating: 0, count: 0x10000), at: 0xA0000)
            }
            cpu.onClearScreen?()
        case 0x0E: // テレタイプ出力
            let byte = cpu.register8(0)
            if byte != 0x07 { // ベルは無視
                cpu.onChar?(byte)
            }
        case 0x09, 0x0A: // 文字の繰り返し書き込み
            let count = max(1, Int(cpu.register16(1)))
            let byte = cpu.register8(0)
            for _ in 0..<count { cpu.onChar?(byte) }
        case 0x13: // 文字列書き込み（ES:BP、長さ CX、AL の bit1 で属性混在）
            let segment = cpu.segment(0)
            var offset = UInt32(cpu.register16(5))
            let count = Int(cpu.register16(1))
            let withAttributes = cpu.register8(0) & 0x02 != 0
            for _ in 0..<count {
                let address = cpu.physicalAddress(segment: segment, offset: offset)
                if let byte = try? cpu.readMemory8(at: address) {
                    if byte != 0x07 { cpu.onChar?(byte) }
                }
                offset += withAttributes ? 2 : 1
            }
        case 0x06, 0x07: // スクロール（全消去のみ対応）
            if cpu.register8(0) == 0 { cpu.onClearScreen?() }
        case 0x0F: // 現在のモード取得
            cpu.setRegister8(0, cpu.devices.biosVideoMode) // AL: 現在のモード
            cpu.setRegister8(4, 80) // AH: 桁数
            cpu.setRegister8(7, 0)  // BH: ページ
        case 0x01: // カーソル形状設定（CX）
            cursorShape = cpu.register16(1)
        case 0x02: // カーソル位置設定（DX: DH=行, DL=列）
            cursorPosition = cpu.register16(2)
        case 0x03: // カーソル位置取得（設定した値を返す）
            cpu.setRegister16(2, cursorPosition)
            cpu.setRegister16(1, cursorShape)
        default:
            break
        }
        return .handled
    }

    // MARK: - INT 13h: ディスク

    private func setDiskResult(success: Bool, status: UInt8) {
        guard let cpu else { return }
        cpu.setFlag(X86CPU.flagCarry, !success)
        cpu.setRegister8(4, status)
    }

    private func handleDisk() -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        let ah = cpu.register8(4)
        // 自ドライブ宛てでなければエラー
        if cpu.register8(2) != bootDrive && ah != 0x00 {
            setDiskResult(success: false, status: 0x01)
            return .handled
        }
        switch ah {
        case 0x00: // リセット
            setDiskResult(success: true, status: 0)
        case 0x02, 0x03: // CHS 読み取り / 書き込み
            let count = Int(cpu.register8(0))
            let cylinder = Int(cpu.register8(5)) | ((Int(cpu.register8(1)) & 0xC0) << 2)
            let sector = Int(cpu.register8(1)) & 0x3F
            let head = Int(cpu.register8(6))
            let lba = ((cylinder * heads) + head) * sectorsPerTrack + (sector - 1)
            let buffer = cpu.physicalAddress(segment: cpu.segment(0), offset: UInt32(cpu.register16(3)))
            transfer(lba: lba, count: count, buffer: buffer, isWrite: ah == 0x03)
        case 0x08: // ジオメトリ取得
            let cylinders = max(1, diskData.count / diskSectorSize / (heads * sectorsPerTrack))
            cpu.setRegister8(5, UInt8((cylinders - 1) & 0xFF))
            cpu.setRegister8(1, UInt8(sectorsPerTrack) | UInt8(((cylinders - 1) >> 2) & 0xC0))
            cpu.setRegister8(6, UInt8(heads - 1))
            cpu.setRegister8(2, 1)
            setDiskResult(success: true, status: 0)
        case 0x15: // ドライブ種別（固定ディスクとして総セクタ数を返す）
            let total = UInt32(diskData.count / diskSectorSize)
            cpu.setRegister8(4, 3)
            cpu.setRegister16(1, UInt16(total >> 16))
            cpu.setRegister16(2, UInt16(total & 0xFFFF))
            cpu.setFlag(X86CPU.flagCarry, false)
        case 0x41: // 拡張機能チェック
            if cpu.register16(3) == 0xAA55 {
                cpu.setRegister16(3, 0x55AA)
                cpu.setRegister8(4, 0x30)
                cpu.setRegister16(1, 0x0001)
                cpu.setFlag(X86CPU.flagCarry, false)
            } else {
                setDiskResult(success: false, status: 0x01)
            }
        case 0x42, 0x43: // LBA 読み取り / 書き込み（アドレスパケット使用）
            let packet = cpu.physicalAddress(segment: cpu.segment(3), offset: UInt32(cpu.register16(6)))
            guard let countValue = try? cpu.readMemory(at: packet + 2, size: 2),
                  let bufferOffset = try? cpu.readMemory(at: packet + 4, size: 2),
                  let bufferSegment = try? cpu.readMemory(at: packet + 6, size: 2),
                  let lbaLow = try? cpu.readMemory(at: packet + 8, size: 4)
            else {
                setDiskResult(success: false, status: 0x01)
                return .handled
            }
            let buffer = cpu.physicalAddress(segment: UInt16(bufferSegment), offset: bufferOffset)
            transfer(lba: Int(lbaLow), count: Int(countValue), buffer: buffer, isWrite: ah == 0x43)
        case 0x48: // 拡張パラメータ取得
            let packet = cpu.physicalAddress(segment: cpu.segment(3), offset: UInt32(cpu.register16(6)))
            let bufferSize = (try? cpu.readMemory(at: packet, size: 2)) ?? 0
            guard bufferSize >= 0x1A else {
                setDiskResult(success: false, status: 0x01)
                return .handled
            }
            let total = diskData.count / diskSectorSize
            let cylinders = max(1, total / (heads * sectorsPerTrack))
            try? cpu.writeMemory(at: packet, size: 2, 0x001A)
            try? cpu.writeMemory(at: packet + 2, size: 2, 0) // 情報フラグ
            try? cpu.writeMemory(at: packet + 4, size: 4, UInt32(cylinders))
            try? cpu.writeMemory(at: packet + 8, size: 4, UInt32(heads))
            try? cpu.writeMemory(at: packet + 12, size: 4, UInt32(sectorsPerTrack))
            try? cpu.writeMemory(at: packet + 16, size: 4, UInt32(total & 0xFFFFFFFF))
            try? cpu.writeMemory(at: packet + 20, size: 4, 0)
            try? cpu.writeMemory(at: packet + 24, size: 2, UInt32(diskSectorSize))
            setDiskResult(success: true, status: 0)
        default:
            setDiskResult(success: false, status: 0x01)
        }
        return .handled
    }

    private func transfer(lba: Int, count: Int, buffer: Int, isWrite: Bool) {
        guard let cpu, count > 0 else {
            setDiskResult(success: false, status: 0x01)
            return
        }
        let byteOffset = lba * diskSectorSize
        let byteCount = count * diskSectorSize
        guard byteOffset >= 0, byteOffset + byteCount <= diskData.count else {
            setDiskResult(success: false, status: 0x04)
            return
        }
        if isWrite {
            guard let box = diskBox else {
                setDiskResult(success: false, status: 0x01)
                return
            }
            var data = box.data
            for i in 0..<byteCount {
                if let byte = try? cpu.readMemory8(at: buffer + i) {
                    data[byteOffset + i] = byte
                }
            }
            box.data = data
        } else {
            for i in 0..<byteCount {
                try? cpu.writeMemory8(at: buffer + i, diskData[byteOffset + i])
            }
        }
        cpu.setRegister8(0, UInt8(count))
        setDiskResult(success: true, status: 0)
    }

    // MARK: - INT 16h: キーボード

    private func handleKeyboard() -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        let ah = cpu.register8(4)
        switch ah {
        case 0x00, 0x10: // キー入力（ブロック）
            guard let byte = cpu.nextInputByte() else { return .needsInput }
            cpu.setRegister8(0, byte)
            cpu.setRegister8(4, Self.scancode(for: byte))
        case 0x01, 0x11: // キー有無の確認
            if let byte = cpu.peekInputByte() {
                cpu.setFlag(X86CPU.flagZero, false)
                cpu.setRegister8(0, byte)
                cpu.setRegister8(4, Self.scancode(for: byte))
            } else {
                cpu.setFlag(X86CPU.flagZero, true)
            }
        case 0x02, 0x12: // シフト状態
            cpu.setRegister8(0, 0)
        default:
            break
        }
        return .handled
    }

    /// ASCII コードから代表的なスキャンコードを返す。
    private static func scancode(for ascii: UInt8) -> UInt8 {
        switch ascii {
        case 0x1B: return 0x01
        case 0x08: return 0x0E
        case 0x09: return 0x0F
        case 0x0D: return 0x1C
        case 0x20: return 0x39
        case 0x30...0x39: return ascii == 0x30 ? 0x0B : (0x02 + (ascii - 0x31))
        default:
            let rows: [(String, UInt8)] = [
                ("qwertyuiop", 0x10),
                ("asdfghjkl", 0x1E),
                ("zxcvbnm", 0x2C),
            ]
            let scalar = UnicodeScalar(ascii)
            let char = Character(scalar).lowercased().first
            if let char {
                for (letters, base) in rows {
                    if let index = letters.firstIndex(of: char) {
                        return base + UInt8(letters.distance(from: letters.startIndex, to: index))
                    }
                }
            }
            return 0x1E
        }
    }

    // MARK: - INT 1Ah: 時刻

    private func handleTimer() -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        let ah = cpu.register8(4)
        let now = Date()
        switch ah {
        case 0x00: // ティック数（18.2 Hz 相当、1 日 = 0x1800B0 で巻き戻る）
            let totalTicks = UInt64(now.timeIntervalSince(startTime) * 18.206)
            let ticks = UInt32(totalTicks % 0x1800B0)
            cpu.setRegister16(1, UInt16(ticks >> 16))
            cpu.setRegister16(2, UInt16(ticks & 0xFFFF))
            let day = totalTicks / 0x1800B0
            cpu.setRegister8(0, day > lastTickDay ? 1 : 0) // 日付変更フラグ
            if day > lastTickDay { lastTickDay = day }
        case 0x02: // 時刻（BCD）
            let components = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
            cpu.setRegister8(5, Self.bcd(components.hour ?? 0))
            cpu.setRegister8(1, Self.bcd(components.minute ?? 0))
            cpu.setRegister8(6, Self.bcd(components.second ?? 0))
            cpu.setRegister8(2, 0)
            cpu.setFlag(X86CPU.flagCarry, false)
        case 0x04: // 日付（BCD）
            let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let year = components.year ?? 2026
            cpu.setRegister8(5, Self.bcd(year / 100))
            cpu.setRegister8(1, Self.bcd(year % 100))
            cpu.setRegister8(6, Self.bcd(components.month ?? 1))
            cpu.setRegister8(2, Self.bcd(components.day ?? 1))
            cpu.setFlag(X86CPU.flagCarry, false)
        default:
            break
        }
        return .handled
    }

    private static func bcd(_ value: Int) -> UInt8 {
        UInt8(((value / 10) << 4) | (value % 10))
    }

    // MARK: - INT 15h: システム

    private func handleSystemServices() -> X86CPU.InterruptOutcome {
        guard let cpu else { return .handled }
        switch cpu.register8(4) {
        case 0x88: // 拡張メモリサイズ（KB、16 MiB 機として報告）
            cpu.setRegister16(0, 15360)
            cpu.setFlag(X86CPU.flagCarry, false)
        case 0x86: // ウェイト（即時復帰）
            cpu.setFlag(X86CPU.flagCarry, false)
        case 0xE8: // メモリマップ取得（E820 / E801）
            if cpu.register32(0) == 0x0000E820 {
                handleE820()
            } else if cpu.register32(0) & 0xFFFF == 0xE801 {
                // 拡張メモリ: AX = 1〜16 MiB の KB 数、BX = 16 MiB 以上の 64 KB 数
                cpu.setRegister16(0, 15360)
                cpu.setRegister16(3, 0)
                cpu.setFlag(X86CPU.flagCarry, false)
            } else {
                cpu.setFlag(X86CPU.flagCarry, true)
                cpu.setRegister8(4, 0x86)
            }
        default:
            cpu.setFlag(X86CPU.flagCarry, true)
            cpu.setRegister8(4, 0x86)
        }
        return .handled
    }

    /// INT 15h AX=E820: メモリマップを 1 件ずつ返す（EBX が継続値）。
    private func handleE820() {
        guard let cpu else { return }
        guard cpu.register32(2) == 0x534D4150 else { // EDX = "SMAP"
            cpu.setFlag(X86CPU.flagCarry, true)
            cpu.setRegister8(4, 0x86)
            return
        }
        let memorySize = UInt64(cpu.memory.count)
        let entries: [(base: UInt64, length: UInt64, type: UInt32)] = [
            (0, 0xA0000, 1), // 通常メモリ
            (0xE0000, 0x20000, 2), // BIOS / ACPI 領域（予約）
            (0x100000, memorySize - 0x100000, 1), // 拡張メモリ
        ]
        let index = Int(cpu.register32(3))
        guard index < entries.count else {
            cpu.setFlag(X86CPU.flagCarry, true)
            cpu.setRegister8(4, 0x86)
            return
        }
        let entry = entries[index]
        let address = cpu.physicalAddress(segment: cpu.segment(0), offset: UInt32(cpu.register16(7)))
        func write64(_ value: UInt64, at offset: Int) {
            for i in 0..<8 {
                try? cpu.writeMemory8(at: address + offset + i, UInt8((value >> (8 * i)) & 0xFF))
            }
        }
        func write32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 {
                try? cpu.writeMemory8(at: address + offset + i, UInt8((value >> (8 * i)) & 0xFF))
            }
        }
        write64(entry.base, at: 0)
        write64(entry.length, at: 8)
        write32(entry.type, at: 16)
        write32(1, at: 20) // ACPI 3.0 拡張属性（有効）
        cpu.setRegister32(0, 0x534D4150)
        cpu.setRegister32(3, index + 1 < entries.count ? UInt32(index + 1) : 0)
        cpu.setRegister32(1, 24)
        cpu.setFlag(X86CPU.flagCarry, false)
    }
}
