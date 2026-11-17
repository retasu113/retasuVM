import Foundation

/// NVMe コントローラ（NVMe 1.4 のコアサブセット）。
///
/// Apple Silicon プラットフォーム向けに、MMIO レジスタ + ドアベル + 管理キュー /
/// IO キューを実装する。コマンドはドアベル書込時に同期実行する。
/// 割り込みは CQ 作成時に IEN が立っていれば完了時に 1 回ラッチする（ポーリングも可）。
/// RAM アクセスは ARM64CPU がクロージャで結線する。
final class ARM64NVMe {
    var readRAM: ((UInt64, Int) -> [UInt8])?
    var writeRAM: ((UInt64, [UInt8]) -> Void)?
    var onIRQ: (() -> Void)?

    private var disk: [UInt8] = []
    private var diskAttached = false

    func attachDisk(_ data: [UInt8]) {
        disk = data
        diskAttached = true
    }

    private var sectorCount: UInt64 {
        if !diskAttached { return 32 * 1024 * 1024 / 512 }   // 既定 32 MiB
        return UInt64(disk.count / 512)
    }

    // レジスタ状態
    private var cc: UInt32 = 0
    private var ready = false
    private var aqa: UInt32 = 0
    private var asqBase: UInt64 = 0
    private var acqBase: UInt64 = 0
    private var interruptMask: UInt32 = 0

    private struct SubmissionQueue {
        var base: UInt64
        var size: Int
        var head: Int
        var completionQueueID: Int
    }
    private struct CompletionQueue {
        var base: UInt64
        var size: Int
        var tail: Int
        var phase: Int
        var interruptsEnabled: Bool
    }
    private var submissionQueues: [Int: SubmissionQueue] = [:]
    private var completionQueues: [Int: CompletionQueue] = [:]

    // MARK: - レジスタアクセス

