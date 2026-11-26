import Foundation

/// Multiboot 仕様（バージョン 1）ブートローダ。
///
/// Multiboot 対応の ELF32（i386）カーネルを読み込み、仕様どおりの
/// CPU 状態（プロテクトモード、フラットセグメント、EAX にマジック、
/// EBX に情報構造体へのポインタ）でエントリポイントへ入る。
/// GRUB のような外部ブートローダなしに、カーネルを直接起動できる。
enum MultibootError: Error, LocalizedError {
    case notELF
    case headerNotFound
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .notELF:
            return "ELF32（i386）形式のカーネルではありません。"
        case .headerNotFound:
            return "Multiboot ヘッダが見つかりません。"
        case .unsupportedImage:
            return "カーネルイメージがメモリに収まりません。"
        }
    }
}

enum Multiboot {
    /// カーネル側ヘッダのマジック。
    static let headerMagic: UInt32 = 0x1BADB002
    /// ブートローダが EAX に入れるマジック。
    static let bootMagic: UInt32 = 0x2BADB002

    /// Multiboot 情報構造体とメモリマップを置く物理アドレス。
    private static let infoAddress: UInt32 = 0x00002000
    /// 初期スタックの先頭。
    private static let stackTop: UInt32 = 0x00090000

    // MARK: - 判定

    /// ELF32（i386）かつ Multiboot ヘッダを持つカーネルかどうか。
    static func isMultibootKernel(_ data: [UInt8]) -> Bool {
        isELF32(data) && findHeader(in: data) != nil
    }

    private static func isELF32(_ data: [UInt8]) -> Bool {
        guard data.count >= 52 else { return false }
        guard data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 else { return false }
        guard data[4] == 1, data[5] == 1 else { return false } // 32 ビット、リトルエンディアン
        return read16(data, 18) == 3 // EM_386
    }

    /// ファイル先頭 8 KiB から Multiboot ヘッダ（マジック + チェックサム）を探す。
    private static func findHeader(in data: [UInt8]) -> (offset: Int, flags: UInt32)? {
        let limit = min(data.count - 12, 8192)
        guard limit >= 0 else { return nil }
        var offset = 0
        while offset <= limit {
            if read32(data, offset) == headerMagic {
                let flags = read32(data, offset + 4)
                let checksum = read32(data, offset + 8)
                if headerMagic &+ flags &+ checksum == 0 {
                    return (offset, flags)
                }
            }
            offset += 4
        }
        return nil
    }

    // MARK: - 起動

    /// カーネルを読み込んで Multiboot 状態で開始できるよう CPU を準備する。
    static func boot(cpu: X86CPU, imageData: [UInt8]) throws {
        guard isELF32(imageData) else { throw MultibootError.notELF }
        guard let header = findHeader(in: imageData) else { throw MultibootError.headerNotFound }
        let memorySize = cpu.memory.count
        let entry: UInt32

        if header.flags & 0x10000 != 0 {
            // a.out クルージュ: ヘッダ内のアドレス指定で読み込む
            let headerAddress = read32(imageData, header.offset + 12)
            let loadAddress = read32(imageData, header.offset + 16)
            let loadEndAddress = read32(imageData, header.offset + 20)
            let bssEndAddress = read32(imageData, header.offset + 24)
            entry = read32(imageData, header.offset + 28)
            let fileStart = header.offset - Int(headerAddress - loadAddress)
            let loadLength = loadEndAddress == 0 ? imageData.count - fileStart : Int(loadEndAddress - loadAddress)
            guard fileStart >= 0, loadLength >= 0, fileStart + loadLength <= imageData.count,
                  Int(loadAddress) + loadLength <= memorySize else {
                throw MultibootError.unsupportedImage
            }
            cpu.loadData(Array(imageData[fileStart..<(fileStart + loadLength)]), at: Int(loadAddress))
            if bssEndAddress > loadAddress + UInt32(loadLength) {
                let bssStart = Int(loadAddress) + loadLength
                let bssEnd = Int(bssEndAddress)
                guard bssEnd <= memorySize else { throw MultibootError.unsupportedImage }
                cpu.loadData([UInt8](repeating: 0, count: bssEnd - bssStart), at: bssStart)
            }
        } else {
            // ELF プログラムヘッダで読み込む
            entry = read32(imageData, 24)
            let programHeaderOffset = Int(read32(imageData, 28))
            let entrySize = Int(read16(imageData, 42))
            let count = Int(read16(imageData, 44))
            for index in 0..<count {
                let offset = programHeaderOffset + index * entrySize
                guard offset + 32 <= imageData.count, read32(imageData, offset) == 1 else { continue } // PT_LOAD
                let fileOffset = Int(read32(imageData, offset + 4))
                let physicalAddress = read32(imageData, offset + 12)
                let fileSize = Int(read32(imageData, offset + 16))
                let memorySizeOfSegment = Int(read32(imageData, offset + 20))
                guard fileOffset + fileSize <= imageData.count,
                      Int(physicalAddress) + memorySizeOfSegment <= memorySize else {
                    throw MultibootError.unsupportedImage
                }
                if fileSize > 0 {
                    cpu.loadData(Array(imageData[fileOffset..<(fileOffset + fileSize)]), at: Int(physicalAddress))
                }
                if memorySizeOfSegment > fileSize {
                    cpu.loadData([UInt8](repeating: 0, count: memorySizeOfSegment - fileSize), at: Int(physicalAddress) + fileSize)
                }
            }
        }

        writeInfoStructure(cpu: cpu, memorySize: memorySize)
        cpu.prepareMultibootEntry(entry: entry, infoAddress: infoAddress, stackTop: stackTop)
    }

    /// Multiboot 情報構造体（メモリ情報 + メモリマップ）を書き込む。
    private static func writeInfoStructure(cpu: X86CPU, memorySize: Int) {
        let mmapAddress = infoAddress + 52
        var info = [UInt8](repeating: 0, count: 52)
        // flags: bit0 = メモリ情報、bit1 = ブートデバイス、bit6 = メモリマップ
        write32(&info, 0, 0x00000043)
        write32(&info, 4, 640) // mem_lower（KiB）
        write32(&info, 8, UInt32(memorySize / 1024 - 1024)) // mem_upper（KiB）
        write32(&info, 12, 0xFFFFFF80) // boot_device（ドライブ 0x80、パーティションなし）
        write32(&info, 44, 72) // mmap_length（3 エントリ × 24 バイト）
        write32(&info, 48, mmapAddress)
        cpu.loadData(info, at: Int(infoAddress))

        var mmap = [UInt8]()
        func entry(base: UInt64, length: UInt64, type: UInt32) {
            var bytes = [UInt8](repeating: 0, count: 24)
            write32(&bytes, 0, 20) // size（このフィールド自身は含まない）
            write64(&bytes, 4, base)
            write64(&bytes, 12, length)
            write32(&bytes, 20, type)
            mmap.append(contentsOf: bytes)
        }
        entry(base: 0, length: 0x000A0000, type: 1) // 0〜640 KiB: 使用可能
        entry(base: 0x000A0000, length: 0x00060000, type: 2) // 640 KiB〜1 MiB: 予約
        entry(base: 0x00100000, length: UInt64(memorySize - 0x100000), type: 1) // 1 MiB〜: 使用可能
        cpu.loadData(mmap, at: Int(mmapAddress))
    }

    // MARK: - バイナリ読み取り

    private static func read16(_ data: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func write32(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static func write64(_ data: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
}
