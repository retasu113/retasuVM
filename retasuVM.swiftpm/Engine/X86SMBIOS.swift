import Foundation

/// SMBIOS テーブル（バージョン 2.7 形式）の生成。
///
/// エントリポイントを 0xE2000、構造テーブルを 0xE2100 に配置する。
/// macOS のブートローダ (boot.efi) は SMBIOS から機種情報やボード ID を
/// 読むため、システム情報（タイプ 1）は iMac19,1 として提示する。
/// UEFI の構成テーブルにも SMBIOS GUID で登録される。
enum X86SMBIOS {
    static let entryPointAddress = 0xE2000
    static let tableAddress = 0xE2100

    static func install(cpu: X86CPU) {
        let table = buildTable()
        cpu.loadData(table.bytes, at: tableAddress)
        cpu.loadData(buildEntryPoint(structureCount: table.count,
                                     maxStructureSize: table.maxSize,
                                     tableLength: table.bytes.count),
                     at: entryPointAddress)
    }

    // MARK: - 構造テーブル

    private static func buildTable() -> (bytes: [UInt8], count: Int, maxSize: Int) {
        var bytes: [UInt8] = []
        var count = 0
        var maxSize = 0
        func add(_ formatted: [UInt8], _ strings: [String]) {
            var structure = formatted
            if strings.isEmpty {
                structure += [0, 0]
            } else {
                for string in strings {
                    structure += [UInt8](string.utf8) + [0]
                }
                structure.append(0)
            }
            bytes += structure
            count += 1
            maxSize = max(maxSize, structure.count)
        }

        // タイプ 0: BIOS 情報
        var bios = [UInt8](repeating: 0, count: 0x18)
        bios[0] = 0
        bios[1] = 0x18
        bios[4] = 1 // ベンダ文字列
        bios[5] = 2 // バージョン文字列
        bios[6] = 0x00
        bios[7] = 0xE0 // 開始セグメント 0xE000
        bios[8] = 3 // リリース日文字列
        bios[20] = 0 // BIOS メジャーリリース
        bios[21] = 13 // BIOS マイナーリリース
        add(bios, ["retasuVM", "0.13", "11/15/2026"])

        // タイプ 1: システム情報（iMac19,1 として提示）
        var system = [UInt8](repeating: 0, count: 0x1B)
        system[0] = 1
        system[1] = 0x1B
        write16(&system, at: 2, 0x0100)
        system[4] = 1 // 製造元
        system[5] = 2 // 製品名
        system[6] = 3 // バージョン
        system[7] = 4 // シリアル
        let uuid: [UInt8] = [0x78, 0x56, 0x34, 0x12, 0x34, 0x12, 0x78, 0x56,
                             0x9A, 0xBC, 0x52, 0x45, 0x54, 0x41, 0x53, 0x55]
        system.replaceSubrange(8..<24, with: uuid)
        system[24] = 6 // ウェイクアップ種別: 電源スイッチ
        system[25] = 5 // SKU
        system[26] = 6 // ファミリ
        add(system, ["Apple Inc.", "iMac19,1", "1.0", "RETASUVM000001", "iMac", "iMac"])

        // タイプ 2: ベースボード情報
        var board = [UInt8](repeating: 0, count: 0x0F)
        board[0] = 2
        board[1] = 0x0F
        write16(&board, at: 2, 0x0200)
        board[4] = 1
        board[5] = 2 // ボード ID
        board[6] = 3
        board[7] = 4
        board[9] = 0x01 // ホスティングボード
        write16(&board, at: 11, 0x0300) // シャーシハンドル
        board[13] = 10 // マザーボード
        add(board, ["Apple Inc.", "Mac-AA95B1DDAB278B95", "1.0", "RETASUBOARD001"])

        // タイプ 3: シャーシ情報
        var chassis = [UInt8](repeating: 0, count: 0x15)
        chassis[0] = 3
        chassis[1] = 0x15
        write16(&chassis, at: 2, 0x0300)
        chassis[4] = 1
        chassis[5] = 13 // オールインワン
        chassis[6] = 2
        chassis[7] = 3
        chassis[9] = 3 // 起動時状態: 安全
        chassis[10] = 3 // 電源状態: 安全
        chassis[11] = 3 // 熱状態: 安全
        chassis[12] = 3 // セキュリティ状態: 安全
        chassis[18] = 1 // 電源コード数
        add(chassis, ["Apple Inc.", "1.0", "RETASUCHASSIS1"])

        // タイプ 4: プロセッサ情報
        var processor = [UInt8](repeating: 0, count: 0x2A)
        processor[0] = 4
        processor[1] = 0x2A
        write16(&processor, at: 2, 0x0400)
        processor[4] = 1 // ソケット
        processor[5] = 3 // 中央プロセッサ
        processor[6] = 0xFE // ファミリ 2 を使用
        processor[7] = 2 // 製造元
        write64(&processor, at: 8, 0x00000000000806EA) // CPUID 署名
        processor[16] = 3 // バージョン
        write16(&processor, at: 18, 100) // 外部クロック MHz
        write16(&processor, at: 20, 2300) // 最大速度 MHz
        write16(&processor, at: 22, 2300) // 現在速度 MHz
        processor[24] = 0x41 // 装着済み + 有効
        processor[25] = 1 // アップグレード: その他
        write16(&processor, at: 26, 0xFFFF)   // L1 キャッシュハンドル（なし）
        write16(&processor, at: 28, 0xFFFF)   // L2 キャッシュハンドル（なし）
        write16(&processor, at: 30, 0xFFFF)   // L3 キャッシュハンドル（なし）
        write16(&processor, at: 0x28, 0x00C6) // ファミリ 2（オフセット 0x28）
        processor[35] = 1 // コア数
        processor[36] = 1 // 有効コア数
        processor[37] = 1 // スレッド数
        write16(&processor, at: 38, 0x0004) // 64 ビット対応
        add(processor, ["CPU", "Intel", "Intel(R) Core(TM) i5-8259U CPU @ 2.30GHz"])

        // タイプ 17: メモリデバイス（VM の実メモリ 16 MB）
        var memory = [UInt8](repeating: 0, count: 0x1B)
        memory[0] = 17
        memory[1] = 0x1B
        write16(&memory, at: 2, 0x1100)
        write16(&memory, at: 4, 0xFFFF)
        write16(&memory, at: 6, 0xFFFF)
        write16(&memory, at: 8, 64) // 合計幅
        write16(&memory, at: 10, 64) // データ幅
        write16(&memory, at: 12, 16) // サイズ: 16 MB
        memory[14] = 8 // DIMM
        memory[16] = 1 // デバイスロケータ
        memory[17] = 2 // バンクロケータ
        memory[18] = 26 // DDR4
        write16(&memory, at: 19, 0x0080) // 同期
        write16(&memory, at: 21, 2400) // 速度 MT/s
        memory[23] = 3 // 製造元
        memory[24] = 4 // シリアル
        memory[26] = 5 // 型番
        add(memory, ["DIMM0", "BANK0", "retasuVM", "00000001", "VMRAM16"])

        // タイプ 127: 終端
        var end = [UInt8](repeating: 0, count: 4)
        end[0] = 127
        end[1] = 4
        add(end, [])

        return (bytes, count, maxSize)
    }

