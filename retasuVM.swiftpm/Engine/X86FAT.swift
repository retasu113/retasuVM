import Foundation

/// FAT12 / FAT16 / FAT32 ボリューム（UEFI の Simple File System 用）。
///
/// 読み取り（BPB 解析、LFN を含むディレクトリ列挙、クラスタチェーン
/// 読み出し）と、基本的な書き込み（ファイル作成 / 置換 / 削除、
/// クラスタ割り当て、全 FAT コピーへの反映）を提供する。
/// データは共有ストレージ（`Storage`）越しに読み書きするため、
/// Block I/O と同じ内容を参照できる。
final class FATVolume {
    /// 共有ストレージ。Block I/O と同じバイト列を指す。
    final class Storage {
        var data: [UInt8]
        init(_ data: [UInt8]) { self.data = data }
    }

    struct Entry {
        /// 表示名（LFN があれば LFN、なければ 8.3 形式）。
        var name: String
        /// 8.3 形式の生バイト（11 バイト）。
        var shortName: [UInt8]
        var isDirectory: Bool
        var isVolumeLabel: Bool
        var firstCluster: Int
        var size: Int
    }

    enum FATError: Error {
        case notFAT
        case notFound
        case directoryFull
        case diskFull
        case isDirectory
    }

    let storage: Storage
    let bytesPerSector: Int
    let sectorsPerCluster: Int
    let fatStart: Int        // バイトオフセット
    let fatCount: Int
    let sectorsPerFAT: Int
    let rootEntryCount: Int  // FAT32 では 0
    let rootStart: Int       // FAT12/16 のルート領域（バイト）
    let dataStart: Int       // データ領域（バイト）
    let totalClusters: Int
    let rootCluster: Int     // FAT32 のルートクラスタ
    let volumeLabelText: String

    var clusterBytes: Int { bytesPerSector * sectorsPerCluster }
    var totalBytes: Int { storage.data.count }
    var isFAT32: Bool { rootEntryCount == 0 }

    init(storage: Storage) throws {
        self.storage = storage
        let d = storage.data
        guard d.count >= 512, d[510] == 0x55, d[511] == 0xAA else { throw FATError.notFAT }
        func u16(_ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }
        let bps = u16(11)
        guard bps == 512 || bps == 1024 || bps == 2048 || bps == 4096 else { throw FATError.notFAT }
        bytesPerSector = bps
        sectorsPerCluster = max(1, Int(d[13]))
        let reserved = u16(14)
        fatCount = max(1, Int(d[16]))
        rootEntryCount = u16(17)
        var total = u16(19)
        if total == 0 { total = u32(32) }
        var spf = u16(22)
        rootCluster = u32(44)
        if spf == 0 { spf = u32(36) }
        sectorsPerFAT = spf
        guard total > 0, spf > 0 else { throw FATError.notFAT }
        fatStart = reserved * bps
        rootStart = fatStart + fatCount * spf * bps
        let rootBytes = rootEntryCount * 32
        dataStart = rootStart + rootBytes
        let dataSectors = total - (dataStart / bps)
        totalClusters = dataSectors / sectorsPerCluster + 2
        // ボリュームラベル（BPB の拡張領域）
        let labelOffset = rootEntryCount == 0 ? 71 : 43
        var label = ""
        if labelOffset + 11 <= d.count {
            label = String(bytes: d[labelOffset..<(labelOffset + 11)], encoding: .ascii) ?? ""
            label = label.trimmingCharacters(in: .whitespaces)
        }
        volumeLabelText = label.isEmpty ? "NO NAME" : label
    }

    // MARK: - FAT アクセス

    private func fatEntryOffset(_ cluster: Int) -> Int {
        switch fatKind {
        case .fat12: return fatStart + cluster + cluster / 2
        case .fat16: return fatStart + cluster * 2
        case .fat32: return fatStart + cluster * 4
        }
    }

    private enum FATKind { case fat12, fat16, fat32 }
    private var fatKind: FATKind {
        if totalClusters < 4085 { return .fat12 }
        if totalClusters < 65525 { return .fat16 }
        return .fat32
    }

