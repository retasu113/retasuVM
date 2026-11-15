import Foundation

enum ISO9660Error: Error, CustomStringConvertible, LocalizedError {
    case notISO9660
    case truncated
    case missingBootBinary
    case storageUnavailable

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notISO9660:
            return "ISO 9660 形式ではありません（CD001 シグネチャが見つかりません）"
        case .truncated:
            return "ISO ファイルが小さすぎます（途中で切れている可能性があります）"
        case .missingBootBinary:
            return "ISO 内に BOOT.BIN がありません（retasuVM 形式の ISO が必要です）"
        case .storageUnavailable:
            return "ISO の保存先を用意できませんでした"
        }
    }
}

/// ISO 9660 イメージの最小パーサ。
///
/// Primary Volume Descriptor とルートディレクトリを読み、
/// ファイル名（大文字小文字・`;1` のバージョン接尾辞を無視）で
/// ファイルを取り出せる。retasuVM のブート規約では、ルート直下の
/// `BOOT.BIN`（RISC-V フラットバイナリ）を起動プログラムとして使う。
struct ISO9660Image {
    struct Entry {
        let name: String
        let extentLBA: UInt32
        let size: UInt32
        let isDirectory: Bool
    }

    let data: [UInt8]
    /// ボリュームラベル（末尾の空白は除去）
    let volumeLabel: String
    /// ルートディレクトリのエントリ（"." と ".." は除く）
    let rootEntries: [Entry]

    static let sectorSize = 2048

    init(data: [UInt8]) throws {
        self.data = data
        let pvdOffset = 16 * Self.sectorSize
        guard data.count > pvdOffset + Self.sectorSize else {
            throw ISO9660Error.truncated
        }
        guard data[pvdOffset] == 1,
              String(bytes: data[(pvdOffset + 1)..<(pvdOffset + 6)], encoding: .ascii) == "CD001" else {
            throw ISO9660Error.notISO9660
        }
        let labelBytes = data[(pvdOffset + 40)..<(pvdOffset + 72)]
        volumeLabel = String(bytes: labelBytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0")) ?? ""

        let rootRecordOffset = pvdOffset + 156
        let rootLBA = try Self.readLE32(data, at: rootRecordOffset + 2)
        let rootSize = try Self.readLE32(data, at: rootRecordOffset + 10)
        rootEntries = try Self.parseDirectory(data: data, extentLBA: rootLBA, size: rootSize)
    }

    /// ルート直下のファイルを名前で探して中身を返す。無ければ nil。
    func file(named name: String) -> [UInt8]? {
        let target = Self.normalize(name)
        guard let entry = rootEntries.first(where: {
            !$0.isDirectory && Self.normalize($0.name) == target
        }) else {
            return nil
        }
        let start = Int(entry.extentLBA) * Self.sectorSize
        let end = start + Int(entry.size)
        guard start >= 0, end <= data.count else { return nil }
        return Array(data[start..<end])
    }

    /// ファイル名の正規化: 大文字化し、`;1` のようなバージョン接尾辞を落とす。
    private static func normalize(_ name: String) -> String {
        let base = name.split(separator: ";").first.map(String.init) ?? name
        return base.uppercased()
    }

    private static func readLE32(_ data: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ISO9660Error.truncated }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func parseDirectory(data: [UInt8], extentLBA: UInt32, size: UInt32) throws -> [Entry] {
        let start = Int(extentLBA) * sectorSize
        let end = start + Int(size)
        guard end <= data.count else { throw ISO9660Error.truncated }

        var entries: [Entry] = []
        var offset = start
        while offset < end {
            let recordLength = Int(data[offset])
            if recordLength == 0 {
                // セクタ内の残りはパディング。次のセクタ境界へ進む。
                offset = ((offset / sectorSize) + 1) * sectorSize
                continue
            }
            guard offset + recordLength <= end, recordLength >= 34 else { break }
            let nameLength = Int(data[offset + 32])
            guard 33 + nameLength <= recordLength else { break }
            let nameBytes = data[(offset + 33)..<(offset + 33 + nameLength)]
            let extent = try readLE32(data, at: offset + 2)
            let entrySize = try readLE32(data, at: offset + 10)
            let flags = data[offset + 25]
            // 特殊エントリ "."(0x00) と ".."(0x01) はスキップ
            if !(nameLength == 1 && (nameBytes.first == 0 || nameBytes.first == 1)) {
                let name = String(bytes: nameBytes, encoding: .ascii) ?? ""
                entries.append(Entry(
                    name: name,
                    extentLBA: extent,
                    size: entrySize,
                    isDirectory: flags & 0x02 != 0
                ))
            }
            offset += recordLength
        }
        return entries
    }
}
