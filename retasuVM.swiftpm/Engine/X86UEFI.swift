import Foundation

/// 最小 UEFI ファームウェア（自作）。
///
/// PE32+（x86-64）イメージを ImageBase へ配置し、ロングモードで
/// エントリポイントを呼ぶ。UEFI の呼び出し規約どおり、RCX に
/// ImageHandle、RDX に SystemTable ポインタを渡す。
/// サービス関数はスタブアドレスを CPU の preExecuteHook で横取りし、
/// Swift 側でネイティブ実行する（ゲストコードは実行されない）。
///
/// 提供するサービスはコンソール出力と基本的なブートサービスのみ。
/// Block I/O やファイルシステム、変数サービスは未提供のため、
/// Windows Boot Manager や GRUB のような本格的なブートローダは
/// まだ起動できない（README / リリースノートに明記）。
enum X86UEFI {
    enum UEFIError: LocalizedError {
        case notUEFIApplication
        case unsupportedMachine(UInt16)
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .notUEFIApplication:
                return "UEFI アプリケーション（PE32+ / x86-64）ではありません。"
            case .unsupportedMachine(let machine):
                return "対応していない PE マシンタイプです（0x\(String(machine, radix: 16))）。x86-64 のみ対応します。"
            case .imageTooLarge:
                return "UEFI イメージが大きすぎます。"
            }
        }
    }

    // メモリ配置（16 MiB RAM 内）
    static let pml4Address = 0x100000
    static let pdptAddress = 0x101000
    static let pdAddress = 0x102000
    static let gdtAddress = 0x103000
    static let idtAddress = 0x104000
    static let systemTableAddress = 0x300000
    static let conOutAddress = 0x300100
    static let conOutModeAddress = 0x300200
    static let configTableAddress = 0x300280
    static let bootServicesAddress = 0x300300
    static let runtimeServicesAddress = 0x300600
    static let stubBase = 0x301000
    static let idtStubAddress = 0x301F00
    static let returnTrapAddress = 0x3FF000
    static let stackTop = 0x400000
    static let heapStart = 0x500000
    static let heapEnd = 0xF00000

    /// PE ヘッダだけを見て UEFI アプリケーションかどうかを判定する。
    static func isUEFIApplication(_ data: [UInt8]) -> Bool {
        guard let info = parsePE(data) else { return false }
        return info.machine == 0x8664 && (10...12).contains(info.subsystem)
    }

    private struct PEInfo {
        var machine: UInt16
        var subsystem: UInt32
        var imageBase: UInt64
        var entryRVA: UInt32
        var sizeOfImage: UInt32
        var sizeOfHeaders: UInt32
        var sectionTableOffset: Int
        var sectionCount: Int
        var relocationRVA: UInt32
        var relocationSize: UInt32
    }

    private static func read16(_ data: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func read32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func read64(_ data: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(read32(data, offset)) | UInt64(read32(data, offset + 4)) << 32
    }

    private static func parsePE(_ data: [UInt8]) -> PEInfo? {
        guard data.count >= 0x40, data[0] == 0x4D, data[1] == 0x5A else { return nil } // "MZ"
        let peOffset = Int(read32(data, 0x3C))
        guard peOffset + 24 <= data.count,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0, data[peOffset + 3] == 0 else { return nil } // "PE\0\0"
        let coff = peOffset + 4
        let machine = read16(data, coff)
        let sectionCount = Int(read16(data, coff + 2))
        let optionalSize = Int(read16(data, coff + 16))
        let optional = coff + 20
        guard optional + optionalSize <= data.count, optionalSize >= 112,
              read16(data, optional) == 0x20B else { return nil } // PE32+
        let directoryBase = optional + 112
        var relocationRVA: UInt32 = 0
        var relocationSize: UInt32 = 0
        if directoryBase + 6 * 8 <= data.count {
            relocationRVA = read32(data, directoryBase + 5 * 8)
            relocationSize = read32(data, directoryBase + 5 * 8 + 4)
        }
        return PEInfo(
            machine: machine,
            subsystem: read32(data, optional + 68),
            imageBase: read64(data, optional + 24),
            entryRVA: read32(data, optional + 16),
            sizeOfImage: read32(data, optional + 56),
            sizeOfHeaders: read32(data, optional + 60),
            sectionTableOffset: optional + optionalSize,
            sectionCount: sectionCount,
            relocationRVA: relocationRVA,
            relocationSize: relocationSize
        )
    }

    /// UEFI アプリケーションを起動する。CPU はロングモードで開始する。
    static func boot(cpu: X86CPU, imageData: [UInt8]) throws {
        guard let info = parsePE(imageData) else { throw UEFIError.notUEFIApplication }
        guard info.machine == 0x8664 else { throw UEFIError.unsupportedMachine(info.machine) }
        let imageBase = Int(info.imageBase)
        guard imageBase >= 0x110000, imageBase + Int(info.sizeOfImage) <= heapStart else {
            throw UEFIError.imageTooLarge
        }

        let firmware = Firmware(cpu: cpu, imageBase: info.imageBase, sizeOfImage: Int(info.sizeOfImage))

        // ヘッダとセクションを配置
        var image = [UInt8](repeating: 0, count: Int(info.sizeOfImage))
        let headerCount = min(Int(info.sizeOfHeaders), imageData.count, image.count)
        image.replaceSubrange(0..<headerCount, with: imageData[0..<headerCount])
        for index in 0..<info.sectionCount {
            let section = info.sectionTableOffset + index * 40
            guard section + 40 <= imageData.count else { break }
            let virtualSize = Int(read32(imageData, section + 8))
            let virtualAddress = Int(read32(imageData, section + 12))
            let rawSize = Int(read32(imageData, section + 16))
            let rawPointer = Int(read32(imageData, section + 20))
            let wanted = min(rawSize, virtualSize == 0 ? rawSize : virtualSize)
            let copyCount = min(wanted, image.count - virtualAddress, imageData.count - rawPointer)
            guard copyCount > 0 else { continue }
            image.replaceSubrange(virtualAddress..<(virtualAddress + copyCount),
                                  with: imageData[rawPointer..<(rawPointer + copyCount)])
        }
        cpu.loadData(image, at: imageBase)
        // イメージは常に ImageBase へ配置するため再配置は不要

        firmware.installStructures()
        // Firmware はフックのクロージャが強参照で保持する
        // （CPU が生きている間サービスを提供し続ける）。
        cpu.preExecuteHook = { address in
            firmware.handleStub(address: address)
        }

        // 戻り先トラップ（cli; hlt; jmp $）を植えてアプリの RET で止まるようにする
        cpu.loadData([0xFA, 0xF4, 0xEB, 0xFE], at: returnTrapAddress)
        let returnAddress = returnTrapAddress
        var stackBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { stackBytes[i] = UInt8((returnAddress >> (8 * i)) & 0xFF) }
        cpu.loadData(stackBytes, at: stackTop - 8)

        cpu.enterLongMode(
            entry: info.imageBase + UInt64(info.entryRVA),
            stackTop: UInt64(stackTop - 8),
            arg1: info.imageBase, // ImageHandle
            arg2: UInt64(systemTableAddress), // SystemTable
            pageTableBase: UInt32(pml4Address),
            gdtBase: UInt32(gdtAddress), gdtLimit: 0x17,
            idtBase: UInt32(idtAddress), idtLimit: 0xFFF
        )
    }

    // MARK: - ファームウェア本体

    /// サービスの識別子（スタブの並び順）。
    private enum Service: Int {
        case conOutReset = 0, conOutOutputString, conOutTestString, conOutQueryMode,
             conOutSetMode, conOutSetAttribute, conOutClearScreen, conOutSetCursorPosition,
             conOutEnableCursor
        case bsRaiseTPL = 16, bsRestoreTPL, bsAllocatePages, bsFreePages, bsGetMemoryMap,
             bsAllocatePool, bsFreePool, bsExitBootServices, bsStall, bsSetWatchdogTimer,
             bsCopyMem, bsSetMem, bsCalculateCrc32, bsLocateProtocol, bsGetNextMonotonicCount
        case rsResetSystem = 48
        case unsupported = 63
    }

    private final class Firmware {
        unowned let cpu: X86CPU
        let imageBase: UInt64
        let sizeOfImage: Int
        private var heapPointer = X86UEFI.heapStart
        private var mapKey: UInt64 = 0
        private var monotonicCount: UInt64 = 0
        private var exitedBootServices = false

        // EFI_STATUS
        private let success: UInt64 = 0
        private let invalidParameter: UInt64 = 0x8000000000000002
        private let unsupportedStatus: UInt64 = 0x8000000000000003
        private let bufferTooSmall: UInt64 = 0x8000000000000005
        private let outOfResources: UInt64 = 0x8000000000000009
        private let notFound: UInt64 = 0x800000000000000E

        init(cpu: X86CPU, imageBase: UInt64, sizeOfImage: Int) {
            self.cpu = cpu
            self.imageBase = imageBase
            self.sizeOfImage = sizeOfImage
        }

        // MARK: メモリアクセス（アイデンティティマップ前提）

        private func read(_ address: UInt64, size: Int) -> UInt64 {
            (try? cpu.readMemoryValue(at: Int(address), size: size)) ?? 0
        }

        private func write(_ address: UInt64, _ value: UInt64, size: Int) {
            try? cpu.writeMemoryValue(at: Int(address), size: size, value)
        }

        private func stubAddress(_ service: Service) -> UInt64 {
            UInt64(X86UEFI.stubBase + service.rawValue * 16)
        }

        // MARK: 構造体の配置

        func installStructures() {
            installPageTablesAndGDT()
            installIDT()
            installSystemTable()
            installConOut()
            installBootServices()
            installRuntimeServices()
            // スタブ領域は RET で埋める（フックが横取りするので通常は実行されない）
            var stubs = [UInt8](repeating: 0x90, count: 0x1000)
            for index in 0..<64 { stubs[index * 16] = 0xC3 }
            // IDT 用ダミーハンドラ（iretq）
            stubs[0xF00] = 0x48
            stubs[0xF01] = 0xCF
            cpu.loadData(stubs, at: X86UEFI.stubBase)
        }

        private func installPageTablesAndGDT() {
            var pml4 = [UInt8](repeating: 0, count: 4096)
            put64(&pml4, 0, UInt64(X86UEFI.pdptAddress) | 0x3)
            cpu.loadData(pml4, at: X86UEFI.pml4Address)
            var pdpt = [UInt8](repeating: 0, count: 4096)
            put64(&pdpt, 0, UInt64(X86UEFI.pdAddress) | 0x3)
            cpu.loadData(pdpt, at: X86UEFI.pdptAddress)
            var pd = [UInt8](repeating: 0, count: 4096)
            for index in 0..<8 { // 2 MiB × 8 = 16 MiB をアイデンティティマップ
                put64(&pd, index * 8, UInt64(index) * 0x200000 | 0x83)
            }
            cpu.loadData(pd, at: X86UEFI.pdAddress)
            var gdt = [UInt8](repeating: 0, count: 24)
            // 64 ビット コード: L=1, D=0, P=1, DPL=0, S=1, Type=1010
            put64(&gdt, 8, 0x00AF9A000000FFFF)
            // データ
            put64(&gdt, 16, 0x00CF92000000FFFF)
            cpu.loadData(gdt, at: X86UEFI.gdtAddress)
        }

        private func installIDT() {
            var idt = [UInt8](repeating: 0, count: 4096)
            let handler = UInt64(X86UEFI.idtStubAddress)
            for index in 0..<256 {
                let offset = index * 16
                put16(&idt, offset, UInt16(handler & 0xFFFF))
                put16(&idt, offset + 2, 0x08)
                idt[offset + 4] = 0 // IST
                idt[offset + 5] = 0x8E // 割り込みゲート（存在・DPL 0）
                put16(&idt, offset + 6, UInt16((handler >> 16) & 0xFFFF))
                put32(&idt, offset + 8, UInt32(handler >> 32))
            }
            cpu.loadData(idt, at: X86UEFI.idtAddress)
        }

        private func installSystemTable() {
            var table = [UInt8](repeating: 0, count: 120)
            put64(&table, 0, 0x5453595320494249) // "IBI SYST"
            put32(&table, 8, 0x0002000A) // Revision 2.10
            put32(&table, 12, 120) // HeaderSize
            put64(&table, 40, imageBase) // ConsoleInHandle（ダミー）
            put64(&table, 48, 0) // ConIn（未提供）
            put64(&table, 56, imageBase) // ConsoleOutHandle
            put64(&table, 64, UInt64(X86UEFI.conOutAddress)) // ConOut
            put64(&table, 72, imageBase) // StandardErrorHandle
            put64(&table, 80, UInt64(X86UEFI.conOutAddress)) // StdErr
            put64(&table, 88, UInt64(X86UEFI.runtimeServicesAddress))
            put64(&table, 96, UInt64(X86UEFI.bootServicesAddress))
            put64(&table, 104, 1) // NumberOfTableEntries
            put64(&table, 112, UInt64(X86UEFI.configTableAddress))
            // ConfigurationTable: ACPI 2.0 の GUID → RSDP
            var config = [UInt8](repeating: 0, count: 24)
            let acpiGUID: [UInt8] = [0x71, 0xE8, 0x68, 0x88, 0xF1, 0xE4, 0xD3, 0x11,
                                     0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81]
            config.replaceSubrange(0..<16, with: acpiGUID)
            put64(&config, 16, 0xE0000)
            cpu.loadData(config, at: X86UEFI.configTableAddress)
            // CRC32（フィールドを 0 にして計算し、書き込む）
            let crc = X86UEFI.crc32(table)
            put32(&table, 16, crc)
            cpu.loadData(table, at: X86UEFI.systemTableAddress)
        }

        private func installConOut() {
            var conOut = [UInt8](repeating: 0, count: 80)
            put64(&conOut, 0, stubAddress(.conOutReset))
            put64(&conOut, 8, stubAddress(.conOutOutputString))
            put64(&conOut, 16, stubAddress(.conOutTestString))
            put64(&conOut, 24, stubAddress(.conOutQueryMode))
            put64(&conOut, 32, stubAddress(.conOutSetMode))
            put64(&conOut, 40, stubAddress(.conOutSetAttribute))
            put64(&conOut, 48, stubAddress(.conOutClearScreen))
            put64(&conOut, 56, stubAddress(.conOutSetCursorPosition))
            put64(&conOut, 64, stubAddress(.conOutEnableCursor))
            put64(&conOut, 72, UInt64(X86UEFI.conOutModeAddress))
            cpu.loadData(conOut, at: X86UEFI.conOutAddress)
            var mode = [UInt8](repeating: 0, count: 28)
            put32(&mode, 20, 1) // CursorVisible
            cpu.loadData(mode, at: X86UEFI.conOutModeAddress)
        }

        private func installBootServices() {
            var services = [UInt8](repeating: 0, count: 376)
            put64(&services, 0, 0x56524553544F4F42) // "BOOTSERV"
            put32(&services, 8, 0x0002000A)
            put32(&services, 12, 376)
            let generic = stubAddress(.unsupported)
            for offset in stride(from: 24, to: 376, by: 8) {
                put64(&services, offset, generic)
            }
            put64(&services, 24, stubAddress(.bsRaiseTPL))
            put64(&services, 32, stubAddress(.bsRestoreTPL))
            put64(&services, 40, stubAddress(.bsAllocatePages))
            put64(&services, 48, stubAddress(.bsFreePages))
            put64(&services, 56, stubAddress(.bsGetMemoryMap))
            put64(&services, 64, stubAddress(.bsAllocatePool))
            put64(&services, 72, stubAddress(.bsFreePool))
            put64(&services, 232, stubAddress(.bsExitBootServices))
            put64(&services, 240, stubAddress(.bsGetNextMonotonicCount))
            put64(&services, 248, stubAddress(.bsStall))
            put64(&services, 256, stubAddress(.bsSetWatchdogTimer))
            put64(&services, 320, stubAddress(.bsLocateProtocol))
            put64(&services, 344, stubAddress(.bsCalculateCrc32))
            put64(&services, 352, stubAddress(.bsCopyMem))
            put64(&services, 360, stubAddress(.bsSetMem))
            let crc = X86UEFI.crc32(services)
            put32(&services, 16, crc)
            cpu.loadData(services, at: X86UEFI.bootServicesAddress)
        }

        private func installRuntimeServices() {
            var services = [UInt8](repeating: 0, count: 136)
            put64(&services, 0, 0x56524553544E5252) // ランタイムサービス署名
            put32(&services, 8, 0x0002000A)
            put32(&services, 12, 136)
            let generic = stubAddress(.unsupported)
            for offset in stride(from: 24, to: 136, by: 8) {
                put64(&services, offset, generic)
            }
            put64(&services, 104, stubAddress(.rsResetSystem)) // ResetSystem
            let crc = X86UEFI.crc32(services)
            put32(&services, 16, crc)
            cpu.loadData(services, at: X86UEFI.runtimeServicesAddress)
        }

        // MARK: スタブ横取り

        /// RIP がスタブ範囲ならサービスを実行し、戻り先へ RIP を移す。
        func handleStub(address: UInt64) -> Bool {
            let base = UInt64(X86UEFI.stubBase)
            guard address >= base, address < base + 0x1000 else { return false }
            let index = Int((address - base) / 16)
            guard let service = Service(rawValue: index) else { return false }
            let result = perform(service)
            if service == .rsResetSystem { return true } // 停止済み
            // 戻りアドレスをポップして RIP を戻す
            let stackPointer = cpu.register64(4)
            let returnAddress = read(stackPointer, size: 8)
            cpu.setRegister64(4, stackPointer + 8)
            cpu.redirectExecution(to: returnAddress)
            cpu.setRegister64(0, result)
            return true
        }

        private func perform(_ service: Service) -> UInt64 {
            let rcx = cpu.register64(1)
            let rdx = cpu.register64(2)
            let r8 = cpu.register64(8)
            let r9 = cpu.register64(9)
            switch service {
            // ConOut
            case .conOutReset:
                return success
            case .conOutOutputString:
                outputString(at: rdx)
                return success
            case .conOutTestString:
                return success
            case .conOutQueryMode:
                guard rdx == 0 else { return unsupportedStatus }
                write(r8, 80, size: 8)
                write(r9, 25, size: 8)
                return success
            case .conOutSetMode:
                return rdx == 0 ? success : unsupportedStatus
            case .conOutSetAttribute, .conOutSetCursorPosition, .conOutEnableCursor:
                return success
            case .conOutClearScreen:
                cpu.onClearScreen?()
                return success
            // BootServices
            case .bsRaiseTPL:
                return 0
            case .bsRestoreTPL, .bsFreePages, .bsFreePool, .bsStall, .bsSetWatchdogTimer:
                return success
            case .bsAllocatePages:
                // RCX=Type, RDX=MemoryType, R8=Pages, R9=*Memory
                return allocatePages(pages: r8, pointerAddress: r9)
            case .bsAllocatePool:
                // RCX=PoolType, RDX=Size, R8=*Buffer
                return allocatePool(bytes: rdx, pointerAddress: r8)
            case .bsGetMemoryMap:
                return getMemoryMap(sizeAddress: rcx, mapAddress: rdx, keyAddress: r8,
                                    descriptorSizeAddress: r9)
            case .bsExitBootServices:
                guard rdx == mapKey else { return invalidParameter }
                exitedBootServices = true
                return success
            case .bsGetNextMonotonicCount:
                monotonicCount += 1
                write(rdx, monotonicCount, size: 8)
                return success
            case .bsCopyMem:
                copyMemory(destination: rcx, source: rdx, length: r8)
                return success
            case .bsSetMem:
                setMemory(destination: rcx, length: rdx, value: UInt8(r8 & 0xFF))
                return success
            case .bsCalculateCrc32:
                let crc = crc32OfMemory(at: rcx, length: rdx)
                write(r8, UInt64(crc), size: 4)
                return success
            case .bsLocateProtocol:
                return notFound
            case .rsResetSystem:
                cpu.halt(exitCode: 0)
                return success
            case .unsupported:
                return unsupportedStatus
            }
        }

        // MARK: サービス実装

        private func outputString(at address: UInt64) {
            var pointer = address
            var guardCount = 0
            while guardCount < 4096 {
                let unit = read(pointer, size: 2)
                if unit == 0 { break }
                if unit == 0x0D {
                    // CR は無視（LF で改行する）
                } else if unit < 0x80 {
                    cpu.onChar?(UInt8(unit))
                } else {
                    cpu.onChar?(0x3F) // '?'
                }
                pointer += 2
                guardCount += 1
            }
        }

        private func allocatePages(pages: UInt64, pointerAddress: UInt64) -> UInt64 {
            let byteCount = Int(pages) * 4096
            guard heapPointer + byteCount <= X86UEFI.heapEnd else { return outOfResources }
            let address = heapPointer
            heapPointer += byteCount
            write(pointerAddress, UInt64(address), size: 8)
            return success
        }

        private func allocatePool(bytes: UInt64, pointerAddress: UInt64) -> UInt64 {
            let byteCount = max(16, (Int(bytes) + 15) & ~15)
            guard heapPointer + byteCount <= X86UEFI.heapEnd else { return outOfResources }
            let address = heapPointer
            heapPointer += byteCount
            write(pointerAddress, UInt64(address), size: 8)
            return success
        }

        private func memoryRegions() -> [(start: UInt64, pages: UInt64, type: UInt32)] {
            let imagePages = UInt64((sizeOfImage + 4095) / 4096)
            return [
                (0x000000, 0x80, 7), // 通常メモリ（0〜512 KiB）
                (0x080000, 0x80, 0), // 予約（BIOS / ACPI 領域を含む）
                (0x100000, 0x100, 3), // ファームウェア構造（ページ表・GDT・IDT）
                (imageBase, imagePages, 2), // ローダコード（イメージ）
                (0x300000, 0x10, 3), // システムテーブル等
                (0x310000, 0xE0, 7), // 通常メモリ
                (0x3F0000, 0x10, 3), // スタック
                (0x400000, 0xC00, 7), // 通常メモリ（ヒープを含む）
            ]
        }

        private func getMemoryMap(sizeAddress: UInt64, mapAddress: UInt64, keyAddress: UInt64,
                                  descriptorSizeAddress: UInt64) -> UInt64 {
            let regions = memoryRegions()
            let descriptorSize = 40
            let required = regions.count * descriptorSize
            let provided = Int(read(sizeAddress, size: 8))
            mapKey += 1
            write(keyAddress, mapKey, size: 8)
            write(descriptorSizeAddress, UInt64(descriptorSize), size: 8)
            // 5 番目の引数（DescriptorVersion へのポインタ）はスタック上
            let stackPointer = cpu.register64(4)
            let versionAddress = read(stackPointer + 40, size: 8)
            if versionAddress != 0 { write(versionAddress, 1, size: 4) }
            guard mapAddress != 0, provided >= required else {
                write(sizeAddress, UInt64(required), size: 8)
                return bufferTooSmall
            }
            for (index, region) in regions.enumerated() {
                let base = mapAddress + UInt64(index * descriptorSize)
                write(base, UInt64(region.type), size: 4)
                write(base + 8, region.start, size: 8)
                write(base + 16, 0, size: 8) // VirtualStart（未使用）
                write(base + 24, region.pages, size: 8)
                write(base + 32, 0xF, size: 8) // Attribute
            }
            write(sizeAddress, UInt64(required), size: 8)
            return success
        }

        private func copyMemory(destination: UInt64, source: UInt64, length: UInt64) {
            var offset: UInt64 = 0
            while offset < length {
                let value = read(source + offset, size: 1)
                write(destination + offset, value, size: 1)
                offset += 1
            }
        }

        private func setMemory(destination: UInt64, length: UInt64, value: UInt8) {
            var offset: UInt64 = 0
            while offset < length {
                write(destination + offset, UInt64(value), size: 1)
                offset += 1
            }
        }

        private func crc32OfMemory(at address: UInt64, length: UInt64) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            var offset: UInt64 = 0
            while offset < length {
                let byte = UInt32(read(address + offset, size: 1))
                crc = crcTable[Int((crc ^ byte) & 0xFF)] ^ (crc >> 8)
                offset += 1
            }
            return crc ^ 0xFFFFFFFF
        }
    }

    // MARK: - バイト列ユーティリティ

    private static func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static func put64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