    private var endOfChain: Int {
        switch fatKind {
        case .fat12: return 0xFF8
        case .fat16: return 0xFFF8
        case .fat32: return 0x0FFFFFF8
        }
    }

    private var eocValue: Int {
        switch fatKind {
        case .fat12: return 0xFFF
        case .fat16: return 0xFFFF
        case .fat32: return 0x0FFFFFFF
        }
    }

    func fatEntry(_ cluster: Int) -> Int {
        let d = storage.data
        switch fatKind {
        case .fat12:
            let offset = fatEntryOffset(cluster)
            guard offset + 1 < d.count else { return eocValue }
            let value = Int(d[offset]) | (Int(d[offset + 1]) << 8)
            return cluster & 1 == 0 ? (value & 0xFFF) : (value >> 4)
        case .fat16:
            let offset = fatEntryOffset(cluster)
            guard offset + 1 < d.count else { return eocValue }
            return Int(d[offset]) | (Int(d[offset + 1]) << 8)
        case .fat32:
            let offset = fatEntryOffset(cluster)
            guard offset + 3 < d.count else { return eocValue }
            var value = 0
            for i in 0..<4 { value |= Int(d[offset + i]) << (8 * i) }
            return value & 0x0FFFFFFF
        }
    }

    private func setFATEntry(_ cluster: Int, _ newValue: Int) {
        // 全 FAT コピーへ反映する
        for copy in 0..<fatCount {
            let copyBase = fatStart + copy * sectorsPerFAT * bytesPerSector
            switch fatKind {
            case .fat12:
                let offset = copyBase + cluster + cluster / 2
                guard offset + 1 < storage.data.count else { continue }
                let old = Int(storage.data[offset]) | (Int(storage.data[offset + 1]) << 8)
                let merged = cluster & 1 == 0
                    ? (old & 0xF000) | (newValue & 0xFFF)
                    : (old & 0x000F) | ((newValue & 0xFFF) << 4)
                storage.data[offset] = UInt8(merged & 0xFF)
                storage.data[offset + 1] = UInt8((merged >> 8) & 0xFF)
            case .fat16:
                let offset = copyBase + cluster * 2
                guard offset + 1 < storage.data.count else { continue }
                storage.data[offset] = UInt8(newValue & 0xFF)
                storage.data[offset + 1] = UInt8((newValue >> 8) & 0xFF)
            case .fat32:
                let offset = copyBase + cluster * 4
                guard offset + 3 < storage.data.count else { continue }
                let old = (0..<4).reduce(0) { $0 | (Int(storage.data[offset + $1]) << (8 * $1)) }
                let merged = (old & 0xF0000000) | (newValue & 0x0FFFFFFF)
                for i in 0..<4 { storage.data[offset + i] = UInt8((merged >> (8 * i)) & 0xFF) }
            }
        }
    }

    /// クラスタチェーンをたどる（最大長で保護）。
    func clusterChain(_ start: Int) -> [Int] {
        var chain: [Int] = []
        var cluster = start
        while cluster >= 2, cluster < endOfChain, chain.count < totalClusters {
            chain.append(cluster)
            cluster = fatEntry(cluster)
        }
        return chain
    }

    private func clusterOffset(_ cluster: Int) -> Int {
        dataStart + (cluster - 2) * clusterBytes
    }

    /// クラスタチェーン全体のバイト列を読む。
    func readChain(_ start: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for cluster in clusterChain(start) {
            let offset = clusterOffset(cluster)
            guard offset < storage.data.count else { break }
            let end = min(offset + clusterBytes, storage.data.count)
            bytes += storage.data[offset..<end]
        }
        return bytes
    }

    // MARK: - ディレクトリ

    /// ディレクトリの生バイト列（ルートまたはサブディレクトリ）。
    private func directoryBytes(cluster: Int) -> (bytes: [UInt8], isRootRegion: Bool) {
        if cluster == 0 {
            if isFAT32 {
                return (readChain(rootCluster), false)
            }
            let end = min(rootStart + rootEntryCount * 32, storage.data.count)
            return ([UInt8](storage.data[rootStart..<end]), true)
        }
        return (readChain(cluster), false)
    }