    // MARK: - エントリポイント

    private static func buildEntryPoint(structureCount: Int, maxStructureSize: Int, tableLength: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 31)
        bytes.replaceSubrange(0..<4, with: [UInt8]("_SM_".utf8))
        bytes[5] = 0x1F // エントリポイント長
        bytes[6] = 2 // メジャー
        bytes[7] = 7 // マイナー
        write16(&bytes, at: 8, UInt16(maxStructureSize))
        bytes.replaceSubrange(16..<21, with: [UInt8]("_DMI_".utf8))
        write16(&bytes, at: 22, UInt16(tableLength))
        write32(&bytes, at: 24, UInt32(tableAddress))
        write16(&bytes, at: 28, UInt16(structureCount))
        bytes[30] = 0x27 // BCD リビジョン (2.7)
        bytes[21] = checksum(bytes, range: 16..<31, excluding: 21)
        bytes[4] = checksum(bytes, range: 0..<31, excluding: 4)
        return bytes
    }

    // MARK: - 共通

    private static func checksum(_ bytes: [UInt8], range: Range<Int>, excluding index: Int) -> UInt8 {
        var sum = 0
        for i in range where i != index {
            sum += Int(bytes[i])
        }
        return UInt8((256 - (sum % 256)) % 256)
    }

    private static func write16(_ bytes: inout [UInt8], at offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func write32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static func write64(_ bytes: inout [UInt8], at offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
}
