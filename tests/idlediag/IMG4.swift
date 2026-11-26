import Foundation

/// IMG4 / IM4P コンテナの最小パーサ。
///
/// IPSW 内のコンポーネント（kernelcache、DeviceTree など）は IM4P 形式で格納される:
///   IM4P ::= SEQUENCE { IA5String "IM4P", IA5String type, OCTET STRING payload, [0] KBAG? }
/// .img4 ファイルはこれに IM4M（マニフェスト）を付けた外側 SEQUENCE で包む。
/// ここでは署名検証は行わず、ペイロードの取り出しだけを行う。
enum IMG4Error: Error, CustomStringConvertible {
    case truncated
    case unexpectedTag(UInt8)
    case notIMG4
    case notIM4P
    var description: String {
        switch self {
        case .truncated: return "IMG4: データが途中で終わっています"
        case .unexpectedTag(let t): return "IMG4: 予期しないタグ 0x\(String(t, radix: 16))"
        case .notIMG4: return "IMG4: 先頭が IMG4/IM4P ではありません"
        case .notIM4P: return "IMG4: IM4P が見つかりません"
        }
    }
}

struct IM4PPayload {
    /// コンポーネント種別（"krnl" = kernelcache、"tree" = DeviceTree など）
    let type: String
    /// ペイロード本体（kernelcache なら圧縮済み Mach-O、DeviceTree なら ADT）
    let payload: [UInt8]
}

enum IMG4 {
    /// DER の TLV を 1 つ読む。(tag, valueRange, nextOffset) を返す。
    private static func readTLV(_ data: [UInt8], at offset: Int) throws -> (UInt8, Range<Int>, Int) {
        guard offset + 2 <= data.count else { throw IMG4Error.truncated }
        let tag = data[offset]
        var pos = offset + 1
        guard pos < data.count else { throw IMG4Error.truncated }
        var length: Int
        let first = data[pos]
        pos += 1
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard n >= 1 && n <= 4 && pos + n <= data.count else { throw IMG4Error.truncated }
            length = 0
            for i in 0..<n {
                length = (length << 8) | Int(data[pos + i])
            }
            pos += n
        }
        guard pos + length <= data.count else { throw IMG4Error.truncated }
        return (tag, pos..<(pos + length), pos + length)
    }

    private static func ia5String(_ data: [UInt8], _ range: Range<Int>) -> String {
        String(bytes: data[range], encoding: .ascii) ?? ""
    }

    /// IM4P シーケンス（value 範囲）からペイロードを取り出す。
    /// 形式: SEQUENCE { IA5 "IM4P", IA5 type, IA5 description, OCTET STRING payload, ... }
    private static func parseIM4P(_ data: [UInt8], sequenceContent: Range<Int>) throws -> IM4PPayload {
        var pos = sequenceContent.lowerBound
        let end = sequenceContent.upperBound
        // IA5String "IM4P"
        let (t0, r0, n0) = try readTLV(data, at: pos)
        guard t0 == 0x16, ia5String(data, r0) == "IM4P" else { throw IMG4Error.notIM4P }
        pos = n0
        guard pos < end else { throw IMG4Error.truncated }
        // IA5String type（"krnl" など 4 文字）
        let (t1, r1, n1) = try readTLV(data, at: pos)
        guard t1 == 0x16 else { throw IMG4Error.unexpectedTag(t1) }
        let type = ia5String(data, r1)
        pos = n1
        guard pos < end else { throw IMG4Error.truncated }
        // IA5String description（例 "KernelCacheBuilder-960.40.11"）は読み飛ばす
        let (t2, _, n2) = try readTLV(data, at: pos)
        guard t2 == 0x16 else { throw IMG4Error.unexpectedTag(t2) }
        pos = n2
        guard pos < end else { throw IMG4Error.truncated }
        // OCTET STRING payload
        let (t3, r3, _) = try readTLV(data, at: pos)
        guard t3 == 0x04 else { throw IMG4Error.unexpectedTag(t3) }
        return IM4PPayload(type: type, payload: Array(data[r3]))
    }

    /// IMG4 または IM4P データからペイロードを取り出す。
    static func extractPayload(_ data: [UInt8]) throws -> IM4PPayload {
        let (tag, content, _) = try readTLV(data, at: 0)
        guard tag == 0x30 else { throw IMG4Error.notIMG4 }
        // 先頭要素を見る: "IMG4" なら内側の IM4P へ、"IM4P" ならこのシーケンス自体が IM4P。
        let (t0, r0, n0) = try readTLV(data, at: content.lowerBound)
        guard t0 == 0x16 else { throw IMG4Error.notIMG4 }
        let magic = ia5String(data, r0)
        if magic == "IM4P" {
            return try parseIM4P(data, sequenceContent: content)
        }
        if magic == "IMG4" {
            // 次の要素が IM4P シーケンス
            let (t1, r1, _) = try readTLV(data, at: n0)
            guard t1 == 0x30 else { throw IMG4Error.notIM4P }
            return try parseIM4P(data, sequenceContent: r1)
        }
        throw IMG4Error.notIMG4
    }
}