    /// ディレクトリエントリを列挙する（LFN を合成する）。
    func listDirectory(cluster: Int) -> [Entry] {
        let (bytes, _) = directoryBytes(cluster: cluster)
        var entries: [Entry] = []
        var longName: String?
        var index = 0
        while index + 32 <= bytes.count {
            let entry = [UInt8](bytes[index..<(index + 32)])
            let first = entry[0]
            if first == 0x00 { break }
            if first == 0xE5 { longName = nil; index += 32; continue }
            let attributes = entry[11]
            if attributes == 0x0F {
                // LFN エントリ: シーケンス番号の下位で位置を決める
                let sequence = Int(entry[0] & 0x1F)
                var chars: [UInt16] = []
                for range in [(1, 11), (14, 26), (28, 32)] {
                    var offset = range.0
                    while offset < range.1 {
                        chars.append(UInt16(entry[offset]) | (UInt16(entry[offset + 1]) << 8))
                        offset += 2
                    }
                }
                var piece = ""
                for unit in chars {
                    if unit == 0 { break }
                    if unit != 0xFFFF, let scalar = UnicodeScalar(unit) {
                        piece.append(Character(scalar))
                    }
                }
                if sequence >= 1 {
                    if longName == nil || entry[0] & 0x40 != 0 {
                        longName = piece
                    } else {
                        longName = piece + (longName ?? "")
                    }
                }
                index += 32
                continue
            }
            let shortName = [UInt8](entry[0..<11])
            let display = longName ?? Self.displayName(shortName: shortName)
            let cluster = Int(entry[26]) | (Int(entry[27]) << 8) | (isFAT32 ? (Int(entry[20]) | (Int(entry[21]) << 8)) << 16 : 0)
            let size = (0..<4).reduce(0) { $0 | (Int(entry[28 + $1]) << (8 * $1)) }
            entries.append(Entry(
                name: display,
                shortName: shortName,
                isDirectory: attributes & 0x10 != 0,
                isVolumeLabel: attributes & 0x08 != 0,
                firstCluster: cluster,
                size: size
            ))
            longName = nil
            index += 32
        }
        return entries
    }

