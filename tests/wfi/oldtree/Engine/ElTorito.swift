import Foundation

enum ElToritoError: Error, CustomStringConvertible, LocalizedError {
    case notBootable
    case invalidCatalog
    case unsupportedMedia(UInt8)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notBootable:
            return "この ISO は El Torito ブートに対応していません"
        case .invalidCatalog:
            return "El Torito ブートカタログが壊れています"
        case .unsupportedMedia(let media):
            return "未対応の El Torito メディア種別です（\(media)）"
        }
    }
}

/// ISO 9660 の El Torito 拡張（CD/DVD からのブート規格）のパーサ。
///
/// ブートレコードとブートカタログを読み、初期エントリが指す
/// ブートイメージ（フロッピー / ハードディスク エミュレーション）を取り出す。
enum ElTorito {
    enum MediaType: Equatable {
        case noEmulation
        case floppy
        case hardDisk
    }

    /// ブートに必要な一式。
    struct BootImage {
        /// メモリへ読み込むバイト列（ブートセクタ等）
        var bytesToLoad: [UInt8]
        /// 読み込み先の物理アドレス
        var loadAddress: Int
        /// 起動時の CS（IP は 0）
        var entrySegment: UInt16
        /// INT 13h で読み取りを提供するディスク全体
        var diskData: [UInt8]
        /// ディスクのセクタサイズ
        var diskSectorSize: Int
        /// CHS ジオメトリ
        var heads: Int
        var sectorsPerTrack: Int
        /// BIOS が DL に入れるブートドライブ番号
        var bootDrive: UInt8
        var mediaType: MediaType
    }

    /// ISO 9660 のシグネチャ（セクタ 16 の "CD001"）があるか。
    static func isISO9660(_ data: [UInt8]) -> Bool {
        let pvd = 16 * 2048
        guard data.count > pvd + 6, data[pvd] == 1 else { return false }
        return String(bytes: data[(pvd + 1)..<(pvd + 6)], encoding: .ascii) == "CD001"
    }

    static func bootImage(fromISO data: [UInt8]) throws -> BootImage {
        let bootRecord = 17 * 2048
        // 識別文字列は 23 バイトで、残りは 0 パディング（仕様）
        guard data.count > bootRecord + 0x47 + 4,
              data[bootRecord] == 0,
              String(bytes: data[(bootRecord + 1)..<(bootRecord + 6)], encoding: .ascii) == "CD001",
              String(bytes: data[(bootRecord + 7)..<(bootRecord + 30)], encoding: .ascii) == "EL TORITO SPECIFICATION"
        else {
            throw ElToritoError.notBootable
        }
        let catalogLBA = readLE32(data, at: bootRecord + 0x47)
        let catalogOffset = Int(catalogLBA) * 2048
        guard catalogOffset + 64 <= data.count, data[catalogOffset] == 0x01 else {
            throw ElToritoError.invalidCatalog
        }
        // 検証エントリ: 16 ワードの合計が 0、末尾が 55 AA
        var sum: UInt32 = 0
        for i in 0..<16 {
            sum += UInt32(readLE16(data, at: catalogOffset + i * 2))
        }
        guard sum & 0xFFFF == 0,
              data[catalogOffset + 30] == 0x55,
              data[catalogOffset + 31] == 0xAA
        else {
            throw ElToritoError.invalidCatalog
        }
        // 初期エントリ
        let entry = catalogOffset + 32
        guard data[entry] == 0x88 else { throw ElToritoError.notBootable }
        let mediaByte = data[entry + 1]
        let loadSegmentValue = readLE16(data, at: entry + 2)
        let sectorCount = readLE16(data, at: entry + 6)
        let loadLBA = readLE32(data, at: entry + 8)
        let imageStart = Int(loadLBA) * 2048
        let loadSegment: UInt16 = loadSegmentValue == 0 ? 0x07C0 : loadSegmentValue

        switch mediaByte {
        case 1, 2, 3: // フロッピー エミュレーション（1.2M / 1.44M / 2.88M）
            let sizes = [1: 1_228_800, 2: 1_474_560, 3: 2_949_120]
            let spt = [1: 15, 2: 18, 3: 36]
            guard let size = sizes[Int(mediaByte)], imageStart + size <= data.count else {
                throw ElToritoError.invalidCatalog
            }
            let image = Array(data[imageStart..<(imageStart + size)])
            return BootImage(
                bytesToLoad: Array(image.prefix(512)),
                loadAddress: 0x7C00,
                entrySegment: 0x07C0,
                diskData: image,
                diskSectorSize: 512,
                heads: 2,
                sectorsPerTrack: spt[Int(mediaByte)] ?? 18,
                bootDrive: 0x00,
                mediaType: .floppy
            )
        case 4: // ハードディスク エミュレーション
            guard imageStart < data.count else { throw ElToritoError.invalidCatalog }
            let image = Array(data[imageStart...])
            return BootImage(
                bytesToLoad: Array(image.prefix(512)),
                loadAddress: 0x7C00,
                entrySegment: 0x07C0,
                diskData: image,
                diskSectorSize: 512,
                heads: 255,
                sectorsPerTrack: 63,
                bootDrive: 0x80,
                mediaType: .hardDisk
            )
        case 0: // エミュレーションなし: 指定セクタ数をそのまま読み込む
            let count = sectorCount == 0 ? 4 : sectorCount
            let size = Int(count) * 2048
            guard imageStart + size <= data.count else { throw ElToritoError.invalidCatalog }
            return BootImage(
                bytesToLoad: Array(data[imageStart..<(imageStart + size)]),
                loadAddress: Int(loadSegment) * 16,
                entrySegment: loadSegment,
                diskData: data,
                diskSectorSize: 2048,
                heads: 255,
                sectorsPerTrack: 63,
                bootDrive: 0x80,
                mediaType: .noEmulation
            )
        default:
            throw ElToritoError.unsupportedMedia(mediaByte)
        }
    }

    private static func readLE16(_ data: [UInt8], at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLE32(_ data: [UInt8], at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
