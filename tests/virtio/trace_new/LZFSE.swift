import Foundation

/// LZFSE ストリームのデコーダ（Apple のリファレンス実装のアルゴリズムを Swift に移植）。
///
/// 対応ブロック: bvx2（圧縮テーブル）/ bvx1（無圧縮テーブル）/ bvx-（無圧縮）/ bvx$（終端）。
/// bvxn（LZVN）には未対応で、その場合は nil を返す。
/// kernelcache や DeviceTree の IM4P ペイロードはこの形式で圧縮されている。
enum LZFSE {
    private static let magicEOS: UInt32 = 0x24787662   // bvx$
    private static let magicRaw: UInt32 = 0x2d787662   // bvx-
    private static let magicV1: UInt32 = 0x31787662    // bvx1
    private static let magicV2: UInt32 = 0x32787662    // bvx2
    private static let magicLZVN: UInt32 = 0x6e787662  // bvxn

    private static let lStates = 64
    private static let mStates = 64
    private static let dStates = 256
    private static let literalStates = 1024

    private static let lSymbols = 20
    private static let mSymbols = 20
    private static let dSymbols = 64
    private static let literalSymbols = 256

    private static let lExtraBits: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 5, 8]
    private static let lBaseValue: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 28, 60]
    private static let mExtraBits: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 5, 8, 11]
    private static let mBaseValue: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 24, 56, 312]
    private static let dExtraBits: [UInt8] = [
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
        8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11,
        12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15,
    ]
    private static let dBaseValue: [Int32] = [
        0, 1, 2, 3, 4, 6, 8, 10, 12, 16,
        20, 24, 28, 36, 44, 52, 60, 76, 92, 108,
        124, 156, 188, 220, 252, 316, 380, 444, 508, 636,
        764, 892, 1020, 1276, 1532, 1788, 2044, 2556, 3068, 3580,
        4092, 5116, 6140, 7164, 8188, 10236, 12284, 14332, 16380, 20476,
        24572, 28668, 32764, 40956, 49148, 57340, 65532, 81916, 98300, 114684,
        131068, 163836, 196604, 229372,
    ]

    // MARK: - 後方読みビットストリーム（64 ビット版 fse_in_stream）

    private struct InStream {
        var accum: UInt64 = 0
        var accumNbits: Int = 0
        /// 次に読み込む位置（ペイロード末尾から前方へ進む）
        var buf: Int
        let bufStart: Int
        let src: [UInt8]

        /// n はエンコーダ最終状態のビット数（-7...0）。
        init?(bits n: Int, src: [UInt8], endIndex: Int, bufStart: Int) {
            self.src = src
            self.bufStart = bufStart
            if n != 0 {
                guard endIndex - 8 >= bufStart else { return nil }
                buf = endIndex - 8
                accum = LZFSE.load64(src, buf)
                accumNbits = n + 64
            } else {
                guard endIndex - 7 >= bufStart else { return nil }
                buf = endIndex - 7
                var v: UInt64 = 0
                for i in 0..<7 {
                    v |= UInt64(src[buf + i]) << (8 * i)
                }
                accum = v & 0x00FF_FFFF_FFFF_FFFF
                accumNbits = 56
            }
            guard accumNbits >= 56 && accumNbits < 64 else { return nil }
            guard (accum >> accumNbits) == 0 else { return nil }
        }

        mutating func flush() -> Bool {
            let nbits = (63 - accumNbits) & -8
            let newBuf = buf - (nbits >> 3)
            guard newBuf >= bufStart else { return false }
            buf = newBuf
            let incoming = LZFSE.load64(src, buf)
            accum = (accum << nbits) | (incoming & LZFSE.mask64(nbits))
            accumNbits += nbits
            return true
        }

        mutating func pull(_ n: Int) -> UInt64 {
            accumNbits -= n
            let result = accum >> accumNbits
            accum &= LZFSE.mask64(accumNbits)
            return result
        }
    }

    private static func mask64(_ nbits: Int) -> UInt64 {
        nbits >= 64 ? UInt64.max : (nbits == 0 ? 0 : (UInt64(1) << nbits) - 1)
    }

    private static func load64(_ src: [UInt8], _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(src[off + i]) << (8 * i)
        }
        return v
    }

    private static func load32(_ src: [UInt8], _ off: Int) -> UInt32 {
        UInt32(src[off]) | (UInt32(src[off + 1]) << 8) | (UInt32(src[off + 2]) << 16) | (UInt32(src[off + 3]) << 24)
    }

    private static func load16(_ src: [UInt8], _ off: Int) -> UInt16 {
        UInt16(src[off]) | (UInt16(src[off + 1]) << 8)
    }

    // MARK: - FSE デコーダテーブル

    /// リテラル用テーブル。エントリは (delta << 16) | (symbol << 8) | k にパックする。
    private static func initDecoderTable(nstates: Int, freq: [UInt16]) -> [Int32] {
        var t = [Int32](repeating: 0, count: nstates)
        let nClz = UInt32(nstates).leadingZeroBitCount
        var idx = 0
        for (symbol, f0) in freq.enumerated() {
            let f = Int(f0)
            if f == 0 { continue }
            let k = UInt32(f).leadingZeroBitCount - nClz
            let j0 = ((2 * nstates) >> k) - f
            for j in 0..<f {
                let kk: Int
                let delta: Int
                if j < j0 {
                    kk = k
                    delta = ((f + j) << k) - nstates
                } else {
                    kk = k - 1
                    delta = (j - j0) << (k - 1)
                }
                t[idx] = Int32((delta << 16) | (symbol << 8) | kk)
                idx += 1
            }
        }
        return t
    }

    private struct ValueEntry {
        var totalBits: UInt8
        var valueBits: UInt8
        var delta: Int32
        var vbase: Int32
    }

    private static func initValueDecoderTable(nstates: Int, freq: [UInt16], vbits: [UInt8], vbase: [Int32]) -> [ValueEntry] {
        var t = [ValueEntry](repeating: ValueEntry(totalBits: 0, valueBits: 0, delta: 0, vbase: 0), count: nstates)
        let nClz = UInt32(nstates).leadingZeroBitCount
        var idx = 0
        for (symbol, f0) in freq.enumerated() {
            let f = Int(f0)
            if f == 0 { continue }
            let k = UInt32(f).leadingZeroBitCount - nClz
            let j0 = ((2 * nstates) >> k) - f
            for j in 0..<f {
                var e = ValueEntry(totalBits: 0, valueBits: vbits[symbol], delta: 0, vbase: vbase[symbol])
                if j < j0 {
                    e.totalBits = UInt8(k) + e.valueBits
                    e.delta = Int32(((f + j) << k) - nstates)
                } else {
                    e.totalBits = UInt8(k - 1) + e.valueBits
                    e.delta = Int32((j - j0) << (k - 1))
                }
                t[idx] = e
                idx += 1
            }
        }
        return t
    }

    private static func fseDecode(state: inout Int, table: [Int32], stream: inout InStream) -> UInt8 {
        let e = table[state]
        state = Int(e >> 16) + Int(stream.pull(Int(e & 0xff)))
        return UInt8((e >> 8) & 0xff)
    }

    private static func fseValueDecode(state: inout Int, table: [ValueEntry], stream: inout InStream) -> Int32 {
        let e = table[state]
        let sav = stream.pull(Int(e.totalBits))
        state = Int(e.delta) + Int(sav >> e.valueBits)
        return e.vbase + Int32(sav & UInt64(mask64(Int(e.valueBits))))
    }

    // MARK: - ブロックヘッダ

    private struct BlockHeader {
        var nRawBytes: Int = 0
        var nLiterals: Int = 0
        var nMatches: Int = 0
        var nLiteralPayloadBytes: Int = 0
        var nLmdPayloadBytes: Int = 0
        var literalBits: Int = 0
        var literalState: [Int] = [0, 0, 0, 0]
        var lmdBits: Int = 0
        var lState: Int = 0
        var mState: Int = 0
        var dState: Int = 0
        var lFreq = [UInt16](repeating: 0, count: 20)
        var mFreq = [UInt16](repeating: 0, count: 20)
        var dFreq = [UInt16](repeating: 0, count: 64)
        var literalFreq = [UInt16](repeating: 0, count: 256)
        var headerSize: Int = 0
    }

    /// v2 ヘッダの freq 値デコード（固定テーブル方式）。
    private static func decodeFreqValue(_ bits: UInt32) -> (value: Int, nbits: Int) {
        let nbitsTable: [Int] = [
            2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14,
            2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14,
        ]
        let valueTable: [Int] = [
            0, 2, 1, 4, 0, 3, 1, -1, 0, 2, 1, 5, 0, 3, 1, -1,
            0, 2, 1, 6, 0, 3, 1, -1, 0, 2, 1, 7, 0, 3, 1, -1,
        ]
        let b = Int(bits & 31)
        let n = nbitsTable[b]
        if n == 8 {
            return (8 + Int((bits >> 4) & 0xf), n)
        }
        if n == 14 {
            return (24 + Int((bits >> 4) & 0x3ff), n)
        }
        return (valueTable[b], n)
    }

    private static func field(_ v: UInt64, _ offset: Int, _ nbits: Int) -> UInt64 {
        (v >> offset) & mask64(nbits)
    }

    /// v2 ヘッダを v1 相当のフィールドへ展開する。失敗時は nil。
    private static func parseV2Header(_ src: [UInt8], at start: Int) -> BlockHeader? {
        // 固定部: magic(4) + n_raw_bytes(4) + packed_fields(24) = 32 バイト
        guard start + 32 <= src.count else { return nil }
        var h = BlockHeader()
        h.nRawBytes = Int(load32(src, start + 4))
        let v0 = load64(src, start + 8)
        let v1 = load64(src, start + 16)
        let v2 = load64(src, start + 24)
        h.nLiterals = Int(field(v0, 0, 20))
        h.nLiteralPayloadBytes = Int(field(v0, 20, 20))
        h.nMatches = Int(field(v0, 40, 20))
        h.literalBits = Int(field(v0, 60, 3)) - 7
        h.literalState = [
            Int(field(v1, 0, 10)), Int(field(v1, 10, 10)),
            Int(field(v1, 20, 10)), Int(field(v1, 30, 10)),
        ]
        h.nLmdPayloadBytes = Int(field(v1, 40, 20))
        h.lmdBits = Int(field(v1, 60, 3)) - 7
        let headerSize = Int(field(v2, 0, 32))
        h.lState = Int(field(v2, 32, 10))
        h.mState = Int(field(v2, 42, 10))
        h.dState = Int(field(v2, 52, 10))
        h.headerSize = headerSize
        guard headerSize >= 32 && start + headerSize <= src.count else { return nil }
        // freq テーブル（l, m, d, literal の順に連結）
        var dst = [UInt16](repeating: 0, count: lSymbols + mSymbols + dSymbols + literalSymbols)
        var pos = start + 32
        let end = start + headerSize
        var accum: UInt32 = 0
        var accumNbits = 0
        if end == pos {
            // テーブル省略（全ゼロ）
        } else {
            for i in 0..<dst.count {
                while pos < end && accumNbits + 8 <= 32 {
                    accum |= UInt32(src[pos]) << accumNbits
                    accumNbits += 8
                    pos += 1
                }
                let (value, nbits) = decodeFreqValue(accum)
                if nbits > accumNbits { return nil }
                dst[i] = UInt16(value)
                accum >>= nbits
                accumNbits -= nbits
            }
            guard accumNbits < 8 && pos == end else { return nil }
        }
        h.lFreq = Array(dst[0..<lSymbols])
        h.mFreq = Array(dst[lSymbols..<(lSymbols + mSymbols)])
        h.dFreq = Array(dst[(lSymbols + mSymbols)..<(lSymbols + mSymbols + dSymbols)])
        h.literalFreq = Array(dst[(lSymbols + mSymbols + dSymbols)...])
        return h
    }

    /// v1 ヘッダ（固定長 770 バイト）を読み取る。
    private static func parseV1Header(_ src: [UInt8], at start: Int) -> BlockHeader? {
        let size = 770
        guard start + size <= src.count else { return nil }
        var h = BlockHeader()
        var p = start + 4
        h.nRawBytes = Int(load32(src, p)); p += 4
        p += 4 // n_payload_bytes（未使用）
        h.nLiterals = Int(load32(src, p)); p += 4
        h.nMatches = Int(load32(src, p)); p += 4
        h.nLiteralPayloadBytes = Int(load32(src, p)); p += 4
        h.nLmdPayloadBytes = Int(load32(src, p)); p += 4
        h.literalBits = Int(Int32(bitPattern: load32(src, p))); p += 4
        for i in 0..<4 { h.literalState[i] = Int(load16(src, p)); p += 2 }
        h.lmdBits = Int(Int32(bitPattern: load32(src, p))); p += 4
        h.lState = Int(load16(src, p)); p += 2
        h.mState = Int(load16(src, p)); p += 2
        h.dState = Int(load16(src, p)); p += 2
        for i in 0..<lSymbols { h.lFreq[i] = load16(src, p); p += 2 }
        for i in 0..<mSymbols { h.mFreq[i] = load16(src, p); p += 2 }
        for i in 0..<dSymbols { h.dFreq[i] = load16(src, p); p += 2 }
        for i in 0..<literalSymbols { h.literalFreq[i] = load16(src, p); p += 2 }
        h.headerSize = size
        return h
    }

    // MARK: - 公開 API

    /// LZFSE ストリーム全体を展開する。失敗時は nil。
    static func decode(_ src: [UInt8]) -> [UInt8]? {
        var dst: [UInt8] = []
        dst.reserveCapacity(src.count * 3)
        var pos = 0
        while true {
            guard pos + 4 <= src.count else { return nil }
            let magic = load32(src, pos)
            if magic == magicEOS {
                return dst
            }
            if magic == magicRaw {
                guard pos + 8 <= src.count else { return nil }
                let n = Int(load32(src, pos + 4))
                guard pos + 8 + n <= src.count else { return nil }
                dst.append(contentsOf: src[(pos + 8)..<(pos + 8 + n)])
                pos += 8 + n
                continue
            }
            if magic == magicLZVN {
                return nil // 未対応
            }
            guard magic == magicV1 || magic == magicV2 else { return nil }
            guard let h = (magic == magicV2 ? parseV2Header(src, at: pos) : parseV1Header(src, at: pos)) else {
                return nil
            }
            let payloadStart = pos + h.headerSize
            guard payloadStart + h.nLiteralPayloadBytes + h.nLmdPayloadBytes <= src.count else { return nil }
            let blockRawStart = dst.count

            // 不正なヘッダでテーブル構築や状態インデックスが trap しないよう事前検証する
            // （FSE の不変条件: 各テーブルの freq 合計は状態数と一致し、初期状態は範囲内）
            func freqValid(_ freq: [UInt16], _ n: Int) -> Bool {
                var sum = 0
                for f in freq { if Int(f) > n { return false }; sum += Int(f) }
                return sum == n
            }
            guard freqValid(h.literalFreq, literalStates), freqValid(h.lFreq, lStates),
                  freqValid(h.mFreq, mStates), freqValid(h.dFreq, dStates),
                  h.literalState.allSatisfy({ $0 >= 0 && $0 < literalStates }),
                  h.lState >= 0 && h.lState < lStates,
                  h.mState >= 0 && h.mState < mStates,
                  h.dState >= 0 && h.dState < dStates else { return nil }

            // テーブル構築
            let literalTable = initDecoderTable(nstates: literalStates, freq: h.literalFreq)
            let lTable = initValueDecoderTable(nstates: lStates, freq: h.lFreq, vbits: lExtraBits, vbase: lBaseValue)
            let mTable = initValueDecoderTable(nstates: mStates, freq: h.mFreq, vbits: mExtraBits, vbase: mBaseValue)
            let dTable = initValueDecoderTable(nstates: dStates, freq: h.dFreq, vbits: dExtraBits, vbase: dBaseValue)

            // リテラルをすべて先に展開する（4 ストリームインターリーブ）
            var literals = [UInt8](repeating: 0, count: h.nLiterals)
            if h.nLiterals > 0 {
                // bufStart はリファレンス実装に合わせバッファ先頭（最終 flush が
                // ヘッダ側へ少しはみ出して読むことを許すため）。
                guard var stream = InStream(bits: h.literalBits, src: src,
                                            endIndex: payloadStart + h.nLiteralPayloadBytes,
                                            bufStart: 0) else { return nil }
                var states = h.literalState
                var i = 0
                while i < h.nLiterals {
                    guard stream.flush() else { return nil }
                    for j in 0..<4 where i + j < h.nLiterals {
                        literals[i + j] = fseDecode(state: &states[j], table: literalTable, stream: &stream)
                    }
                    i += 4
                }
            }

            // LMD を実行する
            let lmdStart = payloadStart + h.nLiteralPayloadBytes
            guard var stream = InStream(bits: h.lmdBits, src: src,
                                        endIndex: lmdStart + h.nLmdPayloadBytes,
                                        bufStart: 0) else { return nil }
            var lState = h.lState
            var mState = h.mState
            var dState = h.dState
            var distance: Int32 = -1
            var litPos = 0
            for _ in 0..<h.nMatches {
                guard stream.flush() else { return nil }
                let l = Int(fseValueDecode(state: &lState, table: lTable, stream: &stream))
                let m = Int(fseValueDecode(state: &mState, table: mTable, stream: &stream))
                let newD = fseValueDecode(state: &dState, table: dTable, stream: &stream)
                if newD != 0 { distance = newD }
                guard distance >= 1 else { return nil }
                guard litPos + l <= literals.count else { return nil }
                dst.append(contentsOf: literals[litPos..<(litPos + l)])
                litPos += l
                // マッチは現在のブロック内で生成された範囲しか参照できない
                guard Int(distance) <= dst.count - blockRawStart else { return nil }
                // マッチコピー（重なりあり）
                var remaining = m
                while remaining > 0 {
                    let from = dst.count - Int(distance)
                    let chunk = min(remaining, Int(distance))
                    dst.append(contentsOf: dst[from..<(from + chunk)])
                    remaining -= chunk
                }
            }
            guard dst.count - blockRawStart == h.nRawBytes else { return nil }
            pos = payloadStart + h.nLiteralPayloadBytes + h.nLmdPayloadBytes
        }
    }
}