    /// 8.3 生バイトから表示名（NAME.EXT）を作る。
    static func displayName(shortName: [UInt8]) -> String {
        func part(_ range: Range<Int>) -> String {
            var text = String(bytes: shortName[range], encoding: .ascii) ?? ""
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
        let base = part(0..<8)
        let ext = part(8..<11)
        return ext.isEmpty ? base : base + "." + ext
    }

    /// 名前から 8.3 生バイトを作る（大文字化、無効文字は除去）。
    static func shortNameBytes(for name: String) -> [UInt8] {
        let upper = name.uppercased()
        let parts = upper.split(separator: ".", omittingEmptySubsequences: false)
        func clean(_ text: Substring, _ length: Int) -> String {
            var result = ""
            for character in text {
                if character.isLetter || character.isNumber || "_-$#@!%(){}".contains(character) {
                    result.append(character)
                }
                if result.count >= length { break }
            }
            while result.count < length { result.append(" ") }
            return result
        }
        let base = clean(parts.first ?? "", 8)
        let ext = parts.count > 1 ? clean(parts[1], 3) : "   "
        return [UInt8]((base + ext).utf8)
    }

    /// パス要素でエントリを探す（大文字小文字を区別しない）。
    func findEntry(directoryCluster: Int, name: String) -> Entry? {
        let target = name.uppercased()
        return listDirectory(cluster: directoryCluster).first {
            !$0.isVolumeLabel && $0.name.uppercased() == target
        }
    }

    /// パス（要素列）をたどってエントリを返す。空ならルート。
    func resolve(path: [String]) -> Entry? {
        var current = Entry(name: "\\", shortName: [UInt8](repeating: 0x20, count: 11),
                            isDirectory: true, isVolumeLabel: false,
                            firstCluster: isFAT32 ? rootCluster : 0, size: 0)
        for component in path {
            guard current.isDirectory else { return nil }
            let cluster = current.firstCluster
            guard let next = findEntry(directoryCluster: cluster, name: component) else { return nil }
            current = next
        }
        return current
    }

    /// ファイル内容を読む。
    func readFile(_ entry: Entry) -> [UInt8] {
        guard entry.size > 0, entry.firstCluster >= 2 else { return [] }
        let bytes = readChain(entry.firstCluster)
        return [UInt8](bytes.prefix(entry.size))
    }

    // MARK: - 書き込み

    /// 空きクラスタを 1 つ割り当てる。
    private func allocateCluster() -> Int? {
        for cluster in 2..<(totalClusters + 2) {
            if fatEntry(cluster) == 0 { return cluster }
        }
        return nil
    }

    private func freeChain(_ start: Int) {
        for cluster in clusterChain(start) {
            setFATEntry(cluster, 0)
        }
    }

    /// ディレクトリ領域へ 32 バイトエントリを書く位置を探し、書き込む。
    /// 戻り値: 書き込めたかどうか。
    private func writeDirectoryEntry(directoryCluster: Int, shortName: [UInt8], make: ([UInt8]) -> [UInt8]) throws {
        if directoryCluster == 0, !isFAT32 {
            // ルート領域（固定長）: 空きスロットを探す
            var offset = rootStart
            let end = rootStart + rootEntryCount * 32
            var target: Int?
            while offset + 32 <= end, offset + 32 <= storage.data.count {
                let first = storage.data[offset]
                let existing = [UInt8](storage.data[offset..<(offset + 11)])
                if existing == shortName, storage.data[offset + 11] != 0x0F {
                    target = offset
                    break
                }
                if (first == 0x00 || first == 0xE5), target == nil { target = offset }
                if first == 0x00 { break }
                offset += 32
            }
            guard let slot = target else { throw FATError.directoryFull }
            let entry = make([UInt8](storage.data[slot..<(slot + 32)]))
            storage.data.replaceSubrange(slot..<(slot + 32), with: entry)
            return
        }
        // クラスタチェーン上のディレクトリ
        let chain = clusterChain(directoryCluster == 0 ? rootCluster : directoryCluster)
        for cluster in chain {
            let base = clusterOffset(cluster)
            var offset = base
            while offset + 32 <= base + clusterBytes, offset + 32 <= storage.data.count {
                let first = storage.data[offset]
                let existing = [UInt8](storage.data[offset..<(offset + 11)])
                if existing == shortName, storage.data[offset + 11] != 0x0F {
                    let entry = make([UInt8](storage.data[offset..<(offset + 32)]))
                    storage.data.replaceSubrange(offset..<(offset + 32), with: entry)
                    return
                }
                if first == 0x00 || first == 0xE5 {
                    let entry = make([UInt8](repeating: 0, count: 32))
                    storage.data.replaceSubrange(offset..<(offset + 32), with: entry)
                    return
                }
                offset += 32
            }
        }
        throw FATError.directoryFull
    }

    /// ファイルを作成 / 置換する（ディレクトリはパス要素列、名前は最終要素）。
    func writeFile(directoryPath: [String], name: String, contents: [UInt8]) throws {
        var directoryCluster = isFAT32 ? rootCluster : 0
        if !directoryPath.isEmpty {
            guard let directory = resolve(path: directoryPath), directory.isDirectory else {
                throw FATError.notFound
            }
            directoryCluster = directory.firstCluster
        }
        let shortName = Self.shortNameBytes(for: name)
        // 既存エントリがあればチェーンを解放する
        if let existing = findEntry(directoryCluster: directoryCluster, name: name), !existing.isDirectory {
            freeChain(existing.firstCluster)
        }
        // クラスタチェーンを割り当てて内容を書く
        var firstCluster = 0
        if !contents.isEmpty {
            let needed = (contents.count + clusterBytes - 1) / clusterBytes
            var clusters: [Int] = []
            for _ in 0..<needed {
                guard let cluster = allocateCluster() else { throw FATError.diskFull }
                clusters.append(cluster)
                setFATEntry(cluster, eocValue) // 仮に終端を書いてから連結する
            }
            for index in clusters.indices {
                let next = index + 1 < clusters.count ? clusters[index + 1] : eocValue
                setFATEntry(clusters[index], next)
                let offset = clusterOffset(clusters[index])
                let start = index * clusterBytes
                let chunk = contents[start..<min(start + clusterBytes, contents.count)]
                var padded = [UInt8](chunk)
                while padded.count < clusterBytes { padded.append(0) }
                guard offset + clusterBytes <= storage.data.count else { throw FATError.diskFull }
                storage.data.replaceSubrange(offset..<(offset + clusterBytes), with: padded)
            }
            firstCluster = clusters.first ?? 0
        }
        // ディレクトリエントリを書く
        try writeDirectoryEntry(directoryCluster: directoryCluster, shortName: shortName) { _ in
            var entry = [UInt8](repeating: 0, count: 32)
            entry.replaceSubrange(0..<11, with: shortName)
            entry[11] = 0x20 // アーカイブ
            entry[26] = UInt8(firstCluster & 0xFF)
            entry[27] = UInt8((firstCluster >> 8) & 0xFF)
            if isFAT32 {
                entry[20] = UInt8((firstCluster >> 16) & 0xFF)
                entry[21] = UInt8((firstCluster >> 24) & 0xFF)
            }
            for i in 0..<4 { entry[28 + i] = UInt8((contents.count >> (8 * i)) & 0xFF) }
            return entry
        }
    }

    /// ファイルを削除する。
    func deleteFile(directoryPath: [String], name: String) throws {
        var directoryCluster = isFAT32 ? rootCluster : 0
        if !directoryPath.isEmpty {
            guard let directory = resolve(path: directoryPath), directory.isDirectory else {
                throw FATError.notFound
            }
            directoryCluster = directory.firstCluster
        }
        guard let existing = findEntry(directoryCluster: directoryCluster, name: name) else {
            throw FATError.notFound
        }
        if existing.isDirectory { throw FATError.isDirectory }
        freeChain(existing.firstCluster)
        let shortName = existing.shortName
        try writeDirectoryEntry(directoryCluster: directoryCluster, shortName: shortName) { entry in
            var entry = entry
            entry[0] = 0xE5
            return entry
        }
    }

    /// 使用中バイト数の概算（空き容量計算用）。
    var usedBytes: Int {
        var used = 0
        for cluster in 2..<(totalClusters + 2) where fatEntry(cluster) != 0 {
            used += clusterBytes
        }
        return dataStart + used
    }

    // MARK: - フォーマット

    /// 空の FAT12 フロッピー（1.44 MB）イメージを作る。
    static func formattedFloppy() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 2880 * 512)
        // ブートセクタ + BPB
        data[0] = 0xEB; data[1] = 0x3C; data[2] = 0x90
        let oem = "RETASUVM"
        for (index, byte) in oem.utf8.enumerated() { data[3 + index] = byte }
        func put16(_ offset: Int, _ value: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put32(_ offset: Int, _ value: Int) {
            put16(offset, value & 0xFFFF)
            put16(offset + 2, (value >> 16) & 0xFFFF)
        }
        put16(11, 512)       // バイト / セクタ
        data[13] = 1         // セクタ / クラスタ
        put16(14, 1)         // 予約セクタ
        data[16] = 2         // FAT 数
        put16(17, 224)       // ルートエントリ数
        put16(19, 2880)      // 総セクタ数
        data[21] = 0xF0      // メディア
        put16(22, 9)         // セクタ / FAT
        put16(24, 18)        // セクタ / トラック
        put16(26, 2)         // ヘッド数
        data[38] = 0x29      // 拡張ブート署名
        put32(39, 0x20251115)
        let label = "RETASUVM   "
        for (index, byte) in label.utf8.enumerated() { data[43 + index] = byte }
        let fsType = "FAT12   "
        for (index, byte) in fsType.utf8.enumerated() { data[54 + index] = byte }
        data[510] = 0x55; data[511] = 0xAA
        // FAT（2 コピー）: 先頭エントリ
        for copy in 0..<2 {
            let base = 512 + copy * 9 * 512
            data[base] = 0xF0
            data[base + 1] = 0xFF
            data[base + 2] = 0xFF
        }
        // ルートにボリュームラベルエントリ
        let rootStart = 512 + 2 * 9 * 512
        for (index, byte) in label.utf8.enumerated() { data[rootStart + index] = byte }
        data[rootStart + 11] = 0x08
        return data
    }
}
