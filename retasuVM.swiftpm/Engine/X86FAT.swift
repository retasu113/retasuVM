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
    /// データ領域の実クラスタ数（FAT 種別判定と走査範囲に使う）。
    let dataClusterCount: Int
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
        guard reserved > 0, d[13] > 0, Int(d[13]) & (Int(d[13]) - 1) == 0 else { throw FATError.notFAT }
        fatStart = reserved * bps
        rootStart = fatStart + fatCount * spf * bps
        let rootBytes = rootEntryCount * 32
        dataStart = rootStart + rootBytes
        let dataSectors = total - (dataStart / bps)
        guard dataSectors > 0, dataStart <= d.count else { throw FATError.notFAT }
        dataClusterCount = dataSectors / sectorsPerCluster
        totalClusters = dataClusterCount + 2
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
        if dataClusterCount < 4085 { return .fat12 }
        if dataClusterCount < 65525 { return .fat16 }
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
        while cluster >= 2, cluster < endOfChain - 1, chain.count < totalClusters {
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
            let start = min(rootStart, end)
            return ([UInt8](storage.data[start..<end]), true)
        }
        return (readChain(cluster), false)
    }

    /// ディレクトリエントリを列挙する（LFN を合成する）。
    func listDirectory(cluster: Int) -> [Entry] {
        let (bytes, _) = directoryBytes(cluster: cluster)
        var entries: [Entry] = []
        var longName: String?
        var longNameChecksum: UInt8?
        var longNameBroken = false
        var index = 0
        while index + 32 <= bytes.count {
            let entry = [UInt8](bytes[index..<(index + 32)])
            let first = entry[0]
            if first == 0x00 { break }
            if first == 0xE5 { longName = nil; longNameChecksum = nil; longNameBroken = false; index += 32; continue }
            let attributes = entry[11]
            if attributes == 0x0F {
                // LFN のチェックサムが SFN と一致しなければ採用しない
                if longNameBroken { index += 32; continue }
                if let expected = longNameChecksum, entry[13] != expected {
                    longName = nil
                    longNameBroken = true
                    index += 32
                    continue
                }
                longNameChecksum = entry[13]
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
            let display: String
            if let longName, let checksum = longNameChecksum, checksum == Self.shortNameChecksum(shortName) {
                display = longName
            } else {
                display = Self.displayName(shortName: shortName)
            }
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
            longNameChecksum = nil
            longNameBroken = false
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

    /// 名前から 8.3 生バイトを作る。最初のドットで分割し、無効文字と
    /// 非 ASCII は '_' に置換する。必ず 11 バイトちょうどを返す。
    static func shortNameBytes(for name: String) -> [UInt8] {
        let upper = name.uppercased()
        let dot = upper.firstIndex(of: ".")
        let basePart: Substring = dot.map { upper[..<$0] } ?? Substring(upper)
        let extPart: Substring = dot.map { upper[upper.index(after: $0)...] } ?? ""
        func clean(_ text: Substring, _ length: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            for character in text {
                if bytes.count >= length { break }
                if let ascii = character.asciiValue, isValidShortNameByte(ascii) {
                    bytes.append(ascii)
                } else {
                    bytes.append(0x5F) // '_'
                }
            }
            while bytes.count < length { bytes.append(0x20) }
            return bytes
        }
        return clean(basePart, 8) + clean(extPart, 3)
    }

    /// 8.3 ファイル名に使えるバイトかどうか。
    static func isValidShortNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A: // 0-9, A-Z
            return true
        default:
            return "$%'-_@~`!(){}^#&".utf8.contains(byte)
        }
    }

    /// LFN エントリ用の SFN チェックサム。
    static func shortNameChecksum(_ shortName: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in shortName {
            sum = ((sum & 1) << 7) | (sum >> 1)
            sum = sum &+ byte
        }
        return sum
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
        for cluster in 2..<(dataClusterCount + 2) {
            if fatEntry(cluster) == 0 { return cluster }
        }
        return nil
    }

    private func freeChain(_ start: Int) {
        for cluster in clusterChain(start) {
            setFATEntry(cluster, 0)
        }
    }

    /// ディレクトリ内の全スロットのストレージオフセット（列挙順）。
    private func directorySlotOffsets(directoryCluster: Int) -> [Int] {
        if directoryCluster == 0, !isFAT32 {
            return (0..<rootEntryCount)
                .map { rootStart + $0 * 32 }
                .filter { $0 + 32 <= storage.data.count }
        }
        let chain = clusterChain(directoryCluster == 0 ? rootCluster : directoryCluster)
        var offsets: [Int] = []
        for cluster in chain {
            let base = clusterOffset(cluster)
            var offset = base
            while offset + 32 <= base + clusterBytes, offset + 32 <= storage.data.count {
                offsets.append(offset)
                offset += 32
            }
        }
        return offsets
    }

    /// SFN エントリと、その直前に連なる LFN エントリ群を削除済みに
    /// する。見つからなければ何もしない。
    private func markEntryDeleted(directoryCluster: Int, shortName: [UInt8]) {
        let slots = directorySlotOffsets(directoryCluster: directoryCluster)
        var longNameRun: [Int] = []
        for offset in slots {
            let first = storage.data[offset]
            if first == 0x00 { break }
            if first == 0xE5 { longNameRun = []; continue }
            if storage.data[offset + 11] == 0x0F { longNameRun.append(offset); continue }
            let existing = [UInt8](storage.data[offset..<(offset + 11)])
            if existing == shortName {
                for runOffset in longNameRun { storage.data[runOffset] = 0xE5 }
                storage.data[offset] = 0xE5
                return
            }
            longNameRun = []
        }
    }

    /// 連続した空きスロット（0x00 / 0xE5）の開始インデックスを探す。
    private func freeRunStart(slots: [Int], needed: Int) -> Int? {
        var run = 0
        var start = 0
        for (index, offset) in slots.enumerated() {
            let first = storage.data[offset]
            if first == 0x00 || first == 0xE5 {
                if run == 0 { start = index }
                run += 1
                if run >= needed { return start }
            } else {
                run = 0
            }
        }
        return nil
    }

    /// チェーン型ディレクトリの末尾に空クラスタを 1 つ連結する。
    private func extendDirectory(directoryCluster: Int) -> Bool {
        if directoryCluster == 0, !isFAT32 { return false }
        let chain = clusterChain(directoryCluster == 0 ? rootCluster : directoryCluster)
        guard let last = chain.last, let newCluster = allocateCluster() else { return false }
        let offset = clusterOffset(newCluster)
        guard offset + clusterBytes <= storage.data.count else { return false }
        storage.data.replaceSubrange(offset..<(offset + clusterBytes), with: [UInt8](repeating: 0, count: clusterBytes))
        setFATEntry(last, newCluster)
        setFATEntry(newCluster, eocValue)
        return true
    }

    /// LFN エントリ群を作る（物理順は末尾チャンクが先で、最終チャンクに
    /// 0x40 フラグが立つ）。名前が 13 文字の倍数のときは終端だけの
    /// エントリが 1 つ増える。
    static func longNameEntries(name: String, shortName: [UInt8]) -> [[UInt8]] {
        var units = [UInt16](name.utf16)
        units.append(0) // 終端
        while units.count % 13 != 0 { units.append(0xFFFF) }
        let chunkCount = units.count / 13
        let checksum = shortNameChecksum(shortName)
        var entries: [[UInt8]] = []
        for chunkIndex in stride(from: chunkCount - 1, through: 0, by: -1) {
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = UInt8(chunkIndex + 1) | (chunkIndex == chunkCount - 1 ? 0x40 : 0)
            entry[11] = 0x0F
            entry[13] = checksum
            var unitIndex = chunkIndex * 13
            for range in [(1, 11), (14, 26), (28, 32)] {
                var offset = range.0
                while offset < range.1 {
                    let unit = units[unitIndex]
                    unitIndex += 1
                    entry[offset] = UInt8(unit & 0xFF)
                    entry[offset + 1] = UInt8(unit >> 8)
                    offset += 2
                }
            }
            entries.append(entry)
        }
        return entries
    }

    /// SFN でエントリを探す。
    private func entry(forShortName shortName: [UInt8], directoryCluster: Int) -> Entry? {
        listDirectory(cluster: directoryCluster).first { $0.shortName == shortName && !$0.isVolumeLabel }
    }

    /// 既存エントリと重ならない SFN を作る（必要なら ~n を付ける）。
    private func uniqueShortName(for name: String, directoryCluster: Int) -> [UInt8] {
        let base = Self.shortNameBytes(for: name)
        if entry(forShortName: base, directoryCluster: directoryCluster) == nil { return base }
        let baseText = String(bytes: base[0..<8], encoding: .ascii) ?? ""
        let trimmedBase = baseText.trimmingCharacters(in: .whitespaces)
        for number in 1...99 {
            let suffix = "~\(number)"
            var candidate = base
            let head = String(trimmedBase.prefix(8 - suffix.count)) + suffix
            let headBytes = [UInt8](head.utf8)
            for index in 0..<8 {
                candidate[index] = index < headBytes.count ? headBytes[index] : 0x20
            }
            if entry(forShortName: candidate, directoryCluster: directoryCluster) == nil { return candidate }
        }
        return base
    }

    /// ディレクトリへエントリ（必要なら LFN つき）を書く。同 SFN の
    /// 既存エントリは先に削除扱いにして二重化を防ぐ。
    private func writeDirectoryEntry(directoryCluster: Int, shortName: [UInt8], longName: String?, make: ([UInt8]) -> [UInt8]) throws {
        markEntryDeleted(directoryCluster: directoryCluster, shortName: shortName)
        let lfnEntries = longName.map { Self.longNameEntries(name: $0, shortName: shortName) } ?? []
        let needed = lfnEntries.count + 1
        var slots = directorySlotOffsets(directoryCluster: directoryCluster)
        var start = freeRunStart(slots: slots, needed: needed)
        if start == nil, extendDirectory(directoryCluster: directoryCluster) {
            slots = directorySlotOffsets(directoryCluster: directoryCluster)
            start = freeRunStart(slots: slots, needed: needed)
        }
        guard let start else { throw FATError.directoryFull }
        for (index, lfnEntry) in lfnEntries.enumerated() {
            let offset = slots[start + index]
            storage.data.replaceSubrange(offset..<(offset + 32), with: lfnEntry)
        }
        let offset = slots[start + lfnEntries.count]
        let entry = make([UInt8](storage.data[offset..<(offset + 32)]))
        storage.data.replaceSubrange(offset..<(offset + 32), with: entry)
    }

    /// ファイルを作成 / 置換する（ディレクトリはパス要素列、名前は最終要素）。
    /// 新しいチェーンを先に割り当ててから旧チェーンを解放するため、
    /// 途中で失敗しても既存ファイルは壊れない。SFN で表せない名前には
    /// LFN エントリを付ける。
    func writeFile(directoryPath: [String], name: String, contents: [UInt8]) throws {
        var directoryCluster = isFAT32 ? rootCluster : 0
        if !directoryPath.isEmpty {
            guard let directory = resolve(path: directoryPath), directory.isDirectory else {
                throw FATError.notFound
            }
            directoryCluster = directory.firstCluster
        }
        let existing = findEntry(directoryCluster: directoryCluster, name: name).flatMap { $0.isDirectory ? nil : $0 }
        // 既存ファイルはその SFN を引き継ぎ、新規は重ならない SFN を作る
        let shortName = existing?.shortName ?? uniqueShortName(for: name, directoryCluster: directoryCluster)
        // クラスタチェーンを割り当てて内容を書く（旧チェーンはまだ残す）
        var firstCluster = 0
        var allocated: [Int] = []
        do {
            if !contents.isEmpty {
                let needed = (contents.count + clusterBytes - 1) / clusterBytes
                for _ in 0..<needed {
                    guard let cluster = allocateCluster() else { throw FATError.diskFull }
                    allocated.append(cluster)
                    setFATEntry(cluster, eocValue) // 仮に終端を書いてから連結する
                }
                for index in allocated.indices {
                    let next = index + 1 < allocated.count ? allocated[index + 1] : eocValue
                    setFATEntry(allocated[index], next)
                    let offset = clusterOffset(allocated[index])
                    guard offset + clusterBytes <= storage.data.count else { throw FATError.diskFull }
                    let start = index * clusterBytes
                    let chunk = contents[start..<min(start + clusterBytes, contents.count)]
                    var padded = [UInt8](chunk)
                    while padded.count < clusterBytes { padded.append(0) }
                    storage.data.replaceSubrange(offset..<(offset + clusterBytes), with: padded)
                }
                firstCluster = allocated.first ?? 0
            }
        } catch {
            for cluster in allocated { setFATEntry(cluster, 0) }
            throw error
        }
        // ディレクトリエントリを書く（SFN で表せない名前には LFN を付ける）
        let longName = Self.displayName(shortName: shortName) != name ? name : nil
        do {
            try writeDirectoryEntry(directoryCluster: directoryCluster, shortName: shortName, longName: longName) { _ in
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
        } catch {
            for cluster in allocated { setFATEntry(cluster, 0) }
            throw error
        }
        // ここまで成功してから旧チェーンを解放する
        if let existing {
            freeChain(existing.firstCluster)
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
        markEntryDeleted(directoryCluster: directoryCluster, shortName: existing.shortName)
    }

    /// 使用中バイト数の概算（空き容量計算用）。
    var usedBytes: Int {
        var used = 0
        for cluster in 2..<(dataClusterCount + 2) where fatEntry(cluster) != 0 {
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