    func readRegister(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x00: return Self.capabilities
        case 0x04: return Self.capabilities >> 32
        case 0x08: return 0x0001_0400                        // VS: NVMe 1.4.0
        case 0x0C, 0x10: return UInt64(interruptMask)
        case 0x14: return UInt64(cc)
        case 0x1C: return ready ? 1 : 0                      // CSTS.RDY
        case 0x24: return UInt64(aqa)
        case 0x28: return asqBase
        case 0x2C: return asqBase >> 32
        case 0x30: return acqBase
        case 0x34: return acqBase >> 32
        default: return 0                                    // ドアベル等は 0
        }
    }

    private static var capabilities: UInt64 {
        // CAP: MQES=1023 [15:0], CQR=1 [16], TO=20（10 秒）[31:24],
        // DSTRD=0 [35:32], CSS=NVM コマンドセット [43:37] の bit37, MPSMIN/MPSMAX=0（4K ページ）
        return 0x3FF | (1 << 16) | (UInt64(20) << 24) | (UInt64(1) << 37)
    }

    func writeRegister(offset: UInt64, value: UInt64, size: Int) {
        let v32 = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x0C: interruptMask |= v32                       // INTMS
        case 0x10: interruptMask &= ~v32                      // INTMC
        case 0x14: writeControllerConfiguration(v32)
        case 0x24: aqa = v32
        case 0x28: asqBase = size == 8 ? value : (asqBase & 0xFFFF_FFFF_0000_0000) | UInt64(v32)
        case 0x2C: asqBase = (asqBase & 0xFFFF_FFFF) | (UInt64(v32) << 32)
        case 0x30: acqBase = size == 8 ? value : (acqBase & 0xFFFF_FFFF_0000_0000) | UInt64(v32)
        case 0x34: acqBase = (acqBase & 0xFFFF_FFFF) | (UInt64(v32) << 32)
        default:
            if offset >= 0x1000 {
                let index = Int((offset - 0x1000) / 4)
                let queueID = index / 2
                if index % 2 == 0 {
                    processSubmissionQueue(queueID, tail: Int(value & 0xFFFF))
                }
                // CQ ヘッドドアベルは消費位置の通知のみ（フロー制御には使わない）
            }
        }
    }

    private func writeControllerConfiguration(_ value: UInt32) {
        let wasEnabled = cc & 1 != 0
        let nowEnabled = value & 1 != 0
        cc = value
        if nowEnabled && !wasEnabled {
            // 有効化: 管理キューを AQA / ASQ / ACQ から作り直し、RDY を立てる
            submissionQueues = [0: SubmissionQueue(base: asqBase, size: Int(aqa & 0xFFF) + 1, head: 0, completionQueueID: 0)]
            completionQueues = [0: CompletionQueue(base: acqBase, size: Int((aqa >> 16) & 0xFFF) + 1, tail: 0, phase: 1, interruptsEnabled: false)]
            ready = true
        } else if !nowEnabled && wasEnabled {
            submissionQueues = [:]
            completionQueues = [:]
            ready = false
        }
    }

    // MARK: - コマンド実行

    private func processSubmissionQueue(_ queueID: Int, tail: Int) {
        guard var queue = submissionQueues[queueID] else { return }
        var guardCounter = 0
        while queue.head != tail && guardCounter < 4096 {
            guardCounter += 1
            let entryAddress = queue.base + UInt64(queue.head) * 64
            let command = readRAM?(entryAddress, 64) ?? [UInt8](repeating: 0, count: 64)
            queue.head = (queue.head + 1) % queue.size
            submissionQueues[queueID] = queue
            execute(command: command, queueID: queueID, queueHead: queue.head)
            guard let updated = submissionQueues[queueID] else { return }
            queue = updated
        }
    }

    private func dword(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        let o = index * 4
        guard o + 3 < bytes.count else { return 0 }
        return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }

    private func execute(command: [UInt8], queueID: Int, queueHead: Int) {
        let dw0 = dword(command, 0)
        let opcode = dw0 & 0xFF
        let commandID = (dw0 >> 16) & 0xFFFF
        let namespaceID = dword(command, 1)
        let prp1 = UInt64(dword(command, 6)) | UInt64(dword(command, 7)) << 32
        let prp2 = UInt64(dword(command, 8)) | UInt64(dword(command, 9)) << 32
        let cdw10 = dword(command, 10)
        let cdw11 = dword(command, 11)
        let cdw12 = dword(command, 12)

        var status: UInt32 = 0          // 0 = 成功（SC）、SCT は常に 0
        var result: UInt32 = 0

        if queueID == 0 {
            // 管理コマンド
            switch opcode {
            case 0x00:  // Delete I/O Submission Queue
                let target = Int((cdw10 >> 16) & 0xFFFF)
                if target == 0 || submissionQueues[target] == nil { status = 0x02 } else { submissionQueues[target] = nil }
            case 0x04:  // Delete I/O Completion Queue
                let target = Int((cdw10 >> 16) & 0xFFFF)
                if target == 0 || completionQueues[target] == nil { status = 0x02 } else { completionQueues[target] = nil }
            case 0x05:  // Create I/O Completion Queue
                let qid = Int((cdw10 >> 16) & 0xFFFF)
                let qsize = Int(cdw10 & 0xFFFF) + 1
                // CAP.MQES=1023 のため最大 1024 エントリ。それを超える要求は Invalid Field
                if qid == 0 || qsize < 2 || qsize > 1024 { status = 0x02 } else {
                    completionQueues[qid] = CompletionQueue(base: prp1, size: qsize, tail: 0, phase: 1, interruptsEnabled: cdw11 & 0x2 != 0)
                }
            case 0x01:  // Create I/O Submission Queue
                let qid = Int((cdw10 >> 16) & 0xFFFF)
                let qsize = Int(cdw10 & 0xFFFF) + 1
                let cqid = Int((cdw11 >> 16) & 0xFFFF)
                if qid == 0 || qsize < 2 || qsize > 1024 || completionQueues[cqid] == nil { status = 0x02 } else {
                    submissionQueues[qid] = SubmissionQueue(base: prp1, size: qsize, head: 0, completionQueueID: cqid)
                }
            case 0x06:  // Identify
                let cns = cdw10 & 0xFF
                if cns == 1 {
                    transferToGuest(prp1: prp1, prp2: prp2, data: identifyController())
                } else if cns == 0 {
                    if namespaceID != 1 { status = 0x0B } else {
                        transferToGuest(prp1: prp1, prp2: prp2, data: identifyNamespace())
                    }
                } else { status = 0x02 }
            case 0x02:  // Get Log Page（すべてゼロで応答）
                let dwordCount = Int(((cdw11 & 0xFFFF) << 16) | ((cdw10 >> 16) & 0xFFFF)) + 1
                let byteCount = min(dwordCount * 4, 16384)
                transferToGuest(prp1: prp1, prp2: prp2, data: [UInt8](repeating: 0, count: byteCount))
            case 0x09, 0x0A:  // Set / Get Features
                let fid = cdw10 & 0xFF
                if fid == 7 { result = 63 | (63 << 16) }        // キュー数: 64 本まで
                else if fid == 1 { result = 0 }
                else { status = 0x02 }
            default:
                status = 0x01   // Invalid Opcode
            }
            postCompletion(queueID: 0, commandID: commandID, result: result, status: status, submissionQueueID: 0, submissionQueueHead: queueHead)
        } else {
            // I/O コマンド（NVM コマンドセット）
            switch opcode {
            case 0x00:  // Flush
                break
            case 0x01, 0x02:  // Write / Read
                let lba = UInt64(cdw10) | UInt64(cdw11) << 32
                let count = Int(cdw12 & 0xFFFF) + 1
                if lba > sectorCount || UInt64(count) > sectorCount - lba {
                    status = 0x80   // LBA Out of Range
                } else if opcode == 0x02 {
                    var data = [UInt8](repeating: 0, count: count * 512)
                    if diskAttached {
                        let start = Int(lba) * 512
                        let slice = disk[start..<(start + count * 512)]
                        data.replaceSubrange(0..<slice.count, with: slice)
                    }
                    transferToGuest(prp1: prp1, prp2: prp2, data: data)
                } else {
                    let data = transferFromGuest(prp1: prp1, prp2: prp2, byteCount: count * 512)
                    if diskAttached {
                        let start = Int(lba) * 512
                        disk.replaceSubrange(start..<(start + count * 512), with: data)
                    }
                }
            default:
                status = 0x01
            }
            let cqid = submissionQueues[queueID]?.completionQueueID ?? 0
            postCompletion(queueID: cqid, commandID: commandID, result: result, status: status, submissionQueueID: queueID, submissionQueueHead: queueHead)
        }
    }

    private func postCompletion(queueID: Int, commandID: UInt32, result: UInt32, status: UInt32, submissionQueueID: Int, submissionQueueHead: Int) {
        guard var cq = completionQueues[queueID] else { return }
        var entry = [UInt8](repeating: 0, count: 16)
        func put32(_ index: Int, _ value: UInt32) {
            entry[index * 4] = UInt8(value & 0xFF)
            entry[index * 4 + 1] = UInt8((value >> 8) & 0xFF)
            entry[index * 4 + 2] = UInt8((value >> 16) & 0xFF)
            entry[index * 4 + 3] = UInt8((value >> 24) & 0xFF)
        }
        put32(0, result)
        put32(1, 0)
        put32(2, UInt32(submissionQueueHead) | (UInt32(submissionQueueID) << 16))
        put32(3, commandID | (UInt32(cq.phase) << 16) | (status << 17))
        writeRAM?(cq.base + UInt64(cq.tail) * 16, entry)
        cq.tail += 1
        if cq.tail >= cq.size {
            cq.tail = 0
            cq.phase ^= 1
        }
        completionQueues[queueID] = cq
        if cq.interruptsEnabled { onIRQ?() }
    }

    // MARK: - PRP 転送

    /// 転送に必要なページアドレス列（先頭チャンクは PRP1 のページ内オフセットを考慮）。
    private func prpChunks(prp1: UInt64, prp2: UInt64, byteCount: Int) -> [(address: UInt64, length: Int)] {
        var chunks: [(UInt64, Int)] = []
        var remaining = byteCount
        var current = prp1
        // 触れるページ数の判定（PRP2 が直接ポインタかリストかの決定に使う）
        let firstLength = min(remaining, 4096 - Int(prp1 & 0xFFF))
        var pageCount = 1
        if remaining > firstLength {
            pageCount += (remaining - firstLength + 4095) / 4096
        }
        var listEntries: [UInt64] = []
        var listIndex = 0
        var listPagesLeft = pageCount - 1   // リストから取るデータページ数
        func loadListPage(_ base: UInt64) -> [UInt64] {
            let page = readRAM?(base & ~0xFFF, 4096) ?? []
            var entries: [UInt64] = []
            for i in 0..<(page.count / 8) {
                var value: UInt64 = 0
                for j in 0..<8 { value |= UInt64(page[i * 8 + j]) << (8 * j) }
                entries.append(value)
            }
            return entries
        }
        var isFirst = true
        while remaining > 0 {
            let length = min(remaining, 4096 - Int(current & 0xFFF))
            chunks.append((current, length))
            remaining -= length
            if remaining == 0 { break }
            if isFirst && pageCount == 2 {
                current = prp2
            } else {
                if listEntries.isEmpty { listEntries = loadListPage(prp2) }
                // リストページの最終エントリ（511）は、まだデータページが残る場合は
                // 次のリストページへのチェインポインタ（NVMe 仕様）
                if listIndex == 511 && listPagesLeft > 1 {
                    listEntries = loadListPage(listEntries[511])
                    listIndex = 0
                }
                if listIndex < listEntries.count {
                    current = listEntries[listIndex]; listIndex += 1; listPagesLeft -= 1
                } else { break }
            }
            isFirst = false
        }
        return chunks
    }

    private func transferToGuest(prp1: UInt64, prp2: UInt64, data: [UInt8]) {
        var offset = 0
        for chunk in prpChunks(prp1: prp1, prp2: prp2, byteCount: data.count) {
            let slice = data[offset..<(offset + chunk.length)]
            writeRAM?(chunk.address, [UInt8](slice))
            offset += chunk.length
        }
    }

    private func transferFromGuest(prp1: UInt64, prp2: UInt64, byteCount: Int) -> [UInt8] {
        var data: [UInt8] = []
        for chunk in prpChunks(prp1: prp1, prp2: prp2, byteCount: byteCount) {
            data += readRAM?(chunk.address, chunk.length) ?? [UInt8](repeating: 0, count: chunk.length)
        }
        return data
    }

    // MARK: - Identify データ

    private func identifyController() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4096)
        func put16(_ offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        func putString(_ offset: Int, _ length: Int, _ text: String) {
            let bytes = [UInt8](text.utf8)
            for i in 0..<length { data[offset + i] = i < bytes.count ? bytes[i] : 0x20 }
        }
        put16(0, 0x106B)                 // VID（Apple）
        put16(2, 0x106B)                 // SSVID
        putString(4, 20, "RETASUVM0001") // SN
        putString(24, 40, "retasuVM NVMe") // MN
        putString(64, 8, "0.15")         // FR
        data[77] = 4                     // MDTS: 2^4 × 4 KiB = 最大 64 KiB
        put16(78, 1)                     // CNTLID
        put32(80, 0x0001_0400)           // VER: 1.4.0
        put32(516, 1)                    // NN: 名前空間 1 つ
        return data
    }

    private func identifyNamespace() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4096)
        func put64(_ offset: Int, _ value: UInt64) {
            for i in 0..<8 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        put64(0, sectorCount)            // NSZE
        put64(8, sectorCount)            // NCAP
        put64(16, 0)                     // NUSE
        data[25] = 0                     // NLBAF
        data[26] = 0                     // FLBAS（フォーマット 0 を使用）
        // LBAF0（オフセット 128）: MS=0, DS=9（512 バイト）, RP=0
        data[128] = 0
        data[129] = 0
        data[130] = 9
        data[131] = 0
        return data
    }
}
