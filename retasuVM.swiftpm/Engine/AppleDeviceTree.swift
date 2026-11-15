import Foundation

/// Apple Device Tree（ADT）のノード表現とバイナリ生成。
///
/// ADT は Apple のファームウェアがカーネルへ渡す独自形式のデバイスツリーで、
/// 標準の FDT とは異なる。形式（Asahi Linux プロジェクトの公開ドキュメントによる）:
/// - ノード: u32 プロパティ数、u32 子ノード数に続き、プロパティ列、子ノード列（再帰）
/// - プロパティ: 32 バイトの NUL パディング済み名前、u32 サイズ
///   （bit31 はプレースホルダフラグ、下位 31 ビットがバイト長）、値（4 バイト境界へパディング）
/// - ノード自身の名前は "name" というプロパティとして格納される
struct ADTNode {
    var name: String
    var properties: [(name: String, value: [UInt8])] = []
    var children: [ADTNode] = []

    init(_ name: String) {
        self.name = name
    }

    mutating func setString(_ name: String, _ value: String) {
        setBytes(name, [UInt8](value.utf8) + [0])
    }

    /// NUL 区切りの文字列リスト（compatible など）。
    mutating func setStringList(_ name: String, _ values: [String]) {
        var bytes: [UInt8] = []
        for value in values { bytes += [UInt8](value.utf8) + [0] }
        setBytes(name, bytes)
    }

    mutating func setU32(_ name: String, _ value: UInt32) {
        setBytes(name, [UInt8](repeating: 0, count: 4).enumerated().map { i, _ in UInt8((value >> (8 * i)) & 0xFF) })
    }

    mutating func setU64(_ name: String, _ value: UInt64) {
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
        setBytes(name, bytes)
    }

    /// reg プロパティ（アドレスとサイズの u64 ペア）。
    mutating func setReg(_ name: String = "reg", address: UInt64, size: UInt64) {
        var bytes: [UInt8] = []
        for value in [address, size] {
            for i in 0..<8 { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
        }
        setBytes(name, bytes)
    }

    mutating func setEmpty(_ name: String) {
        setBytes(name, [])
    }

    mutating func setBytes(_ name: String, _ value: [UInt8]) {
        if let index = properties.firstIndex(where: { $0.name == name }) {
            properties[index] = (name, value)
        } else {
            properties.append((name, value))
        }
    }

    /// ADT バイナリへ直列化する。
    func serialized() -> [UInt8] {
        var out: [UInt8] = []
        serialize(into: &out)
        return out
    }

    private func serialize(into out: inout [UInt8]) {
        var allProperties: [(name: String, value: [UInt8])] = [("name", [UInt8](name.utf8) + [0])]
        allProperties += properties
        appendU32(&out, UInt32(allProperties.count))
        appendU32(&out, UInt32(children.count))
        for property in allProperties {
            var nameBytes = [UInt8](property.name.utf8)
            nameBytes += [UInt8](repeating: 0, count: max(0, 32 - nameBytes.count))
            out += nameBytes.prefix(32)
            appendU32(&out, UInt32(property.value.count))
            out += property.value
            let padding = (4 - (property.value.count % 4)) % 4
            out += [UInt8](repeating: 0, count: padding)
        }
        for child in children {
            child.serialize(into: &out)
        }
    }

    private func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        for i in 0..<4 { out.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
}
