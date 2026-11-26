import Foundation

/// 最小 UEFI ファームウェア（自作）。
///
/// PE32+（x86-64）イメージを ImageBase へ配置し、ロングモードで
/// エントリポイントを呼ぶ。UEFI の呼び出し規約どおり、RCX に
/// ImageHandle、RDX に SystemTable ポインタを渡す。
/// サービス関数はスタブアドレスを CPU の preExecuteHook で横取りし、
/// Swift 側でネイティブ実行する（ゲストコードは実行されない）。
///
/// 提供するサービス: コンソール出力、ブートサービス一式
/// （メモリ確保、プロトコル DB、LoadImage / StartImage / Exit、
/// イベント / タイマ、GetMemoryMap 等）、Block I/O、Simple File
/// System（FAT）、GOP（フレームバッファ）、変数サービス、
/// ランタイムサービス（時刻・変数・リセット）。
/// ただしドライバモデルや通知関数の呼び出しは簡略化しており、
/// Windows Boot Manager や GRUB のような本格的なブートローダの
/// 起動はまだ保証できない（README / リリースノートに明記）。
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
    static let idtStubAddress = 0x301FF0
    static let consoleHandleAddress = 0x300800
    static let diskHandleAddress = 0x300810
    static let blockIOAddress = 0x300900
    static let blockIOMediaAddress = 0x300980
    static let sfsAddress = 0x300A00
    static let devicePathAddress = 0x300A80
    static let loadedImageAddress = 0x300B00
    static let gopAddress = 0x300C00
    static let gopModeAddress = 0x300C40
    static let gopInfoAddress = 0x300C80
    static let conInAddress = 0x300D00
    /// LoadImage で配置するイメージの領域（RAM 末尾 1 MiB）
    static let loadRegionStart = 0xF00000
    static let loadRegionEnd = 0x1000000
    static let protocolArenaStart = 0x305000
    static let protocolArenaEnd = 0x310000
    static let returnTrapAddress = 0x3FF000
    static let stackTop = 0x400000
    static let heapStart = 0x500000
    static let heapEnd = 0xF00000

    /// UEFI 変数 1 件（永続化のためにセッションと受け渡す）。
    struct Variable: Equatable {
        var guid: [UInt8]
        var name: String
        var attributes: UInt32
        var data: [UInt8]
    }

    /// Authenticode イメージハッシュ（SHA-256）。チェックサムフィールドと
    /// 証明書テーブルエントリ・証明書テーブル本体を除いてハッシュする。
    static func authenticodeHash(_ data: [UInt8]) -> [UInt8]? {
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard data.count > 0x40, data[0] == 0x4D, data[1] == 0x5A else { return nil }
        let peOffset = u32(0x3C)
        guard peOffset > 0, peOffset + 24 + 112 + 40 <= data.count else { return nil }
        let optional = peOffset + 24
        guard u16(optional) == 0x20B else { return nil } // PE32+
        let checksumOffset = optional + 64
        let certEntryOffset = optional + 112 + 4 * 8
        guard u32(optional + 108) > 4 else { return nil } // NumberOfRvaAndSizes
        let certSize = u32(certEntryOffset + 4)
        var hashed = [UInt8]()
        hashed.reserveCapacity(data.count)
        hashed += data[0..<checksumOffset]
        hashed += data[(checksumOffset + 4)..<certEntryOffset]
        let end = certSize > 0 ? data.count - certSize : data.count
        guard end >= certEntryOffset + 8, end <= data.count else { return nil }
        hashed += data[(certEntryOffset + 8)..<end]
        return SHA256.hash(hashed)
    }

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
            subsystem: UInt32(read16(data, optional + 68)), // Subsystem は 2 バイト
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
    /// - initialVariables: 前回セッションから引き継ぐ変数（永続化用）。
    /// - onVariablesChanged: 変数が変更されるたびに現在の全変数を渡す。
    /// 起動中のファームウェア（セッションからの ConIn / 通知 / GOP 参照用）。
    private static var activeFirmwares: [ObjectIdentifier: Firmware] = [:]

    /// アプリのキー入力を ConIn キューへ届ける。
    static func pushConInText(cpu: X86CPU, text: String) {
        activeFirmwares[ObjectIdentifier(cpu)]?.pushKeys(text)
    }

    /// 保留中のイベント通知があれば 1 件届ける（セッションループ用）。
    static func deliverPendingNotifications(cpu: X86CPU) {
        activeFirmwares[ObjectIdentifier(cpu)]?.deliverNotifications()
    }

    /// GOP フレームバッファの位置と大きさ（アプリの画面表示用）。
    static func gopFramebufferInfo(cpu: X86CPU) -> (base: Int, width: Int, height: Int)? {
        activeFirmwares[ObjectIdentifier(cpu)]?.gopFramebuffer
    }

    static func boot(cpu: X86CPU, imageData: [UInt8],
                     initialVariables: [Variable] = [],
                     onVariablesChanged: (([Variable]) -> Void)? = nil) throws {
        guard let info = parsePE(imageData) else { throw UEFIError.notUEFIApplication }
        guard info.machine == 0x8664 else { throw UEFIError.unsupportedMachine(info.machine) }
        let imageBase = Int(info.imageBase)
        guard imageBase >= 0x110000, imageBase + Int(info.sizeOfImage) <= heapStart else {
            throw UEFIError.imageTooLarge
        }

        let firmware = Firmware(cpu: cpu, imageBase: info.imageBase,
                                sizeOfImage: Int(info.sizeOfImage),
                                initialVariables: initialVariables,
                                onVariablesChanged: onVariablesChanged)

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
        // 起動イメージは常に ImageBase へ配置するため再配置は不要

        activeFirmwares[ObjectIdentifier(cpu)] = firmware
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

    /// PE イメージを `base` へ配置する（ヘッダ + セクション）。
    /// ImageBase と異なる場所へ置く場合は DIR64 再配置を適用する。
    /// 再配置情報が無くベースが異なる場合は false を返す。
    private static func stageImage(cpu: X86CPU, data: [UInt8], info: PEInfo, base: Int) -> Bool {
        var image = [UInt8](repeating: 0, count: Int(info.sizeOfImage))
        let headerCount = min(Int(info.sizeOfHeaders), data.count, image.count)
        image.replaceSubrange(0..<headerCount, with: data[0..<headerCount])
        for index in 0..<info.sectionCount {
            let section = info.sectionTableOffset + index * 40
            guard section + 40 <= data.count else { break }
            let virtualSize = Int(read32(data, section + 8))
            let virtualAddress = Int(read32(data, section + 12))
            let rawSize = Int(read32(data, section + 16))
            let rawPointer = Int(read32(data, section + 20))
            let wanted = min(rawSize, virtualSize == 0 ? rawSize : virtualSize)
            let copyCount = min(wanted, image.count - virtualAddress, data.count - rawPointer)
            guard copyCount > 0 else { continue }
            image.replaceSubrange(virtualAddress..<(virtualAddress + copyCount),
                                  with: data[rawPointer..<(rawPointer + copyCount)])
        }
        let delta = Int64(base) - Int64(info.imageBase)
        if delta != 0 {
            guard info.relocationSize >= 8 else { return false }
            var offset = Int(info.relocationRVA)
            let end = offset + Int(info.relocationSize)
            while offset + 8 <= end, offset + 8 <= image.count {
                let pageRVA = Int(read32(image, offset))
                let blockSize = Int(read32(image, offset + 4))
                guard blockSize >= 8, offset + blockSize <= image.count else { break }
                var entryOffset = offset + 8
                while entryOffset + 2 <= offset + blockSize {
                    let entry = read16(image, entryOffset)
                    let relocType = entry >> 12
                    if relocType != 0 && relocType != 10 {
                        return false   // 未対応の再配置は黙って読み込むより失敗させる
                    }
                    if relocType == 10 { // IMAGE_REL_BASED_DIR64
                        let target = pageRVA + Int(entry & 0xFFF)
                        guard target + 8 <= image.count else { return false }
                        let value = read64(image, target)
                        let adjusted = UInt64(bitPattern: Int64(bitPattern: value) + delta)
                        for i in 0..<8 {
                            image[target + i] = UInt8((adjusted >> (8 * i)) & 0xFF)
                        }
                    }
                    entryOffset += 2
                }
                offset += blockSize
            }
        }
        cpu.loadData(image, at: base)
        return true
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
        case bsInstallProtocolInterface = 31, bsUninstallProtocolInterface, bsHandleProtocol,
             bsOpenProtocol, bsCloseProtocol, bsProtocolsPerHandle, bsLocateHandleBuffer,
             bsInstallConfigurationTable
        case bioReset = 40, bioReadBlocks, bioWriteBlocks, bioFlushBlocks
        case sfsOpenVolume = 44
        case rsResetSystem = 48
        case fileOpen = 50, fileClose, fileDelete, fileRead, fileWrite, fileGetPosition,
             fileSetPosition, fileGetInfo, fileSetInfo, fileFlush
        case unsupported = 63
        case rsGetVariable = 70, rsGetNextVariableName, rsSetVariable, rsQueryVariableInfo
        case bsCreateEvent = 80, bsSetTimer, bsWaitForEvent, bsSignalEvent, bsCloseEvent,
             bsCheckEvent, bsLoadImage, bsStartImage, bsExit, bsUnloadImage,
             bsLocateHandle, bsLocateDevicePath, bsReinstallProtocolInterface,
             bsInstallMultipleProtocolInterfaces, bsUninstallMultipleProtocolInterfaces,
             bsOpenProtocolInformation, bsConnectController, bsDisconnectController,
             bsRegisterProtocolNotify, bsCreateEventEx
        case gopQueryMode = 100, gopSetMode, gopBlt
        case conInReset = 103, conInReadKey
        case rsGetTime = 110, rsSetTime, rsGetWakeupTime, rsSetWakeupTime,
             rsSetVirtualAddressMap, rsConvertPointer, rsGetNextHighMonotonicCount,
             rsUpdateCapsule, rsQueryCapsuleCapabilities
        /// StartImage で起動したイメージの戻り先（どの表にも載せない内部用）
        case imageReturnTrap = 120
        /// 通知関数 / ドライババインディング呼び出しの戻り先（内部用）
        case guestCallTrap = 121
    }

    private final class Firmware {
        unowned let cpu: X86CPU
        let imageBase: UInt64
        let sizeOfImage: Int
        // メモリアロケータ: ヒープ領域（heapStart–heapEnd）を 4 KiB ページ単位で管理する
        private enum PageRecordKind { case guest, pool, firmware }
        private var pageUsed = [Bool](repeating: false, count: (X86UEFI.heapEnd - X86UEFI.heapStart) / 4096)
        private var pageTypes = [UInt32](repeating: 7, count: (X86UEFI.heapEnd - X86UEFI.heapStart) / 4096)
        private var pageRecords: [Int: (pages: Int, memoryType: UInt32, kind: PageRecordKind)] = [:]
        private var poolFreeBlocks: [(address: UInt64, size: Int)] = []
        private var poolAllocations: [UInt64: Int] = [:]
        private var guestCallStacks: [UInt64] = []
        private var imageCallStacks: [UInt64] = []
        private var imageRegionAllocations: [(base: Int, size: Int)] = []
        private var mapKey: UInt64 = 0
        private var monotonicCount: UInt64 = 0
        private var exitedBootServices = false
        private var virtualAddressMap: [(physical: UInt64, virtual: UInt64, pages: UInt64)] = []
        private var virtualAddressMapSet = false

        // プロトコルデータベース（ハンドル → GUID → インターフェイス）
        private var protocolDB: [UInt64: [[UInt8]: UInt64]] = [:]
        private var handleOrder: [UInt64] = []
        private var arenaPointer = X86UEFI.protocolArenaStart
        // ディスク（Block I/O と Simple File System の共有裏付け）
        private var diskStorage: FATVolume.Storage?
        private var fatVolume: FATVolume?
        private var fileObjects: [UInt64: FileObject] = [:]
        // UEFI 変数（挿入順を保持）
        private var variables: [X86UEFI.Variable]
        private let onVariablesChanged: (([X86UEFI.Variable]) -> Void)?
        // イベント / タイマ
        private var events: [UInt64: EventObject] = [:]
        // ConIn（キー入力キューはアプリスレッドからも触るためロックする）
        private var keyQueue: [(scan: UInt16, unicode: UInt16)] = []
        private let keyQueueLock = NSLock()
        private var conInEvent: EventObject?
        private var conInEventHandle: UInt64 = 0
        // イベント通知（キューに入れてセッションループから届ける）
        private var notifyQueue: [UInt64] = []
        private var protocolNotifyRegistrations: [(guid: [UInt8], event: UInt64)] = []
        // ゲスト関数呼び出し（通知 / ドライババインディング）のフレーム
        private var guestCallStack: [GuestCallFrame] = []
        // ConnectController で開始済みのドライバ（コントローラごと）
        private var startedDrivers: [UInt64: [(interface: UInt64, imageHandle: UInt64)]] = [:]
        // LoadImage で読み込んだイメージ
        private var loadedImages: [UInt64: LoadedImageInfo] = [:]
        // StartImage の呼び出しフレーム（戻り先の復元用）
        private var imageCallStack: [ImageCallFrame] = []
        // GOP フレームバッファ
        private var framebufferBase = 0
        private let gopModes: [(width: Int, height: Int)] = [(640, 400), (800, 600), (1024, 768)]
        private var gopCurrentMode = 0
        private var framebufferWidth: Int { gopModes[gopCurrentMode].width }
        private var framebufferHeight: Int { gopModes[gopCurrentMode].height }
        private var highMonotonicCount: UInt64 = 0
        // 構成テーブル（初期値は ACPI 2.0 → RSDP と SMBIOS）
        private var configEntries: [(guid: [UInt8], table: UInt64)] = [
            ([0x71, 0xE8, 0x68, 0x88, 0xF1, 0xE4, 0xD3, 0x11,
              0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81], 0xE0000),
            ([0x31, 0x2D, 0x9D, 0xEB, 0x88, 0x2D, 0xD3, 0x11,
              0x9A, 0x16, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D], 0xE2000),
        ]

        // よく使う GUID（メモリ表現: 先頭 3 フィールドはリトルエンディアン）
        private let guidConOut: [UInt8] = [0xC2, 0x77, 0x74, 0x38, 0xC7, 0x69, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidBlockIO: [UInt8] = [0x21, 0x5B, 0x4E, 0x96, 0x59, 0x64, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidSFS: [UInt8] = [0x22, 0x5B, 0x4E, 0x96, 0x59, 0x64, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidDevicePath: [UInt8] = [0x91, 0x6E, 0x57, 0x09, 0x3F, 0x6D, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidFileInfo: [UInt8] = [0x92, 0x6E, 0x57, 0x09, 0x3F, 0x6D, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidFileSystemInfo: [UInt8] = [0x93, 0x6E, 0x57, 0x09, 0x3F, 0x6D, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidVolumeLabel: [UInt8] = [0xD3, 0xD7, 0x47, 0xDB, 0x81, 0xFE, 0xD3, 0x11, 0x86, 0xA1, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidLoadedImage: [UInt8] = [0xA1, 0x31, 0x1B, 0x5B, 0x62, 0x95, 0xD2, 0x11, 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidGOP: [UInt8] = [0xDE, 0xA9, 0x42, 0x90, 0xDC, 0x23, 0x38, 0x4A, 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A]
        private let guidConIn: [UInt8] = [0x31, 0x5D, 0xB2, 0xD3, 0x54, 0x1B, 0xD2, 0x11, 0x8E, 0x4F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B]
        private let guidGlobalVariable: [UInt8] = [0x61, 0xDF, 0xE4, 0x8B, 0xCA, 0x93, 0xD2, 0x11, 0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C]
        private let guidImageSecurityDB: [UInt8] = [0xCB, 0xB2, 0x19, 0xD7, 0x3A, 0x3D, 0x96, 0x45, 0xA3, 0xBC, 0xDA, 0xD0, 0x0E, 0x67, 0x65, 0x6F]
        private let guidCertSHA256: [UInt8] = [0x26, 0x16, 0xC4, 0xC1, 0x4C, 0x50, 0x99, 0x40, 0xAC, 0xA9, 0x41, 0xF9, 0x36, 0x93, 0x43, 0x28]
        private let guidEventGroupEBS: [UInt8] = [0x55, 0xF0, 0xAB, 0x27, 0xB8, 0xB1, 0x86, 0x4C, 0x80, 0x43, 0x74, 0x8E, 0xA6, 0xBF, 0xFD, 0xE9]
        private let guidEventGroupVAC: [UInt8] = [0x6B, 0xD5, 0xF2, 0x40, 0x76, 0x93, 0x4D, 0x42, 0xA9, 0xFE, 0x99, 0x6F, 0x61, 0xFD, 0x2F, 0x66]
        private let guidDriverBinding: [UInt8] = [0xAB, 0x31, 0xA0, 0x18, 0x43, 0xB4, 0x1A, 0x4D, 0xA5, 0xC0, 0x0C, 0x09, 0x26, 0x1E, 0x9F, 0x71]
        private let deviceError: UInt64 = 0x8000000000000007

        /// EFI_EVENT の Swift 側の状態。
        private final class EventObject {
            var type: UInt32 = 0
            var notifyFunction: UInt64 = 0
            var notifyContext: UInt64 = 0
            var signaled = false
            /// タイマ種別（0 = 停止、1 = 周期、2 = 相対）
            var timerType: UInt64 = 0
            var timerPeriod100ns: UInt64 = 0
            var timerDue: Date?
            var eventGroup: [UInt8]?
        }

        /// LoadImage で配置したイメージの情報。
        private struct LoadedImageInfo {
            var base: UInt64
            var size: Int
            var entry: UInt64
            var parentHandle: UInt64
            var loadedImageStruct: UInt64
        }

        /// ゲスト関数呼び出しのフレーム（通知関数 / ドライババインディング）。
        private struct GuestCallFrame {
            var savedRegisters: [UInt64]
            var savedStackPointer: UInt64
            var savedInstructionPointer: UInt64
            var isDriverCall: Bool
            var driverContext: DriverCallContext?
        }

        /// ConnectController / DisconnectController の継続状態。
        private struct DriverCallContext {
            var controller: UInt64
            var remainingPath: UInt64
            var bindings: [(interface: UInt64, imageHandle: UInt64)]
            var index: Int
            var stage: Int // 0 = Supported 呼び出し中、1 = Start 呼び出し中
            var anyStarted: Bool
            var lastError: UInt64
            var disconnect: Bool
        }

        /// StartImage 実行中の呼び出しフレーム。
        private struct ImageCallFrame {
            var handle: UInt64
            var savedRegisters: [UInt64]
            var savedStackPointer: UInt64
            var exitDataSizeAddress: UInt64
            var exitDataAddress: UInt64
        }

        /// EFI_FILE_PROTOCOL の Swift 側の状態。
        private final class FileObject {
            /// ファイルの場合は格納ディレクトリ、ディレクトリの場合は自パス。
            var path: [String] = []
            var entry: FATVolume.Entry?
            var isDirectory = false
            var position: UInt64 = 0
            var directoryIndex = 0
            var writable = false
            var createName: String?
            var writeContents: [UInt8]?
        }

        // EFI_STATUS
        private let success: UInt64 = 0
        private let invalidParameter: UInt64 = 0x8000000000000002
        private let unsupportedStatus: UInt64 = 0x8000000000000003
        private let bufferTooSmall: UInt64 = 0x8000000000000005
        private let notReady: UInt64 = 0x8000000000000006
        private let outOfResources: UInt64 = 0x8000000000000009
        private let notFound: UInt64 = 0x800000000000000E
        private let securityViolation: UInt64 = 0x800000000000001A
        private let writeProtected: UInt64 = 0x8000000000000008

        init(cpu: X86CPU, imageBase: UInt64, sizeOfImage: Int,
             initialVariables: [X86UEFI.Variable],
             onVariablesChanged: (([X86UEFI.Variable]) -> Void)?) {
            self.cpu = cpu
            self.imageBase = imageBase
            self.sizeOfImage = sizeOfImage
            self.variables = initialVariables
            self.onVariablesChanged = onVariablesChanged
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

        /// GOP フレームバッファ情報（アプリの画面表示用）。
        var gopFramebuffer: (base: Int, width: Int, height: Int)? {
            framebufferBase == 0 ? nil : (framebufferBase, framebufferWidth, framebufferHeight)
        }

        /// アプリからのキー入力を ConIn キューへ積む。
        func pushKeys(_ text: String) {
            var keys: [(scan: UInt16, unicode: UInt16)] = []
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\n", "\r": keys.append((0, 0x0D))
                case "\t": keys.append((0, 0x09))
                case "\u{7F}": keys.append((0, 0x08))
                default:
                    if scalar.value <= 0xFFFF { keys.append((0, UInt16(scalar.value))) }
                }
            }
            guard !keys.isEmpty else { return }
            keyQueueLock.lock()
            keyQueue.append(contentsOf: keys)
            keyQueueLock.unlock()
            conInEvent?.signaled = true
        }

        func installStructures() {
            refreshSecureBootVariables()
            // GOP フレームバッファをアロケータから予約する
            let framebufferSize = framebufferWidth * framebufferHeight * 4
            framebufferBase = Int(allocPagesInternal(count: (framebufferSize + 4095) / 4096,
                                                     memoryType: 6, kind: .firmware) ?? 0)
            installPageTablesAndGDT()
            installIDT()
            installSystemTable()
            installConOut()
            installConIn()
            installBootServices()
            installRuntimeServices()
            installProtocols()
            // スタブ領域は RET で埋める（フックが横取りするので通常は実行されない）
            var stubs = [UInt8](repeating: 0x90, count: 0x2000)
            for index in 0..<256 { stubs[index * 16] = 0xC3 }
            // IDT 用ダミーハンドラ（iretq、スタブ番号 255）
            stubs[0xFF0] = 0x48
            stubs[0xFF1] = 0xCF
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
            put64(&table, 40, UInt64(X86UEFI.consoleHandleAddress)) // ConsoleInHandle
            put64(&table, 48, UInt64(X86UEFI.conInAddress)) // ConIn
            put64(&table, 56, UInt64(X86UEFI.consoleHandleAddress)) // ConsoleOutHandle
            put64(&table, 64, UInt64(X86UEFI.conOutAddress)) // ConOut
            put64(&table, 72, imageBase) // StandardErrorHandle
            put64(&table, 80, UInt64(X86UEFI.conOutAddress)) // StdErr
            put64(&table, 88, UInt64(X86UEFI.runtimeServicesAddress))
            put64(&table, 96, UInt64(X86UEFI.bootServicesAddress))
            put64(&table, 104, UInt64(configEntries.count)) // NumberOfTableEntries
            put64(&table, 112, UInt64(X86UEFI.configTableAddress))
            cpu.loadData(table, at: X86UEFI.systemTableAddress)
            // ConfigurationTable を書き、SystemTable の CRC を仕上げる
            writeConfigurationTables()
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

        private func installConIn() {
            let event = EventObject()
            let handle = arenaAlloc(8)
            if handle != 0 {
                events[handle] = event
                conInEvent = event
                conInEventHandle = handle
            }
            var conIn = [UInt8](repeating: 0, count: 24)
            put64(&conIn, 0, stubAddress(.conInReset))
            put64(&conIn, 8, stubAddress(.conInReadKey))
            put64(&conIn, 16, conInEventHandle) // WaitForEvent
            cpu.loadData(conIn, at: X86UEFI.conInAddress)
            installProtocol(handle: UInt64(X86UEFI.consoleHandleAddress),
                            guid: guidConIn, interface: UInt64(X86UEFI.conInAddress))
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
            put64(&services, 80, stubAddress(.bsCreateEvent))
            put64(&services, 88, stubAddress(.bsSetTimer))
            put64(&services, 96, stubAddress(.bsWaitForEvent))
            put64(&services, 104, stubAddress(.bsSignalEvent))
            put64(&services, 112, stubAddress(.bsCloseEvent))
            put64(&services, 120, stubAddress(.bsCheckEvent))
            put64(&services, 136, stubAddress(.bsReinstallProtocolInterface))
            put64(&services, 168, stubAddress(.bsRegisterProtocolNotify))
            put64(&services, 176, stubAddress(.bsLocateHandle))
            put64(&services, 184, stubAddress(.bsLocateDevicePath))
            put64(&services, 200, stubAddress(.bsLoadImage))
            put64(&services, 208, stubAddress(.bsStartImage))
            put64(&services, 216, stubAddress(.bsExit))
            put64(&services, 224, stubAddress(.bsUnloadImage))
            put64(&services, 232, stubAddress(.bsExitBootServices))
            put64(&services, 240, stubAddress(.bsGetNextMonotonicCount))
            put64(&services, 248, stubAddress(.bsStall))
            put64(&services, 256, stubAddress(.bsSetWatchdogTimer))
            put64(&services, 128, stubAddress(.bsInstallProtocolInterface))
            put64(&services, 144, stubAddress(.bsUninstallProtocolInterface))
            put64(&services, 152, stubAddress(.bsHandleProtocol))
            put64(&services, 192, stubAddress(.bsInstallConfigurationTable))
            put64(&services, 280, stubAddress(.bsOpenProtocol))
            put64(&services, 288, stubAddress(.bsCloseProtocol))
            put64(&services, 304, stubAddress(.bsProtocolsPerHandle))
            put64(&services, 312, stubAddress(.bsLocateHandleBuffer))
            put64(&services, 320, stubAddress(.bsLocateProtocol))
            put64(&services, 264, stubAddress(.bsConnectController))
            put64(&services, 272, stubAddress(.bsDisconnectController))
            put64(&services, 296, stubAddress(.bsOpenProtocolInformation))
            put64(&services, 328, stubAddress(.bsInstallMultipleProtocolInterfaces))
            put64(&services, 336, stubAddress(.bsUninstallMultipleProtocolInterfaces))
            put64(&services, 344, stubAddress(.bsCalculateCrc32))
            put64(&services, 368, stubAddress(.bsCreateEventEx))
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
            put64(&services, 24, stubAddress(.rsGetTime))
            put64(&services, 32, stubAddress(.rsSetTime))
            put64(&services, 40, stubAddress(.rsGetWakeupTime))
            put64(&services, 48, stubAddress(.rsSetWakeupTime))
            put64(&services, 56, stubAddress(.rsSetVirtualAddressMap))
            put64(&services, 64, stubAddress(.rsConvertPointer))
            put64(&services, 72, stubAddress(.rsGetVariable))
            put64(&services, 80, stubAddress(.rsGetNextVariableName))
            put64(&services, 88, stubAddress(.rsSetVariable))
            put64(&services, 104, stubAddress(.rsResetSystem)) // ResetSystem
            put64(&services, 96, stubAddress(.rsGetNextHighMonotonicCount))
            put64(&services, 112, stubAddress(.rsUpdateCapsule))
            put64(&services, 120, stubAddress(.rsQueryCapsuleCapabilities))
            put64(&services, 128, stubAddress(.rsQueryVariableInfo))
            let crc = X86UEFI.crc32(services)
            put32(&services, 16, crc)
            cpu.loadData(services, at: X86UEFI.runtimeServicesAddress)
        }

        // MARK: スタブ横取り

        /// RIP がスタブ範囲ならサービスを実行し、戻り先へ RIP を移す。
        func handleStub(address: UInt64) -> Bool {
            let base = UInt64(X86UEFI.stubBase)
            var address = address
            if !(address >= base && address < base + 0x2000), !virtualAddressMap.isEmpty,
               let translated = translateVirtualToPhysical(address),
               translated >= base, translated < base + 0x2000 {
                address = translated // SetVirtualAddressMap 後の仮想アドレス経由の呼び出し
            }
            guard address >= base, address < base + 0x2000 else { return false }
            let index = Int((address - base) / 16)
            guard let service = Service(rawValue: index) else { return false }
            // 制御を移すサービスは通常の「戻り」処理をしない
            if service == .bsStartImage { return startImageCall() }
            if service == .bsExit { return exitImageCall() }
            if service == .imageReturnTrap {
                return finishImageCall(exitStatus: cpu.register64(0))
            }
            if service == .guestCallTrap {
                return finishGuestCall()
            }
            if service == .bsConnectController {
                guard !exitedBootServices else { return returnToCaller(status: notReady) }
                return connectControllerCall()
            }
            if service == .bsDisconnectController {
                guard !exitedBootServices else { return returnToCaller(status: notReady) }
                return disconnectControllerCall()
            }
            let result = perform(service)
            if service == .rsResetSystem { return true } // 停止済み
            return returnToCaller(status: result)
        }

        /// 呼び出し側へ戻る共通処理（戻りアドレスをポップし RAX に結果を入れる）。
        private func returnToCaller(status: UInt64) -> Bool {
            let stackPointer = cpu.register64(4)
            let returnAddress = read(stackPointer, size: 8)
            cpu.setRegister64(4, stackPointer + 8)
            cpu.redirectExecution(to: returnAddress)
            cpu.setRegister64(0, status)
            return true
        }

        /// StartImage: レジスタを保存し、子イメージのエントリへ制御を移す。
        /// 子が RET すると戻りトラップ（imageReturnTrap）が復元する。
        private func startImageCall() -> Bool {
            let handle = cpu.register64(1)
            guard let info = loadedImages[handle] else {
                return returnToCaller(status: invalidParameter)
            }
            let stackSize = 0x10000
            guard let stackBase = allocPagesInternal(count: stackSize / 4096, memoryType: 4, kind: .firmware) else {
                return returnToCaller(status: outOfResources)
            }
            imageCallStacks.append(stackBase)
            let frame = ImageCallFrame(
                handle: handle,
                savedRegisters: (0..<16).map { cpu.register64($0) },
                savedStackPointer: cpu.register64(4),
                exitDataSizeAddress: cpu.register64(2),
                exitDataAddress: cpu.register64(8))
            imageCallStack.append(frame)
            let childStackTop = stackBase + UInt64(stackSize)
            write(childStackTop - 8, stubAddress(.imageReturnTrap), size: 8)
            cpu.setRegister64(4, childStackTop - 8)
            cpu.setRegister64(1, handle) // ImageHandle
            cpu.setRegister64(2, UInt64(X86UEFI.systemTableAddress)) // SystemTable
            cpu.redirectExecution(to: info.entry)
            return true
        }

        /// Exit: 対応する StartImage フレームまで巻き戻す。
        /// 起動イメージの Exit は CPU 停止として扱う。
        private func exitImageCall() -> Bool {
            let handle = cpu.register64(1)
            let exitStatus = cpu.register64(2)
            if let index = imageCallStack.lastIndex(where: { $0.handle == handle }) {
                while imageCallStack.count > index + 1 {
                    imageCallStack.removeLast()
                    if let stackBase = imageCallStacks.popLast() {
                        freeRecordInternal(address: stackBase)
                    }
                }
                return finishImageCall(exitStatus: exitStatus)
            }
            if handle == imageBase {
                cpu.halt(exitCode: Int32(exitStatus & 0xFFFF_FFFF))
                return true
            }
            return returnToCaller(status: invalidParameter)
        }

        /// 子イメージから戻ってきたときの復元処理。
        private func finishImageCall(exitStatus: UInt64) -> Bool {
            guard let frame = imageCallStack.popLast() else {
                cpu.halt(exitCode: Int32(exitStatus & 0xFFFF_FFFF))
                return true
            }
            if let stackBase = imageCallStacks.popLast() {
                freeRecordInternal(address: stackBase)
            }
            if frame.exitDataSizeAddress != 0 { write(frame.exitDataSizeAddress, 0, size: 8) }
            if frame.exitDataAddress != 0 { write(frame.exitDataAddress, 0, size: 8) }
            for index in 0..<16 where index != 0 && index != 4 {
                cpu.setRegister64(index, frame.savedRegisters[index])
            }
            cpu.setRegister64(4, frame.savedStackPointer)
            return returnToCaller(status: exitStatus)
        }

        /// ブートサービス（ExitBootServices 後に無効化する対象）かどうか。
        private func isBootService(_ service: Service) -> Bool {
            switch service {
            case .bsRaiseTPL, .bsRestoreTPL, .bsAllocatePages, .bsFreePages,
                 .bsGetMemoryMap, .bsAllocatePool, .bsFreePool, .bsExitBootServices,
                 .bsStall, .bsSetWatchdogTimer, .bsCopyMem, .bsSetMem,
                 .bsCalculateCrc32, .bsLocateProtocol, .bsGetNextMonotonicCount,
                 .bsInstallProtocolInterface, .bsUninstallProtocolInterface,
                 .bsHandleProtocol, .bsOpenProtocol, .bsCloseProtocol,
                 .bsProtocolsPerHandle, .bsLocateHandleBuffer,
                 .bsInstallConfigurationTable, .bsCreateEvent, .bsSetTimer,
                 .bsWaitForEvent, .bsSignalEvent, .bsCloseEvent, .bsCheckEvent,
                 .bsLoadImage, .bsUnloadImage, .bsLocateHandle, .bsLocateDevicePath,
                 .bsReinstallProtocolInterface,
                 .bsInstallMultipleProtocolInterfaces,
                 .bsUninstallMultipleProtocolInterfaces,
                 .bsOpenProtocolInformation, .bsConnectController,
                 .bsDisconnectController, .bsRegisterProtocolNotify, .bsCreateEventEx,
                 .bioReset, .bioReadBlocks, .bioWriteBlocks, .bioFlushBlocks,
                 .sfsOpenVolume, .fileOpen, .fileClose, .fileDelete, .fileRead,
                 .fileWrite, .fileGetPosition, .fileSetPosition, .fileGetInfo,
                 .fileSetInfo, .fileFlush:
                return true
            default:
                return false
            }
        }

        private func perform(_ service: Service) -> UInt64 {
            // ExitBootServices の後はブートサービスを無効化する
            // （ランタイムサービスとコンソール / GOP は使い続けられる）
            if exitedBootServices, isBootService(service) { return notReady }
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
            case .bsRestoreTPL, .bsSetWatchdogTimer:
                return success
            case .bsFreePages:
                // RCX=Memory, RDX=Pages
                return freePages(memory: rcx, pages: rdx)
            case .bsFreePool:
                // RCX=Buffer
                return freePool(address: rcx)
            case .bsStall:
                // RCX = Microseconds。実際に待つ（1 回あたり最大 1 秒）。
                let microseconds = min(rcx, 1_000_000)
                if microseconds > 0 {
                    Thread.sleep(forTimeInterval: Double(microseconds) / 1_000_000)
                }
                return success
            case .bsAllocatePages:
                // RCX=Type, RDX=MemoryType, R8=Pages, R9=*Memory
                return allocatePages(allocateType: rcx, memoryType: rdx, pages: r8, pointerAddress: r9)
            case .bsAllocatePool:
                // RCX=PoolType, RDX=Size, R8=*Buffer
                return allocatePool(bytes: rdx, pointerAddress: r8)
            case .bsGetMemoryMap:
                return getMemoryMap(sizeAddress: rcx, mapAddress: rdx, keyAddress: r8,
                                    descriptorSizeAddress: r9)
            case .bsExitBootServices:
                guard rdx == mapKey else { return invalidParameter }
                exitedBootServices = true
                signalEventGroup(0x202) // EVT_SIGNAL_EXIT_BOOT_SERVICES
                return success
            case .bsGetNextMonotonicCount:
                // 引数は RCX = OUT UINT64 *Count
                monotonicCount += 1
                write(rcx, monotonicCount, size: 8)
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
                let guid = readGUID(rcx)
                guard let interface = firstInterface(for: guid) else { return notFound }
                write(r8, interface, size: 8)
                return success
            // プロトコルデータベース
            case .bsInstallProtocolInterface:
                return installProtocolInterface(handlePointer: rcx, guidAddress: rdx, interface: r9)
            case .bsUninstallProtocolInterface:
                let guid = readGUID(rdx)
                guard let installed = protocolDB[rcx]?[guid] else { return notFound }
                guard installed == r8 else { return invalidParameter }
                protocolDB[rcx]?[guid] = nil
                if protocolDB[rcx]?.isEmpty == true {
                    protocolDB[rcx] = nil
                    handleOrder.removeAll { $0 == rcx }
                }
                return success
            case .bsHandleProtocol, .bsOpenProtocol:
                return queryProtocol(handle: rcx, guidAddress: rdx, outAddress: r8)
            case .bsCloseProtocol:
                return success
            case .bsProtocolsPerHandle:
                guard let protocols = protocolDB[rcx] else { return notFound }
                let guids = Array(protocols.keys)
                let buffer = arenaAlloc(max(16, guids.count * 16))
                guard buffer != 0 else { return outOfResources }
                for (index, guid) in guids.enumerated() {
                    writeBytes(buffer + UInt64(index * 16), guid)
                }
                write(rdx, buffer, size: 8)
                write(r8, UInt64(guids.count), size: 8)
                return success
            case .bsLocateHandleBuffer:
                // RCX=SearchType, RDX=*GUID, R8=SearchKey, R9=*Count, 引数5=**Buffer
                guard rcx == 0 || rcx == 2 else {
                    // ByRegisterNotify(1) は登録機構が無いため一致なし。
                    // 未知の種別も含め、ここでは見つからなかったとして扱う。
                    return rcx == 1 ? notFound : invalidParameter
                }
                var handles = handleOrder
                if rcx == 2 {
                    let guid = readGUID(rdx)
                    handles = handles.filter { protocolDB[$0]?[guid] != nil }
                }
                guard !handles.isEmpty else { return notFound }
                let buffer = arenaAlloc(max(8, handles.count * 8))
                guard buffer != 0 else { return outOfResources }
                for (index, handle) in handles.enumerated() {
                    write(buffer + UInt64(index * 8), handle, size: 8)
                }
                write(r9, UInt64(handles.count), size: 8)
                write(stackArgument(5), buffer, size: 8)
                return success
            case .bsInstallConfigurationTable:
                return installConfigurationTable(guidAddress: rcx, table: rdx)
            // Block I/O
            case .bioReset, .bioFlushBlocks:
                return success
            case .bioReadBlocks:
                return blockIOTransfer(isRead: true, lba: r8, size: r9, buffer: stackArgument(5))
            case .bioWriteBlocks:
                return blockIOTransfer(isRead: false, lba: r8, size: r9, buffer: stackArgument(5))
            // Simple File System / ファイル
            case .sfsOpenVolume:
                guard let volume = fatVolume else { return notFound }
                let root = makeFileObject(path: [], entry: nil, isDirectory: true)
                _ = volume
                write(rdx, root, size: 8)
                return success
            case .fileOpen:
                return fileOpen(this: rcx, outAddress: rdx, nameAddress: r8, mode: r9)
            case .fileClose:
                var status = success
                if let object = fileObjects[rcx] {
                    status = commitFile(object)
                    fileObjects[rcx] = nil
                }
                return status
            case .fileDelete:
                guard let object = fileObjects[rcx], let volume = fatVolume,
                      let entry = object.entry else { return invalidParameter }
                do {
                    try volume.deleteFile(directoryPath: object.path, name: entry.name)
                } catch {
                    return deviceError   // 削除に失敗したのに成功を報告しない
                }
                fileObjects[rcx] = nil
                syncDisk()
                return success
            case .fileRead:
                return fileRead(this: rcx, sizeAddress: rdx, buffer: r8)
            case .fileWrite:
                return fileWrite(this: rcx, sizeAddress: rdx, buffer: r8)
            case .fileGetPosition:
                guard let object = fileObjects[rcx] else { return notFound }
                write(rdx, object.position, size: 8)
                return success
            case .fileSetPosition:
                guard let object = fileObjects[rcx] else { return notFound }
                if rdx == 0xFFFFFFFFFFFFFFFF {
                    object.position = UInt64(object.entry?.size ?? 0)
                } else {
                    object.position = rdx
                }
                return success
            case .fileGetInfo:
                return fileGetInfo(this: rcx, guidAddress: rdx, sizeAddress: r8, buffer: r9)
            case .fileSetInfo:
                return success
            case .fileFlush:
                if let object = fileObjects[rcx] { return commitFile(object) }
                return success
            // 変数サービス
            case .rsGetVariable:
                return getVariable(nameAddress: rcx, guidAddress: rdx, attributesAddress: r8,
                                   sizeAddress: r9, dataAddress: stackArgument(5))
            case .rsSetVariable:
                return setVariable(nameAddress: rcx, guidAddress: rdx, attributes: r8,
                                   dataSize: r9, dataAddress: stackArgument(5))
            case .rsGetNextVariableName:
                return getNextVariableName(sizeAddress: rcx, nameAddress: rdx, guidAddress: r8)
            case .rsQueryVariableInfo:
                write(rdx, 1024 * 1024, size: 8)
                write(r8, 1024 * 1024, size: 8)
                write(r9, 64 * 1024, size: 8)
                return success
            // イベント / タイマ
            case .bsCreateEvent:
                return createEvent(type: UInt32(rcx & 0xFFFFFFFF),
                                   notifyFunction: r8, notifyContext: r9,
                                   eventAddress: stackArgument(5))
            case .bsCreateEventEx:
                // 引数 5 は EventGroup GUID、引数 6 が *Event
                return createEvent(type: UInt32(rcx & 0xFFFFFFFF),
                                   notifyFunction: r8, notifyContext: r9,
                                   eventAddress: stackArgument(6),
                                   eventGroup: readGUID(stackArgument(5)))
            case .bsSetTimer:
                return setTimer(event: rcx, type: rdx, triggerTime: r8)
            case .bsSignalEvent:
                guard let event = events[rcx] else { return invalidParameter }
                event.signaled = true
                enqueueNotify(handle: rcx, event: event)
                return success
            case .bsCloseEvent:
                guard events.removeValue(forKey: rcx) != nil else { return invalidParameter }
                return success
            case .bsCheckEvent:
                guard let event = events[rcx] else { return invalidParameter }
                if event.type & 0x100 != 0 { // EVT_NOTIFY_WAIT
                    enqueueNotify(handle: rcx, event: event)
                }
                return checkEvent(rcx) ? success : notReady
            case .bsWaitForEvent:
                return waitForEvent(count: rcx, arrayAddress: rdx, indexAddress: r8)
            // イメージ読み込み
            case .bsLoadImage:
                // RCX=BootPolicy, RDX=ParentHandle, R8=DevicePath,
                // R9=SourceBuffer, 引数5=SourceSize, 引数6=*ImageHandle
                return loadImage(parentHandle: rdx, devicePath: r8, sourceBuffer: r9,
                                 sourceSize: stackArgument(5),
                                 handleAddress: stackArgument(6))
            case .bsUnloadImage:
                return unloadImage(handle: rcx)
            case .bsStartImage, .bsExit, .imageReturnTrap, .guestCallTrap:
                return unsupportedStatus // handleStub で処理される（到達しない）
            // ハンドル検索 / プロトコル操作の残り
            case .bsLocateHandle:
                return locateHandle(searchType: rcx, guidAddress: rdx,
                                    sizeAddress: r9, bufferAddress: stackArgument(5))
            case .bsLocateDevicePath:
                return locateDevicePath(guidAddress: rcx, pathAddress: rdx,
                                        handleAddress: r8)
            case .bsReinstallProtocolInterface:
                return reinstallProtocolInterface(handle: rcx, guidAddress: rdx,
                                                  oldInterface: r8, newInterface: r9)
            case .bsInstallMultipleProtocolInterfaces:
                return multipleProtocolInterfaces(firstValue: rcx, install: true)
            case .bsUninstallMultipleProtocolInterfaces:
                return multipleProtocolInterfaces(firstValue: rcx, install: false)
            case .bsOpenProtocolInformation:
                return openProtocolInformation(handle: rcx, guidAddress: rdx,
                                               entriesAddress: r8, countAddress: r9)
            case .bsConnectController, .bsDisconnectController:
                return unsupportedStatus // handleStub で処理される（到達しない）
            case .bsRegisterProtocolNotify:
                // RCX = *Protocol GUID、RDX = Event、R8 = **Registration
                protocolNotifyRegistrations.append((guid: readGUID(rcx), event: rdx))
                let token = arenaAlloc(8)
                guard token != 0 else { return outOfResources }
                write(r8, token, size: 8)
                return success
            // ConIn
            case .conInReset:
                keyQueueLock.lock()
                keyQueue.removeAll()
                keyQueueLock.unlock()
                return success
            case .conInReadKey:
                // RCX = This、RDX = *EFI_INPUT_KEY
                keyQueueLock.lock()
                let key = keyQueue.isEmpty ? nil : keyQueue.removeFirst()
                keyQueueLock.unlock()
                guard let key else { return notReady }
                write(rdx, UInt64(key.scan), size: 2)
                write(rdx + 2, UInt64(key.unicode), size: 2)
                return success
            // GOP
            case .gopQueryMode:
                return gopQueryMode(modeNumber: rdx, sizeAddress: r8, infoAddress: r9)
            case .gopSetMode:
                return gopSetMode(modeNumber: rdx)
            case .gopBlt:
                return gopBlt(buffer: rdx, operation: r8, sourceX: r9,
                              sourceY: stackArgument(5),
                              destinationX: stackArgument(6),
                              destinationY: stackArgument(7),
                              width: stackArgument(8), height: stackArgument(9),
                              delta: stackArgument(10))
            // ランタイムサービス（時刻・変換など）
            case .rsGetTime:
                return getTime(timeAddress: rcx, capabilitiesAddress: rdx)
            case .rsSetTime:
                return rcx == 0 ? invalidParameter : success // ホスト時計は変えない
            case .rsGetWakeupTime:
                if rcx != 0 { write(rcx, 0, size: 1) } // Enabled = FALSE
                if rdx != 0 { write(rdx, 0, size: 1) } // Pending = FALSE
                if r8 != 0 { writeBytes(r8, [UInt8](repeating: 0, count: 16)) }
                return success
            case .rsSetWakeupTime:
                return success
            case .rsSetVirtualAddressMap:
                return setVirtualAddressMap(mapSize: rcx, descriptorSize: rdx, mapAddress: r9)
            case .rsConvertPointer:
                // RCX = 変換種別（bit0 = 0: 仮想へ / 1: 物理へ）、RDX = **Address
                let pointer = read(rdx, size: 8)
                if rcx & 1 == 0 {
                    write(rdx, translatePhysicalToVirtual(pointer), size: 8)
                } else {
                    write(rdx, translateVirtualToPhysical(pointer) ?? pointer, size: 8)
                }
                return success
            case .rsGetNextHighMonotonicCount:
                highMonotonicCount += 1
                write(rcx, highMonotonicCount << 32, size: 8)
                return success
            case .rsUpdateCapsule, .rsQueryCapsuleCapabilities:
                return unsupportedStatus
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

        // MARK: メモリアロケータ

        /// 連続ページの空きランがあるか（確保せずに調べる）。
        private func canAllocPages(count: Int) -> Bool {
            var run = 0
            for used in pageUsed {
                if used { run = 0 } else {
                    run += 1
                    if run >= count { return true }
                }
            }
            return false
        }

        private func markPages(start: Int, count: Int, memoryType: UInt32, kind: PageRecordKind) {
            for i in start..<(start + count) {
                pageUsed[i] = true
                pageTypes[i] = memoryType
            }
            pageRecords[start] = (count, memoryType, kind)
        }

        /// 最低アドレスの first-fit で連続ページを確保する。
        private func allocPagesInternal(count: Int, memoryType: UInt32, kind: PageRecordKind) -> UInt64? {
            guard count > 0, count <= pageUsed.count else { return nil }
            var run = 0
            for index in 0..<pageUsed.count {
                if pageUsed[index] { run = 0; continue }
                run += 1
                if run == count {
                    let start = index - count + 1
                    markPages(start: start, count: count, memoryType: memoryType, kind: kind)
                    return UInt64(X86UEFI.heapStart + start * 4096)
                }
            }
            return nil
        }

        /// 指定アドレスちょうどの範囲が空いていれば確保する。
        private func allocPagesAt(address: UInt64, count: Int, memoryType: UInt32, kind: PageRecordKind) -> Bool {
            guard address % 4096 == 0, address >= UInt64(X86UEFI.heapStart) else { return false }
            let start = Int(address - UInt64(X86UEFI.heapStart)) / 4096
            guard start + count <= pageUsed.count else { return false }
            for i in start..<(start + count) where pageUsed[i] { return false }
            markPages(start: start, count: count, memoryType: memoryType, kind: kind)
            return true
        }

        /// maxAddress 以下に収まる最も高いランを確保する（AllocateMaxAddress 用）。
        private func allocPagesBelow(maxAddress: UInt64, count: Int, memoryType: UInt32, kind: PageRecordKind) -> UInt64? {
            guard count > 0 else { return nil }
            var run = 0
            var index = pageUsed.count - 1
            while index >= 0 {
                if pageUsed[index] { run = 0 } else {
                    run += 1
                    if run == count {
                        let start = index
                        let address = UInt64(X86UEFI.heapStart + start * 4096)
                        if address + UInt64(count * 4096) - 1 <= maxAddress {
                            markPages(start: start, count: count, memoryType: memoryType, kind: kind)
                            return address
                        }
                        run = 0 // このランは上限を超えるため、より低いランを探す
                    }
                }
                index -= 1
            }
            return nil
        }

        /// 記録のある確保を開始アドレスから解放する（内部用）。
        @discardableResult
        private func freeRecordInternal(address: UInt64) -> Bool {
            guard address % 4096 == 0, address >= UInt64(X86UEFI.heapStart) else { return false }
            let start = Int(address - UInt64(X86UEFI.heapStart)) / 4096
            guard let record = pageRecords.removeValue(forKey: start) else { return false }
            for i in start..<(start + record.pages) {
                pageUsed[i] = false
                pageTypes[i] = 7
            }
            return true
        }

        private func allocatePages(allocateType: UInt64, memoryType: UInt64, pages: UInt64, pointerAddress: UInt64) -> UInt64 {
            guard pages > 0, pages <= UInt64(pageUsed.count) else { return invalidParameter }
            let count = Int(pages)
            let type = UInt32(memoryType & 0xFFFFFFFF)
            let address: UInt64?
            switch allocateType {
            case 0: // AllocateAnyPages
                address = allocPagesInternal(count: count, memoryType: type, kind: .guest)
            case 1: // AllocateMaxAddress
                address = allocPagesBelow(maxAddress: read(pointerAddress, size: 8), count: count, memoryType: type, kind: .guest)
            case 2: // AllocateAddress
                let requested = read(pointerAddress, size: 8)
                guard requested % 4096 == 0 else { return invalidParameter }
                address = allocPagesAt(address: requested, count: count, memoryType: type, kind: .guest) ? requested : nil
                if address == nil { return notFound }
            default:
                return invalidParameter
            }
            guard let resolved = address else { return outOfResources }
            write(pointerAddress, resolved, size: 8)
            return success
        }

        private func freePages(memory: UInt64, pages: UInt64) -> UInt64 {
            guard pages > 0, memory % 4096 == 0, memory >= UInt64(X86UEFI.heapStart) else { return invalidParameter }
            let start = Int(memory - UInt64(X86UEFI.heapStart)) / 4096
            guard let record = pageRecords[start], record.pages == Int(pages), record.kind == .guest else {
                return invalidParameter
            }
            freeRecordInternal(address: memory)
            return success
        }

        private func allocatePool(bytes: UInt64, pointerAddress: UInt64) -> UInt64 {
            guard bytes <= 0x4000_0000 else { return outOfResources }
            let size = max(16, (Int(bytes) + 15) & ~15)
            if let index = poolFreeBlocks.firstIndex(where: { $0.size >= size }) {
                let block = poolFreeBlocks[index]
                if block.size - size >= 16 {
                    poolFreeBlocks[index] = (block.address + UInt64(size), block.size - size)
                    poolAllocations[block.address] = size
                } else {
                    poolFreeBlocks.remove(at: index)
                    poolAllocations[block.address] = block.size
                }
                write(pointerAddress, block.address, size: 8)
                return success
            }
            // 新しいプールチャンクをページアロケータから確保する（最低 64 KiB）
            let chunkPages = max(16, (size + 4095) / 4096)
            guard let chunk = allocPagesInternal(count: chunkPages, memoryType: 4, kind: .pool) else {
                return outOfResources
            }
            let chunkSize = chunkPages * 4096
            if chunkSize - size >= 16 {
                poolFreeBlocks.append((chunk + UInt64(size), chunkSize - size))
                poolAllocations[chunk] = size
            } else {
                poolAllocations[chunk] = chunkSize
            }
            write(pointerAddress, chunk, size: 8)
            return success
        }

        private func freePool(address: UInt64) -> UInt64 {
            guard let size = poolAllocations.removeValue(forKey: address) else { return invalidParameter }
            poolFreeBlocks.append((address, size))
            poolFreeBlocks.sort { $0.address < $1.address }
            var merged: [(address: UInt64, size: Int)] = []
            for block in poolFreeBlocks {
                if let last = merged.last, last.address + UInt64(last.size) == block.address {
                    merged[merged.count - 1].size += block.size
                } else {
                    merged.append(block)
                }
            }
            poolFreeBlocks = merged
            return success
        }

        private func memoryRegions() -> [(start: UInt64, pages: UInt64, type: UInt32)] {
            let imagePages = UInt64((sizeOfImage + 4095) / 4096)
            var regions: [(start: UInt64, pages: UInt64, type: UInt32)] = [
                (0x000000, 0x80, 7), // 通常メモリ（0〜512 KiB）
                (0x080000, 0x80, 0), // 予約（BIOS / ACPI 領域を含む）
                (0x100000, 0x100, 3), // ファームウェア構造（ページ表・GDT・IDT）
                (0x300000, 0x1, 5), // ランタイムサービスコード（システムテーブル等）
                (0x301000, 0x2, 5), // ランタイムサービスコード（スタブ）
                (0x303000, 0xD, 3), // ブートサービス領域（アリーナ等）
                (0x310000, 0xE0, 7), // 通常メモリ
                (0x3F0000, 0x10, 3), // スタック
                (0x400000, 0x100, 7), // 通常メモリ
            ]
            // イメージ領域は静的領域と重なる場合は追加しない（メモリマップの
            // ディスクリプタは重なってはならないという UEFI 仕様のため）
            let imageEnd = imageBase + imagePages * 4096
            let staticRanges: [(UInt64, UInt64)] = [
                (0x100000, 0x200000), (0x300000, 0x310000), (0x3F0000, 0x400000), (0x400000, 0x500000),
            ]
            if !staticRanges.contains(where: { imageBase < $0.1 && $0.0 < imageEnd }) {
                regions.append((imageBase, imagePages, 2)) // ローダコード（イメージ）
            }
            // ヒープ領域はページ記録から動的に分割する
            var index = 0
            while index < pageUsed.count {
                let type = pageTypes[index]
                var end = index + 1
                while end < pageUsed.count, pageTypes[end] == type { end += 1 }
                regions.append((UInt64(X86UEFI.heapStart + index * 4096), UInt64(end - index), type))
                index = end
            }
            // ロード領域はイメージ配置記録から分割する
            var cursor = X86UEFI.loadRegionStart
            for allocation in imageRegionAllocations.sorted(by: { $0.base < $1.base }) {
                if allocation.base > cursor {
                    regions.append((UInt64(cursor), UInt64((allocation.base - cursor) / 4096), 7))
                }
                regions.append((UInt64(allocation.base), UInt64((allocation.size + 4095) / 4096), 2))
                cursor = max(cursor, allocation.base + ((allocation.size + 4095) & ~4095))
            }
            if cursor < X86UEFI.loadRegionEnd {
                regions.append((UInt64(cursor), UInt64((X86UEFI.loadRegionEnd - cursor) / 4096), 7))
            }
            return regions
        }

        private func getMemoryMap(sizeAddress: UInt64, mapAddress: UInt64, keyAddress: UInt64,
                                  descriptorSizeAddress: UInt64) -> UInt64 {
            let regions = memoryRegions()
            let descriptorSize = 40
            let required = regions.count * descriptorSize
            let provided = Int(read(sizeAddress, size: 8))
            write(descriptorSizeAddress, UInt64(descriptorSize), size: 8)
            // 5 番目の引数（DescriptorVersion へのポインタ）はスタック上
            let stackPointer = cpu.register64(4)
            let versionAddress = read(stackPointer + 40, size: 8)
            if versionAddress != 0 { write(versionAddress, 1, size: 4) }
            guard mapAddress != 0, provided >= required else {
                write(sizeAddress, UInt64(required), size: 8)
                return bufferTooSmall
            }
            mapKey += 1
            write(keyAddress, mapKey, size: 8)
            for (index, region) in regions.enumerated() {
                let base = mapAddress + UInt64(index * descriptorSize)
                write(base, UInt64(region.type), size: 4)
                write(base + 8, region.start, size: 8)
                write(base + 16, region.start, size: 8) // VirtualStart（初期は物理と同一）
                write(base + 24, region.pages, size: 8)
                let attribute: UInt64 = (region.type == 5 || region.type == 6)
                    ? 0x800000000000000F : 0xF // ランタイム領域には EFI_MEMORY_RUNTIME
                write(base + 32, attribute, size: 8)
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


        // MARK: バイト列 / 文字列アクセス

        private func readBytes(_ address: UInt64, count: Int) -> [UInt8] {
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            var offset = 0
            while offset < count {
                let chunk = min(4, count - offset)
                let value = read(address + UInt64(offset), size: chunk)
                for i in 0..<chunk { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
                offset += chunk
            }
            return bytes
        }

        private func writeBytes(_ address: UInt64, _ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            cpu.loadData(bytes, at: Int(address))
        }

        private func readGUID(_ address: UInt64) -> [UInt8] {
            readBytes(address, count: 16)
        }

        private func readString16(_ address: UInt64) -> String {
            var units: [UInt16] = []
            var pointer = address
            for _ in 0..<512 {
                let unit = read(pointer, size: 2)
                if unit == 0 { break }
                units.append(UInt16(unit & 0xFFFF))
                pointer += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        private func writeString16(_ address: UInt64, _ string: String) {
            var bytes = [UInt8]()
            for unit in string.utf16 {
                bytes.append(UInt8(unit & 0xFF))
                bytes.append(UInt8((unit >> 8) & 0xFF))
            }
            bytes.append(0)
            bytes.append(0)
            writeBytes(address, bytes)
        }

        /// 5 番目以降の引数（RSP + 40 から）。
        private func stackArgument(_ index: Int) -> UInt64 {
            read(cpu.register64(4) + UInt64(40 + (index - 5) * 8), size: 8)
        }

        private func arenaAlloc(_ size: Int) -> UInt64 {
            let aligned = (size + 7) & ~7
            guard arenaPointer + aligned <= X86UEFI.protocolArenaEnd else { return 0 }
            let address = arenaPointer
            arenaPointer += aligned
            return UInt64(address)
        }

        // MARK: プロトコルデータベース

        private func registerHandle(_ handle: UInt64) {
            if protocolDB[handle] == nil {
                protocolDB[handle] = [:]
                handleOrder.append(handle)
            }
        }

        private func installProtocol(handle: UInt64, guid: [UInt8], interface: UInt64) {
            registerHandle(handle)
            protocolDB[handle]?[guid] = interface
            for registration in protocolNotifyRegistrations where registration.guid == guid {
                if let event = events[registration.event] {
                    event.signaled = true
                    enqueueNotify(handle: registration.event, event: event)
                }
            }
        }

        private func firstInterface(for guid: [UInt8]) -> UInt64? {
            for handle in handleOrder {
                if let interface = protocolDB[handle]?[guid] { return interface }
            }
            return nil
        }

        private func installProtocolInterface(handlePointer: UInt64, guidAddress: UInt64, interface: UInt64) -> UInt64 {
            var handle = read(handlePointer, size: 8)
            if handle == 0 {
                handle = arenaAlloc(8)
                guard handle != 0 else { return outOfResources }
                write(handlePointer, handle, size: 8)
            }
            installProtocol(handle: handle, guid: readGUID(guidAddress), interface: interface)
            return success
        }

        private func queryProtocol(handle: UInt64, guidAddress: UInt64, outAddress: UInt64) -> UInt64 {
            let guid = readGUID(guidAddress)
            guard let interface = protocolDB[handle]?[guid] else { return notFound }
            write(outAddress, interface, size: 8)
            return success
        }

        private func installConfigurationTable(guidAddress: UInt64, table: UInt64) -> UInt64 {
            let guid = readGUID(guidAddress)
            if table == 0 {
                configEntries.removeAll { $0.guid == guid }
            } else if let index = configEntries.firstIndex(where: { $0.guid == guid }) {
                configEntries[index].table = table
            } else {
                guard configEntries.count < 4 else { return outOfResources }
                configEntries.append((guid: guid, table: table))
            }
            writeConfigurationTables()
            return success
        }

        private func writeConfigurationTables() {
            var config = [UInt8](repeating: 0, count: 24 * 4)
            for (index, entry) in configEntries.enumerated() {
                config.replaceSubrange((index * 24)..<(index * 24 + 16), with: entry.guid)
                put64(&config, index * 24 + 16, entry.table)
            }
            cpu.loadData(config, at: X86UEFI.configTableAddress)
            let tableAddress = UInt64(X86UEFI.systemTableAddress)
            write(tableAddress + 104, UInt64(configEntries.count), size: 8)
            var table = readBytes(tableAddress, count: 120)
            put32(&table, 16, 0)
            put32(&table, 16, X86UEFI.crc32(table))
            cpu.loadData(table, at: X86UEFI.systemTableAddress)
        }

        /// コンソール / ディスクのハンドルとプロトコルを登録する。
        private func installProtocols() {
            // イメージハンドルとコンソールハンドル
            registerHandle(imageBase)
            installLoadedImage(handle: imageBase, parentHandle: 0,
                               imageAddress: imageBase, imageSize: sizeOfImage,
                               structAddress: UInt64(X86UEFI.loadedImageAddress))
            installGOP()
            installProtocol(handle: UInt64(X86UEFI.consoleHandleAddress),
                            guid: guidConOut, interface: UInt64(X86UEFI.conOutAddress))

            // ディスクの裏付け: 接続済みディスクがあれば共有し、
            // なければ FAT12 RAM ボリュームを用意する
            let initialData = cpu.attachedDisk?.data ?? FATVolume.formattedFloppy()
            let storage = FATVolume.Storage(initialData)
            diskStorage = storage
            fatVolume = try? FATVolume(storage: storage)
            let diskHandle = UInt64(X86UEFI.diskHandleAddress)

            // Block I/O
            var media = [UInt8](repeating: 0, count: 32)
            media[5] = 1 // MediaPresent
            put32(&media, 12, 512)
            put64(&media, 24, UInt64(max(0, storage.data.count / 512 - 1)))
            cpu.loadData(media, at: X86UEFI.blockIOMediaAddress)
            var blockIO = [UInt8](repeating: 0, count: 48)
            put64(&blockIO, 0, 0x00010000)
            put64(&blockIO, 8, UInt64(X86UEFI.blockIOMediaAddress))
            put64(&blockIO, 16, stubAddress(.bioReset))
            put64(&blockIO, 24, stubAddress(.bioReadBlocks))
            put64(&blockIO, 32, stubAddress(.bioWriteBlocks))
            put64(&blockIO, 40, stubAddress(.bioFlushBlocks))
            cpu.loadData(blockIO, at: X86UEFI.blockIOAddress)
            installProtocol(handle: diskHandle, guid: guidBlockIO,
                            interface: UInt64(X86UEFI.blockIOAddress))

            // デバイスパス（PCI ノード + ファイルパス + 終端）
            let devicePath: [UInt8] = [
                0x01, 0x01, 0x06, 0x00, 0x01, 0x01,
                0x04, 0x04, 0x08, 0x00, 0x5C, 0x00, 0x00, 0x00,
                0x7F, 0xFF, 0x04, 0x00,
            ]
            cpu.loadData(devicePath, at: X86UEFI.devicePathAddress)
            installProtocol(handle: diskHandle, guid: guidDevicePath,
                            interface: UInt64(X86UEFI.devicePathAddress))

            // Simple File System（FAT として解釈できる場合のみ）
            if fatVolume != nil {
                var sfs = [UInt8](repeating: 0, count: 16)
                put64(&sfs, 0, 0x00010000)
                put64(&sfs, 8, stubAddress(.sfsOpenVolume))
                cpu.loadData(sfs, at: X86UEFI.sfsAddress)
                installProtocol(handle: diskHandle, guid: guidSFS,
                                interface: UInt64(X86UEFI.sfsAddress))
            }
        }

        /// EFI_LOADED_IMAGE_PROTOCOL を構築してハンドルへ登録する。
        private func installLoadedImage(handle: UInt64, parentHandle: UInt64,
                                        imageAddress: UInt64, imageSize: Int,
                                        structAddress: UInt64) {
            var loaded = [UInt8](repeating: 0, count: 104)
            put32(&loaded, 0, 0x00001000) // Revision
            put64(&loaded, 8, parentHandle)
            put64(&loaded, 16, UInt64(X86UEFI.systemTableAddress))
            put64(&loaded, 24, UInt64(X86UEFI.diskHandleAddress)) // DeviceHandle
            put64(&loaded, 32, UInt64(X86UEFI.devicePathAddress)) // FilePath
            put64(&loaded, 64, imageAddress) // ImageBase
            put64(&loaded, 72, UInt64(imageSize)) // ImageSize
            put64(&loaded, 80, 2) // ImageCodeType = LoaderCode
            put64(&loaded, 88, 2) // ImageDataType = LoaderData
            put64(&loaded, 96, stubAddress(.unsupported)) // Unload
            cpu.loadData(loaded, at: Int(structAddress))
            installProtocol(handle: handle, guid: guidLoadedImage, interface: structAddress)
        }

        /// GOP（Graphics Output Protocol）を構築してコンソールハンドルへ登録する。
        private func installGOP() {
            writeGOPModeStructs()
            // GOP 構造体は Revision を持たず QueryMode から始まる
            var gop = [UInt8](repeating: 0, count: 32)
            put64(&gop, 0, stubAddress(.gopQueryMode))
            put64(&gop, 8, stubAddress(.gopSetMode))
            put64(&gop, 16, stubAddress(.gopBlt))
            put64(&gop, 24, UInt64(X86UEFI.gopModeAddress)) // Mode
            cpu.loadData(gop, at: X86UEFI.gopAddress)
            installProtocol(handle: UInt64(X86UEFI.consoleHandleAddress),
                            guid: guidGOP, interface: UInt64(X86UEFI.gopAddress))
        }

        /// 現在のモードに合わせて Info / Mode 構造体を書き直す。
        private func writeGOPModeStructs() {
            var info = [UInt8](repeating: 0, count: 36)
            put32(&info, 4, UInt32(framebufferWidth))
            put32(&info, 8, UInt32(framebufferHeight))
            put32(&info, 12, 1) // PixelBlueGreenRedReserved8BitPerColor
            put32(&info, 16, 0x00FF0000) // RedMask
            put32(&info, 20, 0x0000FF00) // GreenMask
            put32(&info, 24, 0x000000FF) // BlueMask
            put32(&info, 28, 0xFF000000) // ReservedMask
            put32(&info, 32, UInt32(framebufferWidth)) // PixelsPerScanLine
            cpu.loadData(info, at: X86UEFI.gopInfoAddress)
            let framebufferSize = framebufferWidth * framebufferHeight * 4
            var mode = [UInt8](repeating: 0, count: 40)
            put32(&mode, 0, UInt32(gopModes.count - 1)) // MaxMode
            put32(&mode, 4, UInt32(gopCurrentMode)) // Mode
            put64(&mode, 8, UInt64(X86UEFI.gopInfoAddress))
            put64(&mode, 16, 36) // SizeOfInfo
            put64(&mode, 24, UInt64(framebufferBase))
            put64(&mode, 32, UInt64(framebufferSize))
            cpu.loadData(mode, at: X86UEFI.gopModeAddress)
        }

        /// 指定モードの Info 構造体バイト列。
        private func gopInfoBytes(mode: Int) -> [UInt8] {
            var info = [UInt8](repeating: 0, count: 36)
            put32(&info, 4, UInt32(gopModes[mode].width))
            put32(&info, 8, UInt32(gopModes[mode].height))
            put32(&info, 12, 1)
            put32(&info, 16, 0x00FF0000)
            put32(&info, 20, 0x0000FF00)
            put32(&info, 24, 0x000000FF)
            put32(&info, 28, 0xFF000000)
            put32(&info, 32, UInt32(gopModes[mode].width))
            return info
        }

        /// 接続済みディスクへ書き戻す（Block I/O / FAT の変更を共有する）。
        private func syncDisk() {
            if let attached = cpu.attachedDisk, let storage = diskStorage {
                attached.data = storage.data
            }
        }

        // MARK: Block I/O

        private func blockIOTransfer(isRead: Bool, lba: UInt64, size: UInt64, buffer: UInt64) -> UInt64 {
            guard let storage = diskStorage else { return deviceError }
            guard size % 512 == 0 else { return invalidParameter }
            // 範囲検査は UInt64 のまま行う（Int へ変換してからだと
            // 巨大な LBA でトラップ／溢れが起きる）
            let (start64, multiplyOverflow) = lba.multipliedReportingOverflow(by: 512)
            guard !multiplyOverflow else { return deviceError }
            let total = UInt64(storage.data.count)
            guard start64 <= total, size <= total - start64 else { return deviceError }
            let start = Int(start64)
            let count = Int(size)
            if isRead {
                writeBytes(buffer, [UInt8](storage.data[start..<(start + count)]))
            } else {
                storage.data.replaceSubrange(start..<(start + count),
                                             with: readBytes(buffer, count: count))
                syncDisk()
            }
            return success
        }

        // MARK: ファイルプロトコル

        private func makeFileObject(path: [String], entry: FATVolume.Entry?, isDirectory: Bool) -> UInt64 {
            let address = arenaAlloc(88)
            guard address != 0 else { return 0 }
            var file = [UInt8](repeating: 0, count: 88)
            put64(&file, 0, 0x10000) // Revision
            put64(&file, 8, stubAddress(.fileOpen))
            put64(&file, 16, stubAddress(.fileClose))
            put64(&file, 24, stubAddress(.fileDelete))
            put64(&file, 32, stubAddress(.fileRead))
            put64(&file, 40, stubAddress(.fileWrite))
            put64(&file, 48, stubAddress(.fileGetPosition))
            put64(&file, 56, stubAddress(.fileSetPosition))
            put64(&file, 64, stubAddress(.fileGetInfo))
            put64(&file, 72, stubAddress(.fileSetInfo))
            put64(&file, 80, stubAddress(.fileFlush))
            cpu.loadData(file, at: Int(address))
            let object = FileObject()
            object.path = path
            object.entry = entry
            object.isDirectory = isDirectory
            fileObjects[address] = object
            return address
        }

        private func resolveComponents(base: [String], name: String) -> [String] {
            var components = name.hasPrefix("\\") ? [] : base
            for part in name.split(separator: "\\", omittingEmptySubsequences: true) {
                if part == "." { continue }
                if part == ".." {
                    if !components.isEmpty { components.removeLast() }
                    continue
                }
                components.append(String(part))
            }
            return components
        }

        private func fileOpen(this: UInt64, outAddress: UInt64, nameAddress: UInt64, mode: UInt64) -> UInt64 {
            guard let object = fileObjects[this], let volume = fatVolume else { return notFound }
            let name = readString16(nameAddress)
            let components = resolveComponents(base: object.path, name: name)
            if components.isEmpty {
                let root = makeFileObject(path: [], entry: nil, isDirectory: true)
                guard root != 0 else { return outOfResources }
                write(outAddress, root, size: 8)
                return success
            }
            let directoryPath = [String](components.dropLast())
            let fileName = components.last!
            if let entry = volume.resolve(path: components) {
                if entry.isDirectory {
                    let child = makeFileObject(path: components, entry: entry, isDirectory: true)
                    guard child != 0 else { return outOfResources }
                    write(outAddress, child, size: 8)
                    return success
                }
                let child = makeFileObject(path: directoryPath, entry: entry, isDirectory: false)
                guard child != 0 else { return outOfResources }
                fileObjects[child]?.writable = mode & 0x2 != 0 || mode & 0x8000000000000000 != 0
                write(outAddress, child, size: 8)
                return success
            }
            // 新規作成（CREATE ビット）
            if mode & 0x8000000000000000 != 0 {
                if !directoryPath.isEmpty, volume.resolve(path: directoryPath) == nil {
                    return notFound
                }
                let child = makeFileObject(path: directoryPath, entry: nil, isDirectory: false)
                guard child != 0 else { return outOfResources }
                fileObjects[child]?.createName = fileName
                fileObjects[child]?.writable = true
                fileObjects[child]?.writeContents = []
                write(outAddress, child, size: 8)
                return success
            }
            return notFound
        }

        private func writeFileInfo(at address: UInt64, entry: FATVolume.Entry) {
            var info = [UInt8](repeating: 0, count: 80)
            put64(&info, 0, UInt64(80 + (entry.name.utf16.count + 1) * 2))
            put64(&info, 8, UInt64(entry.size))
            put64(&info, 16, UInt64(entry.size))
            put64(&info, 72, entry.isDirectory ? 0x10 : 0)
            writeBytes(address, info)
            writeString16(address + 80, entry.name)
        }

        private func fileRead(this: UInt64, sizeAddress: UInt64, buffer: UInt64) -> UInt64 {
            guard let object = fileObjects[this], let volume = fatVolume else { return notFound }
            let capacity = Int(read(sizeAddress, size: 8))
            if object.isDirectory {
                let listing = volume.listDirectory(cluster: object.entry?.firstCluster ?? 0)
                    .filter { !$0.isVolumeLabel && $0.name != "." && $0.name != ".." }
                guard object.directoryIndex < listing.count else {
                    write(sizeAddress, 0, size: 8)
                    return success
                }
                let entry = listing[object.directoryIndex]
                let infoSize = 80 + (entry.name.utf16.count + 1) * 2
                guard capacity >= infoSize else {
                    write(sizeAddress, UInt64(infoSize), size: 8)
                    return bufferTooSmall
                }
                writeFileInfo(at: buffer, entry: entry)
                object.directoryIndex += 1
                write(sizeAddress, UInt64(infoSize), size: 8)
                return success
            }
            let contents = object.writeContents ?? (object.entry.map { volume.readFile($0) } ?? [])
            let available = max(0, contents.count - Int(object.position))
            let count = min(capacity, available)
            if count > 0 {
                let start = Int(object.position)
                writeBytes(buffer, [UInt8](contents[start..<(start + count)]))
            }
            object.position += UInt64(count)
            write(sizeAddress, UInt64(count), size: 8)
            return success
        }

        private func fileWrite(this: UInt64, sizeAddress: UInt64, buffer: UInt64) -> UInt64 {
            guard let object = fileObjects[this], let volume = fatVolume else { return notFound }
            guard object.writable || object.writeContents != nil else { return invalidParameter }
            let size = Int(read(sizeAddress, size: 8))
            if object.writeContents == nil {
                object.writeContents = object.entry.map { volume.readFile($0) } ?? []
            }
            var contents = object.writeContents ?? []
            let position = Int(object.position)
            if position > contents.count {
                contents += [UInt8](repeating: 0, count: position - contents.count)
            }
            let bytes = readBytes(buffer, count: size)
            let end = position + size
            if end > contents.count {
                contents += [UInt8](repeating: 0, count: end - contents.count)
            }
            if size > 0 {
                contents.replaceSubrange(position..<end, with: bytes)
            }
            object.writeContents = contents
            object.position += UInt64(size)
            return success
        }

        @discardableResult
        private func commitFile(_ object: FileObject) -> UInt64 {
            guard let volume = fatVolume, let contents = object.writeContents else { return success }
            let name = object.createName ?? object.entry?.name
            guard let name else { return invalidParameter }
            do {
                try volume.writeFile(directoryPath: object.path, name: name, contents: contents)
            } catch {
                return deviceError
            }
            object.writeContents = nil
            object.createName = nil
            object.entry = volume.resolve(path: object.path + [name])
            syncDisk()
            return success
        }

        private func fileGetInfo(this: UInt64, guidAddress: UInt64, sizeAddress: UInt64, buffer: UInt64) -> UInt64 {
            guard let object = fileObjects[this], let volume = fatVolume else { return notFound }
            let guid = readGUID(guidAddress)
            let capacity = Int(read(sizeAddress, size: 8))
            if guid == guidFileInfo {
                let entry = object.entry ?? FATVolume.Entry(
                    name: "\\", shortName: [], isDirectory: true,
                    isVolumeLabel: false, firstCluster: 0, size: 0)
                let needed = 80 + (entry.name.utf16.count + 1) * 2
                guard capacity >= needed else {
                    write(sizeAddress, UInt64(needed), size: 8)
                    return bufferTooSmall
                }
                writeFileInfo(at: buffer, entry: entry)
                write(sizeAddress, UInt64(needed), size: 8)
                return success
            }
            if guid == guidFileSystemInfo {
                let label = volume.volumeLabelText
                let needed = 36 + (label.utf16.count + 1) * 2
                guard capacity >= needed else {
                    write(sizeAddress, UInt64(needed), size: 8)
                    return bufferTooSmall
                }
                var info = [UInt8](repeating: 0, count: 36)
                put64(&info, 0, UInt64(needed))
                put64(&info, 16, UInt64(volume.totalBytes))
                put64(&info, 24, UInt64(max(0, volume.totalBytes - volume.usedBytes)))
                put32(&info, 32, UInt32(volume.clusterBytes))
                writeBytes(buffer, info)
                writeString16(buffer + 36, label)
                write(sizeAddress, UInt64(needed), size: 8)
                return success
            }
            if guid == guidVolumeLabel {
                let label = volume.volumeLabelText
                let needed = (label.utf16.count + 1) * 2
                guard capacity >= needed else {
                    write(sizeAddress, UInt64(needed), size: 8)
                    return bufferTooSmall
                }
                writeString16(buffer, label)
                write(sizeAddress, UInt64(needed), size: 8)
                return success
            }
            return unsupportedStatus
        }

        // MARK: イベント / タイマ

        private func createEvent(type: UInt32, notifyFunction: UInt64,
                                 notifyContext: UInt64, eventAddress: UInt64,
                                 eventGroup: [UInt8]? = nil) -> UInt64 {
            let handle = arenaAlloc(8)
            guard handle != 0 else { return outOfResources }
            let event = EventObject()
            event.type = type
            event.notifyFunction = notifyFunction
            event.notifyContext = notifyContext
            event.eventGroup = eventGroup
            events[handle] = event
            write(eventAddress, handle, size: 8)
            return success
        }

        private func setTimer(event handle: UInt64, type: UInt64, triggerTime: UInt64) -> UInt64 {
            guard let event = events[handle] else { return invalidParameter }
            switch type {
            case 0: // TimerCancel
                event.timerType = 0
                event.timerDue = nil
                event.signaled = false
            case 1, 2: // TimerPeriodic / TimerRelative
                event.timerType = type
                event.timerPeriod100ns = triggerTime
                event.timerDue = Date().addingTimeInterval(Double(triggerTime) / 10_000_000)
            default:
                return invalidParameter
            }
            return success
        }

        // MARK: イベント通知 / ゲスト関数呼び出し

        /// 通知関数の呼び出し予約（EVT_NOTIFY_SIGNAL / WAIT のどちらか）。
        private func enqueueNotify(handle: UInt64, event: EventObject) {
            guard event.notifyFunction != 0,
                  event.type & 0x300 != 0,
                  !notifyQueue.contains(handle) else { return }
            notifyQueue.append(handle)
        }

        private func translateVirtualToPhysical(_ address: UInt64) -> UInt64? {
            for entry in virtualAddressMap {
                let size = entry.pages * 4096
                if address >= entry.virtual, address < entry.virtual + size {
                    return entry.physical + (address - entry.virtual)
                }
            }
            return nil
        }

        private func translatePhysicalToVirtual(_ address: UInt64) -> UInt64 {
            for entry in virtualAddressMap {
                let size = entry.pages * 4096
                if address >= entry.physical, address < entry.physical + size {
                    return entry.virtual + (address - entry.physical)
                }
            }
            return address
        }

        /// SetVirtualAddressMap: ランタイム領域の仮想配置を記録し、以降は
        /// 仮想アドレス経由のランタイムサービス呼び出しを受け付ける。
        private func setVirtualAddressMap(mapSize: UInt64, descriptorSize: UInt64, mapAddress: UInt64) -> UInt64 {
            guard !virtualAddressMapSet else { return invalidParameter }
            guard descriptorSize >= 40, mapSize > 0, mapSize % descriptorSize == 0 else { return invalidParameter }
            var entries: [(physical: UInt64, virtual: UInt64, pages: UInt64)] = []
            for index in 0..<Int(mapSize / descriptorSize) {
                let base = mapAddress + UInt64(index) * descriptorSize
                let physical = read(base + 8, size: 8)
                let virtual = read(base + 16, size: 8)
                let pages = read(base + 24, size: 8)
                let attribute = read(base + 32, size: 8)
                if attribute & 0x8000000000000000 != 0, pages > 0 {
                    entries.append((physical: physical, virtual: virtual, pages: pages))
                }
            }
            virtualAddressMap = entries
            virtualAddressMapSet = true
            signalEventGroup(0x602) // EVT_SIGNAL_VIRTUAL_ADDRESS_CHANGE
            return success
        }

        /// シグナルグループ（ExitBootServices / VirtualAddressChange）の発火。
        private func signalEventGroup(_ mask: UInt32) {
            let groupGUID = mask == 0x202 ? guidEventGroupEBS : (mask == 0x602 ? guidEventGroupVAC : nil)
            for (handle, event) in events {
                let byType = event.type & mask == mask
                let byGroup = groupGUID != nil && event.eventGroup == groupGUID
                if byType || byGroup {
                    event.signaled = true
                    enqueueNotify(handle: handle, event: event)
                }
            }
        }

        /// セッションループから呼ばれる。タイマ期限を反映し、保留中の
        /// 通知があれば 1 件だけゲスト関数として実行開始する（戻りは
        /// guestCallTrap が処理する）。
        func deliverNotifications() {
            for (handle, event) in events where event.timerDue != nil {
                if refreshEvent(event) { enqueueNotify(handle: handle, event: event) }
            }
            guard guestCallStack.isEmpty, !cpu.halted else { return }
            while let handle = notifyQueue.first {
                notifyQueue.removeFirst()
                guard let event = events[handle], event.notifyFunction != 0 else { continue }
                guard canAllocPages(count: 16) else { return }
                let frame = GuestCallFrame(
                    savedRegisters: (0..<16).map { cpu.register64($0) },
                    savedStackPointer: cpu.register64(4),
                    savedInstructionPointer: cpu.instructionPointer,
                    isDriverCall: false, driverContext: nil)
                guestCallStack.append(frame)
                beginGuestCall(function: event.notifyFunction,
                               arguments: [handle, event.notifyContext])
                return
            }
        }

        /// ゲスト関数呼び出しの開始（専用スタック + 戻りトラップ）。
        /// 戻り値は確保したスタックのベース（失敗時は 0）。
        @discardableResult
        private func beginGuestCall(function: UInt64, arguments: [UInt64]) -> UInt64 {
            let stackSize = 0x10000
            guard let stackBase = allocPagesInternal(count: stackSize / 4096, memoryType: 4, kind: .firmware) else {
                return 0
            }
            guestCallStacks.append(stackBase)
            let stackTop = stackBase + UInt64(stackSize)
            write(stackTop - 8, translatePhysicalToVirtual(stubAddress(.guestCallTrap)), size: 8)
            cpu.setRegister64(4, stackTop - 8)
            let registerIndices = [1, 2, 8, 9] // RCX / RDX / R8 / R9
            for (index, value) in arguments.prefix(4).enumerated() {
                cpu.setRegister64(registerIndices[index], value)
            }
            for (offset, value) in arguments.dropFirst(4).enumerated() {
                write(stackTop - 8 + 32 + UInt64(offset * 8), value, size: 8)
            }
            cpu.redirectExecution(to: function)
            return stackBase
        }

        /// ゲスト関数から戻ってきたときの処理。
        private func finishGuestCall() -> Bool {
            guard let frame = guestCallStack.popLast() else {
                cpu.halt(exitCode: 0)
                return true
            }
            if let stackBase = guestCallStacks.popLast() {
                freeRecordInternal(address: stackBase)
            }
            if frame.isDriverCall, let context = frame.driverContext {
                return continueDriverCall(frame: frame, context: context,
                                          status: cpu.register64(0))
            }
            for index in 0..<16 {
                cpu.setRegister64(index, frame.savedRegisters[index])
            }
            cpu.setRegister64(4, frame.savedStackPointer)
            cpu.redirectExecution(to: frame.savedInstructionPointer)
            return true
        }

        // MARK: ドライババインディング（ConnectController / DisconnectController）

        private func connectControllerCall() -> Bool {
            let controller = cpu.register64(1)
            let remainingPath = cpu.register64(8)
            var bindings: [(interface: UInt64, imageHandle: UInt64)] = []
            for handle in handleOrder {
                if let interface = protocolDB[handle]?[guidDriverBinding] {
                    bindings.append((interface, read(interface + 32, size: 8)))
                }
            }
            guard !bindings.isEmpty else { return returnToCaller(status: success) }
            guard canAllocPages(count: 16) else {
                return returnToCaller(status: outOfResources)
            }
            let context = DriverCallContext(
                controller: controller, remainingPath: remainingPath,
                bindings: bindings, index: 0, stage: 0,
                anyStarted: false, lastError: success, disconnect: false)
            let frame = GuestCallFrame(
                savedRegisters: (0..<16).map { cpu.register64($0) },
                savedStackPointer: cpu.register64(4),
                savedInstructionPointer: 0,
                isDriverCall: true, driverContext: context)
            guestCallStack.append(frame)
            callDriverBinding(context: context)
            return true
        }

        private func disconnectControllerCall() -> Bool {
            let controller = cpu.register64(1)
            let drivers = startedDrivers[controller] ?? []
            guard !drivers.isEmpty else { return returnToCaller(status: success) }
            guard canAllocPages(count: 16) else {
                return returnToCaller(status: outOfResources)
            }
            startedDrivers[controller] = nil
            let context = DriverCallContext(
                controller: controller, remainingPath: 0,
                bindings: [drivers].flatMap { $0 }.reversed().map { $0 },
                index: 0, stage: 0,
                anyStarted: false, lastError: success, disconnect: true)
            let frame = GuestCallFrame(
                savedRegisters: (0..<16).map { cpu.register64($0) },
                savedStackPointer: cpu.register64(4),
                savedInstructionPointer: 0,
                isDriverCall: true, driverContext: context)
            guestCallStack.append(frame)
            let binding = context.bindings[0]
            beginGuestCall(function: read(binding.interface + 16, size: 8),
                           arguments: [binding.interface, controller, 0, 0])
            return true
        }

        /// DriverBinding の Supported（stage 0）/ Start（stage 1）を呼ぶ。
        private func callDriverBinding(context: DriverCallContext) {
            let binding = context.bindings[context.index]
            let function = read(binding.interface + UInt64(context.stage == 0 ? 0 : 8), size: 8)
            beginGuestCall(function: function,
                           arguments: [binding.interface, context.controller,
                                       context.remainingPath])
        }

        private func continueDriverCall(frame: GuestCallFrame,
                                        context: DriverCallContext,
                                        status: UInt64) -> Bool {
            var context = context
            var frame = frame
            if context.disconnect {
                context.index += 1
                if context.index < context.bindings.count {
                    frame.driverContext = context
                    guestCallStack.append(frame)
                    let binding = context.bindings[context.index]
                    beginGuestCall(function: read(binding.interface + 16, size: 8),
                                   arguments: [binding.interface, context.controller, 0, 0])
                    return true
                }
                return finishDriverCall(frame: frame, status: success)
            }
            if context.stage == 0 {
                if status == success {
                    context.stage = 1
                    frame.driverContext = context
                    guestCallStack.append(frame)
                    callDriverBinding(context: context)
                    return true
                }
                context.lastError = status
            } else {
                if status == success {
                    context.anyStarted = true
                    startedDrivers[context.controller, default: []].append(
                        context.bindings[context.index])
                } else {
                    context.lastError = status
                }
                context.stage = 0
                context.index += 1
            }
            if context.index < context.bindings.count {
                frame.driverContext = context
                guestCallStack.append(frame)
                callDriverBinding(context: context)
                return true
            }
            return finishDriverCall(frame: frame,
                                    status: context.anyStarted ? success : context.lastError)
        }

        private func finishDriverCall(frame: GuestCallFrame, status: UInt64) -> Bool {
            for index in 0..<16 where index != 0 && index != 4 {
                cpu.setRegister64(index, frame.savedRegisters[index])
            }
            cpu.setRegister64(4, frame.savedStackPointer)
            return returnToCaller(status: status)
        }

        /// デバイスパスからファイルパス部分を取り出す（"\\" 区切り）。
        private func filePathFromDevicePath(_ address: UInt64) -> String? {
            var offset = address
            var path = ""
            for _ in 0..<64 {
                let type = read(offset, size: 1)
                let subtype = read(offset + 1, size: 1)
                let length = Int(read(offset + 2, size: 2))
                guard length >= 4, length <= 4096 else { return nil }
                if type == 0x7F, subtype == 0xFF { break }
                if type == 4, subtype == 4 {
                    var index = offset + 4
                    let end = offset + UInt64(length)
                    while index + 1 < end {
                        let unit = read(index, size: 2)
                        if unit == 0 { break }
                        if let scalar = UnicodeScalar(UInt32(unit)) {
                            path.append(Character(scalar))
                        }
                        index += 2
                    }
                }
                offset += UInt64(length)
            }
            let normalized = path.replacingOccurrences(of: "/", with: "\\")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            return normalized.isEmpty ? nil : normalized
        }

        /// タイマの期限到来をイベントへ反映し、シグナル状態を返す。
        private func refreshEvent(_ event: EventObject) -> Bool {
            if event === conInEvent {
                keyQueueLock.lock()
                event.signaled = !keyQueue.isEmpty
                keyQueueLock.unlock()
                return event.signaled
            }
            if let due = event.timerDue, Date() >= due {
                event.signaled = true
                if event.timerType == 1, event.timerPeriod100ns > 0 {
                    event.timerDue = due.addingTimeInterval(
                        Double(event.timerPeriod100ns) / 10_000_000)
                } else {
                    event.timerDue = nil
                    event.timerType = 0
                }
            }
            return event.signaled
        }

        /// CheckEvent 用: シグナルされていれば消費して true。
        private func checkEvent(_ handle: UInt64) -> Bool {
            guard let event = events[handle] else { return false }
            let signaled = refreshEvent(event)
            if signaled { event.signaled = false }
            return signaled
        }

        private func waitForEvent(count: UInt64, arrayAddress: UInt64,
                                  indexAddress: UInt64) -> UInt64 {
            guard count > 0, count <= 64 else { return invalidParameter }
            let handles = (0..<Int(count)).map {
                read(arrayAddress + UInt64($0 * 8), size: 8)
            }
            guard handles.allSatisfy({ events[$0] != nil }) else { return invalidParameter }
            for handle in handles {
                if let event = events[handle], event.type & 0x100 != 0 {
                    enqueueNotify(handle: handle, event: event)
                }
            }
            // 最大 30 秒ポーリングする。タイマのないイベントはこの場では
            // 発火しようがないため、即座に EFI_NOT_READY を返す。
            for _ in 0..<30_000 {
                for (index, handle) in handles.enumerated() {
                    if let event = events[handle], refreshEvent(event) {
                        event.signaled = false
                        write(indexAddress, UInt64(index), size: 8)
                        return success
                    }
                }
                guard handles.contains(where: { events[$0]?.timerDue != nil || $0 == conInEventHandle }) else {
                    return notReady
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return notReady
        }

        // MARK: イメージ読み込み

        private func loadImage(parentHandle: UInt64, devicePath: UInt64, sourceBuffer: UInt64,
                               sourceSize: UInt64, handleAddress: UInt64) -> UInt64 {
            let data: [UInt8]
            if sourceBuffer != 0 {
                guard sourceSize > 0,
                      sourceSize <= 16 * 1024 * 1024 else { return invalidParameter }
                data = readBytes(sourceBuffer, count: Int(sourceSize))
            } else if devicePath != 0 {
                // デバイスパスのファイルパスノードから SFS ボリューム上の
                // ファイルを読む
                guard let path = filePathFromDevicePath(devicePath),
                      let volume = fatVolume,
                      let entry = volume.resolve(path: path.split(separator: "\\").map(String.init)),
                      !entry.isDirectory else { return notFound }
                data = volume.readFile(entry)
            } else {
                return invalidParameter
            }
            guard let info = X86UEFI.parsePE(data),
                  info.machine == 0x8664 else { return unsupportedStatus }
            if isSecureBootActive {
                // dbx にあれば拒否、db になければ拒否（イメージハッシュ方式）
                guard let hash = X86UEFI.authenticodeHash(data) else { return securityViolation }
                if signatureDatabaseHashes(name: "dbx").contains(hash) { return securityViolation }
                guard signatureDatabaseHashes(name: "db").contains(hash) else { return securityViolation }
            }
            let size = (Int(info.sizeOfImage) + 0xFFF) & ~0xFFF
            // 配置先: 希望 ImageBase が空いていればそこ、駄目なら読み込み領域の空きへ
            let preferred = Int(info.imageBase)
            let loadBase: Int
            if preferred >= 0x110000, preferred + size <= X86UEFI.loadRegionEnd,
               !rangesOverlap(preferred, size) {
                loadBase = preferred
            } else if let fitted = firstFitImageAddress(size: size) {
                loadBase = fitted
            } else {
                return outOfResources
            }
            guard X86UEFI.stageImage(cpu: cpu, data: data, info: info, base: loadBase) else {
                return unsupportedStatus // 再配置情報が無く希望ベースに置けない
            }
            imageRegionAllocations.append((base: loadBase, size: size))
            let handle = arenaAlloc(8)
            let structAddress = arenaAlloc(104)
            guard handle != 0, structAddress != 0 else { return outOfResources }
            installLoadedImage(handle: handle, parentHandle: parentHandle,
                               imageAddress: UInt64(loadBase),
                               imageSize: Int(info.sizeOfImage),
                               structAddress: structAddress)
            loadedImages[handle] = LoadedImageInfo(
                base: UInt64(loadBase), size: Int(info.sizeOfImage),
                entry: UInt64(loadBase) + UInt64(info.entryRVA),
                parentHandle: parentHandle, loadedImageStruct: structAddress)
            write(handleAddress, handle, size: 8)
            return success
        }

        /// ロード領域内の first-fit 空きアドレスを探す。
        private func firstFitImageAddress(size: Int) -> Int? {
            var candidate = X86UEFI.loadRegionStart
            let sorted = imageRegionAllocations.sorted { $0.base < $1.base }
            for allocation in sorted {
                if candidate + size <= allocation.base { break }
                if candidate < allocation.base + allocation.size {
                    candidate = allocation.base + allocation.size
                }
            }
            return candidate + size <= X86UEFI.loadRegionEnd ? candidate : nil
        }

        /// [base, base+size) が既存の確保領域と重なるか。
        private func rangesOverlap(_ base: Int, _ size: Int) -> Bool {
            let end = base + size
            var reserved: [(Int, Int)] = [
                (0x100000, 0x400000), // ファームウェア構造 + スタック
                (Int(imageBase), Int(imageBase) + sizeOfImage), // 起動イメージ
            ]
            for (start, record) in pageRecords {
                reserved.append((X86UEFI.heapStart + start * 4096,
                                 X86UEFI.heapStart + (start + record.pages) * 4096))
            }
            for allocation in imageRegionAllocations {
                reserved.append((allocation.base, allocation.base + allocation.size))
            }
            return reserved.contains { base < $0.1 && $0.0 < end }
        }

        private func unloadImage(handle: UInt64) -> UInt64 {
            guard let info = loadedImages.removeValue(forKey: handle) else {
                return invalidParameter
            }
            imageRegionAllocations.removeAll { $0.base == Int(info.base) }
            protocolDB[handle]?[guidLoadedImage] = nil
            if protocolDB[handle]?.isEmpty == true {
                protocolDB[handle] = nil
                handleOrder.removeAll { $0 == handle }
            }
            return success
        }

        // MARK: ハンドル検索 / プロトコル操作

        private func locateHandle(searchType: UInt64, guidAddress: UInt64,
                                  sizeAddress: UInt64, bufferAddress: UInt64) -> UInt64 {
            var handles = handleOrder
            switch searchType {
            case 0: // AllHandles
                break
            case 2: // ByProtocol
                let guid = readGUID(guidAddress)
                handles = handles.filter { protocolDB[$0]?[guid] != nil }
            case 1: // ByRegisterNotify（登録機構がないため一致なし）
                return notFound
            default:
                return invalidParameter
            }
            guard !handles.isEmpty else { return notFound }
            let needed = handles.count * 8
            let provided = Int(read(sizeAddress, size: 8))
            guard bufferAddress != 0, provided >= needed else {
                write(sizeAddress, UInt64(needed), size: 8)
                return bufferTooSmall
            }
            for (index, handle) in handles.enumerated() {
                write(bufferAddress + UInt64(index * 8), handle, size: 8)
            }
            write(sizeAddress, UInt64(needed), size: 8)
            return success
        }

        private func locateDevicePath(guidAddress: UInt64, pathAddress: UInt64,
                                      handleAddress: UInt64) -> UInt64 {
            let guid = readGUID(guidAddress)
            for handle in handleOrder {
                guard protocolDB[handle]?[guid] != nil,
                      let path = protocolDB[handle]?[guidDevicePath] else { continue }
                write(pathAddress, path, size: 8)
                write(handleAddress, handle, size: 8)
                return success
            }
            return notFound
        }

        private func reinstallProtocolInterface(handle: UInt64, guidAddress: UInt64,
                                                oldInterface: UInt64,
                                                newInterface: UInt64) -> UInt64 {
            let guid = readGUID(guidAddress)
            guard let installed = protocolDB[handle]?[guid] else { return notFound }
            guard installed == oldInterface else { return invalidParameter }
            protocolDB[handle]?[guid] = newInterface
            return success
        }

        /// Install / UninstallMultipleProtocolInterfaces。
        /// (GUID*, Interface) の組が NULL 終端で続く。第 1 組は RDX / R8、
        /// 以降はスタック引数 5, 6, 7, 8... に並ぶ。
        /// Install の第 1 引数は *Handle、Uninstall は Handle そのもの。
        private func multipleProtocolInterfaces(firstValue: UInt64, install: Bool) -> UInt64 {
            var pairs: [(guidAddress: UInt64, interface: UInt64)] = []
            let firstGUID = cpu.register64(2)
            guard firstGUID != 0 else { return invalidParameter }
            pairs.append((firstGUID, cpu.register64(8)))
            var argument = 5
            while argument + 1 <= 10 {
                let guidAddress = stackArgument(argument)
                if guidAddress == 0 { break }
                pairs.append((guidAddress, stackArgument(argument + 1)))
                argument += 2
            }
            if install {
                var handle = read(firstValue, size: 8)
                if handle == 0 {
                    handle = arenaAlloc(8)
                    guard handle != 0 else { return outOfResources }
                    write(firstValue, handle, size: 8)
                }
                for pair in pairs {
                    installProtocol(handle: handle, guid: readGUID(pair.guidAddress),
                                    interface: pair.interface)
                }
                return success
            }
            let handle = firstValue
            for pair in pairs {
                let guid = readGUID(pair.guidAddress)
                guard protocolDB[handle]?[guid] == pair.interface else { return notFound }
                protocolDB[handle]?[guid] = nil
            }
            if protocolDB[handle]?.isEmpty == true {
                protocolDB[handle] = nil
                handleOrder.removeAll { $0 == handle }
            }
            return success
        }

        private func openProtocolInformation(handle: UInt64, guidAddress: UInt64,
                                             entriesAddress: UInt64,
                                             countAddress: UInt64) -> UInt64 {
            let guid = readGUID(guidAddress)
            guard protocolDB[handle]?[guid] != nil else { return notFound }
            let entries = arenaAlloc(32)
            guard entries != 0 else { return outOfResources }
            var entry = [UInt8](repeating: 0, count: 32)
            put64(&entry, 0, imageBase) // AgentHandle（起動イメージ）
            put64(&entry, 8, handle) // ControllerHandle
            put32(&entry, 16, 0x10) // Attributes: BY_HANDLE_PROTOCOL
            put32(&entry, 20, 1) // OpenCount
            cpu.loadData(entry, at: Int(entries))
            write(entriesAddress, entries, size: 8)
            write(countAddress, 1, size: 8)
            return success
        }

        // MARK: GOP

        private func gopQueryMode(modeNumber: UInt64, sizeAddress: UInt64,
                                  infoAddress: UInt64) -> UInt64 {
            guard modeNumber < UInt64(gopModes.count) else { return invalidParameter }
            let info = arenaAlloc(36)
            guard info != 0 else { return outOfResources }
            writeBytes(info, gopInfoBytes(mode: Int(modeNumber)))
            write(sizeAddress, 36, size: 8)
            write(infoAddress, info, size: 8)
            return success
        }

        private func gopSetMode(modeNumber: UInt64) -> UInt64 {
            guard modeNumber < UInt64(gopModes.count) else { return invalidParameter }
            if Int(modeNumber) != gopCurrentMode {
                let newSize = gopModes[Int(modeNumber)].width * gopModes[Int(modeNumber)].height * 4
                guard let newBase = allocPagesInternal(count: (newSize + 4095) / 4096,
                                                       memoryType: 6, kind: .firmware) else {
                    return outOfResources
                }
                if framebufferBase != 0 { freeRecordInternal(address: UInt64(framebufferBase)) }
                framebufferBase = Int(newBase)
                gopCurrentMode = Int(modeNumber)
                writeGOPModeStructs()
            }
            let size = framebufferWidth * framebufferHeight * 4
            cpu.loadData([UInt8](repeating: 0, count: size), at: framebufferBase)
            return success
        }

        /// Blt: VideoFill(0) / BltBufferToVideo(2) / VideoToBltBuffer(1) /
        /// VideoToVideo(3) をフレームバッファ実メモリで実行する。
        private func gopBlt(buffer: UInt64, operation: UInt64, sourceX: UInt64,
                            sourceY: UInt64, destinationX: UInt64,
                            destinationY: UInt64, width: UInt64, height: UInt64,
                            delta: UInt64) -> UInt64 {
            let framebuffer = UInt64(framebufferBase)
            let pitch = framebufferWidth * 4
            func videoOffset(_ x: UInt64, _ y: UInt64) -> UInt64 {
                framebuffer + y * UInt64(pitch) + x * 4
            }
            // GOP 仕様の範囲検証: フレームバッファをはみ出す Blt は
            // EFI_INVALID_PARAMETER（隣接メモリへの書き込みや無限ループを防ぐ）
            let fbW = UInt64(framebufferWidth), fbH = UInt64(framebufferHeight)
            guard width <= fbW, height <= fbH else { return invalidParameter }
            func rectInside(_ x: UInt64, _ y: UInt64) -> Bool {
                x <= fbW - width && y <= fbH - height
            }
            switch operation {
            case 0, 2: guard rectInside(destinationX, destinationY) else { return invalidParameter }
            case 1: guard rectInside(sourceX, sourceY) else { return invalidParameter }
            case 3: guard rectInside(sourceX, sourceY), rectInside(destinationX, destinationY) else { return invalidParameter }
            default: return invalidParameter
            }
            switch operation {
            case 0: // VideoFill: バッファ先頭の 1 ピクセルで矩形を塗る
                let pixel = read(buffer, size: 4)
                for row in 0..<height {
                    for column in 0..<width {
                        write(videoOffset(destinationX + column, destinationY + row),
                              pixel, size: 4)
                    }
                }
            case 2, 1: // BufferToVideo / VideoToBuffer
                let stride = delta == 0 ? width * 4 : delta
                for row in 0..<height {
                    for column in 0..<width {
                        if operation == 2 {
                            let source = buffer + (sourceY + row) * stride + (sourceX + column) * 4
                            write(videoOffset(destinationX + column, destinationY + row),
                                  read(source, size: 4), size: 4)
                        } else {
                            let destination = buffer + (destinationY + row) * stride
                                + (destinationX + column) * 4
                            write(destination,
                                  read(videoOffset(sourceX + column, sourceY + row), size: 4),
                                  size: 4)
                        }
                    }
                }
            case 3: // VideoToVideo（一時バッファ経由で重なりに対応）
                var pixels: [UInt32] = []
                for row in 0..<height {
                    for column in 0..<width {
                        pixels.append(UInt32(read(videoOffset(sourceX + column, sourceY + row), size: 4)))
                    }
                }
                var index = 0
                for row in 0..<height {
                    for column in 0..<width {
                        write(videoOffset(destinationX + column, destinationY + row),
                              UInt64(pixels[index]), size: 4)
                        index += 1
                    }
                }
            default:
                return invalidParameter
            }
            return success
        }

        // MARK: ランタイムサービス（時刻）

        private func getTime(timeAddress: UInt64, capabilitiesAddress: UInt64) -> UInt64 {
            guard timeAddress != 0 else { return invalidParameter }
            let now = Date()
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
            var time = [UInt8](repeating: 0, count: 16)
            put16(&time, 0, UInt16(components.year ?? 2026))
            time[2] = UInt8(components.month ?? 1)
            time[3] = UInt8(components.day ?? 1)
            time[4] = UInt8(components.hour ?? 0)
            time[5] = UInt8(components.minute ?? 0)
            time[6] = UInt8(components.second ?? 0)
            put32(&time, 8, UInt32(components.nanosecond ?? 0))
            let offsetMinutes = Int16(TimeZone.current.secondsFromGMT(for: now) / 60)
            put16(&time, 12, UInt16(bitPattern: offsetMinutes))
            writeBytes(timeAddress, time)
            if capabilitiesAddress != 0 {
                var capabilities = [UInt8](repeating: 0, count: 12)
                put32(&capabilities, 0, 1) // Resolution
                put32(&capabilities, 4, 0) // Accuracy
                writeBytes(capabilitiesAddress, capabilities)
            }
            return success
        }

        // MARK: 変数サービス

        private func getVariable(nameAddress: UInt64, guidAddress: UInt64, attributesAddress: UInt64,
                                 sizeAddress: UInt64, dataAddress: UInt64) -> UInt64 {
            let name = readString16(nameAddress)
            let guid = readGUID(guidAddress)
            guard let variable = variables.first(where: { $0.guid == guid && $0.name == name }) else {
                return notFound
            }
            if attributesAddress != 0 {
                write(attributesAddress, UInt64(variable.attributes), size: 4)
            }
            let capacity = Int(read(sizeAddress, size: 8))
            guard capacity >= variable.data.count else {
                write(sizeAddress, UInt64(variable.data.count), size: 8)
                return bufferTooSmall
            }
            writeBytes(dataAddress, variable.data)
            write(sizeAddress, UInt64(variable.data.count), size: 8)
            return success
        }

        private func setVariable(nameAddress: UInt64, guidAddress: UInt64, attributes: UInt64,
                                 dataSize: UInt64, dataAddress: UInt64) -> UInt64 {
            let name = readString16(nameAddress)
            let guid = readGUID(guidAddress)
            // Secure Boot のモード変数はファームウェアが管理する（書き込み禁止）
            if guid == guidGlobalVariable, name == "SecureBoot" || name == "SetupMode" {
                return writeProtected
            }
            // セットアップモードでないとき、セキュリティデータベース類の更新には
            // 認証付き書き込みが必要（本実装では未対応のため拒否する）
            let isSecurityDatabase = (guid == guidGlobalVariable && (name == "PK" || name == "KEK"))
                || (guid == guidImageSecurityDB && ["db", "dbx", "dbt", "dbr"].contains(name))
            if isSecurityDatabase, !isSetupMode {
                return securityViolation
            }
            if dataSize == 0 {
                variables.removeAll { $0.guid == guid && $0.name == name }
            } else {
                let data = readBytes(dataAddress, count: Int(dataSize))
                if let index = variables.firstIndex(where: { $0.guid == guid && $0.name == name }) {
                    variables[index].attributes = UInt32(attributes)
                    variables[index].data = data
                } else {
                    variables.append(X86UEFI.Variable(
                        guid: guid, name: name,
                        attributes: UInt32(attributes), data: data))
                }
            }
            if isSecurityDatabase { refreshSecureBootVariables() }
            // 合成変数（SecureBoot / SetupMode）は派生値なので永続化対象から除く
            onVariablesChanged?(variables.filter {
                !($0.guid == guidGlobalVariable && ($0.name == "SecureBoot" || $0.name == "SetupMode"))
            })
            return success
        }

        // MARK: Secure Boot

        /// PK が未登録ならセットアップモード。
        private var isSetupMode: Bool {
            variables.first { $0.guid == guidGlobalVariable && $0.name == "PK" } == nil
        }

        private var isSecureBootActive: Bool { !isSetupMode }

        /// SecureBoot / SetupMode 変数を PK の有無から再計算する。
        private func refreshSecureBootVariables() {
            upsertSyntheticVariable(name: "SecureBoot", value: isSecureBootActive ? 1 : 0)
            upsertSyntheticVariable(name: "SetupMode", value: isSetupMode ? 1 : 0)
        }

        private func upsertSyntheticVariable(name: String, value: UInt8) {
            if let index = variables.firstIndex(where: { $0.guid == guidGlobalVariable && $0.name == name }) {
                variables[index].data = [value]
                variables[index].attributes = 0x3 // BS | RT
            } else {
                variables.append(X86UEFI.Variable(
                    guid: guidGlobalVariable, name: name, attributes: 0x3, data: [value]))
            }
        }

        /// 署名データベース（db / dbx）から SHA-256 イメージハッシュの一覧を取り出す。
        private func signatureDatabaseHashes(name: String) -> [[UInt8]] {
            guard let variable = variables.first(where: { $0.guid == guidImageSecurityDB && $0.name == name }) else {
                return []
            }
            let data = variable.data
            func u32(_ offset: Int) -> Int {
                Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            }
            var hashes: [[UInt8]] = []
            var offset = 0
            while offset + 28 <= data.count {
                let listSize = u32(offset + 16)
                let headerSize = u32(offset + 20)
                let signatureSize = u32(offset + 24)
                guard listSize >= 28, signatureSize >= 48, offset + listSize <= data.count else { break }
                if Array(data[offset..<(offset + 16)]) == guidCertSHA256 {
                    var entry = offset + 28 + headerSize
                    while entry + 48 <= offset + listSize {
                        hashes.append(Array(data[(entry + 16)..<(entry + 48)]))
                        entry += signatureSize
                    }
                }
                offset += listSize
            }
            return hashes
        }

        private func getNextVariableName(sizeAddress: UInt64, nameAddress: UInt64, guidAddress: UInt64) -> UInt64 {
            let capacity = Int(read(sizeAddress, size: 8))
            let currentName = readString16(nameAddress)
            let currentGUID = readGUID(guidAddress)
            // 列挙順序は仕様上不定。互換性のため、ファームウェア合成変数
            // （SecureBoot / SetupMode）はゲストが作った変数の後ろに並べる。
            func isSynthetic(_ variable: X86UEFI.Variable) -> Bool {
                variable.guid == guidGlobalVariable && (variable.name == "SecureBoot" || variable.name == "SetupMode")
            }
            let ordered = variables.filter { !isSynthetic($0) } + variables.filter { isSynthetic($0) }
            var nextIndex = 0
            if !currentName.isEmpty {
                guard let index = ordered.firstIndex(where: { $0.guid == currentGUID && $0.name == currentName }) else {
                    return notFound
                }
                nextIndex = index + 1
            }
            guard nextIndex < ordered.count else { return notFound }
            let next = ordered[nextIndex]
            let needed = (next.name.utf16.count + 1) * 2
            guard capacity >= needed else {
                write(sizeAddress, UInt64(needed), size: 8)
                return bufferTooSmall
            }
            writeString16(nameAddress, next.name)
            writeBytes(guidAddress, next.guid)
            write(sizeAddress, UInt64(needed), size: 8)
            return success
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
