import Foundation

/// アプリに内蔵されたサンプルイメージ。
///
/// GitHub Releases で配布しているサンプル（x86 カーネル / UEFI アプリ /
/// BIOS ブート ISO / RISC-V サンプル ISO）と同一内容をアプリへ同梱し、
/// ファイルを用意しなくてもそのまま起動できるようにする。
/// バイナリ本体は `BuiltInSampleData`（Base64）にあり、初回アクセス時に
/// 復号してキャッシュする。各ケースの `sha256` は配布物と一致すること。
enum BuiltInSample: String, Codable, CaseIterable, Identifiable {
    case kernel
    case lm
    case ring
    case devices
    case dma
    case task
    case fpu
    case cpux
    case osx
    case biosISO
    case uefi
    case uefi2
    case uefi3
    case uefi4
    case uefi5
    case lfn
    case riscvISO

    var id: String { rawValue }

    /// このサンプルが対象とするアーキテクチャ。
    var architecture: CPUArchitecture {
        switch self {
        case .riscvISO: return .riscv
        default: return .x86
        }
    }

    /// 表示名
    var displayName: String {
        switch self {
        case .kernel: return "サンプルカーネル（Multiboot）"
        case .lm: return "ロングモード カーネル"
        case .ring: return "特権リング カーネル"
        case .devices: return "周辺デバイス カーネル"
        case .dma: return "IDE DMA カーネル"
        case .task: return "タスクスイッチ カーネル"
        case .fpu: return "FPU / SSE カーネル"
        case .cpux: return "CPU 拡張カーネル"
        case .osx: return "macOS 基盤カーネル"
        case .biosISO: return "BIOS ブート ISO"
        case .uefi: return "UEFI アプリ（基本）"
        case .uefi2: return "UEFI アプリ 2（プロトコル / FAT）"
        case .uefi3: return "UEFI アプリ 3（Loaded Image / 変数）"
        case .uefi4: return "UEFI アプリ 4（ConIn / 通知 / ドライバ）"
        case .uefi5: return "UEFI アプリ 5（アロケータ / Secure Boot）"
        case .lfn: return "UEFI アプリ（FAT ロングファイル名）"
        case .riscvISO: return "RISC-V サンプル ISO"
        }
    }

    /// サンプルの説明
    var detail: String {
        switch self {
        case .kernel: return "Multiboot 対応の最小カーネル"
        case .lm: return "64 ビット ロングモードと APIC / ACPI の確認"
        case .ring: return "リング 0〜3 と SYSCALL / SYSRET の確認"
        case .devices: return "PIC / PIT / キーボード / PCI / IDE の確認"
        case .dma: return "IDE バスマスタ DMA の確認"
        case .task: return "TSS タスクスイッチと SWAPGS の確認"
        case .fpu: return "x87 FPU と SSE / SSE2 の確認"
        case .cpux: return "MMX / SSE3〜4.1 / XSAVE / VGA モード 13h の確認"
        case .osx: return "CPUID / HPET / SMC / SMBIOS / AHCI の確認"
        case .biosISO: return "El Torito 対応 ISO から BIOS ブート"
        case .uefi: return "ConOut と基本ブートサービスの確認"
        case .uefi2: return "プロトコル DB / Block I/O / FAT の確認"
        case .uefi3: return "Loaded Image / GOP / 変数の永続化の確認"
        case .uefi4: return "ConIn / イベント通知 / Driver Binding の確認"
        case .uefi5: return "メモリアロケータ / Secure Boot / GOP モードの確認"
        case .lfn: return "FAT ロングファイル名の読み書きの確認"
        case .riscvISO: return "BOOT.BIN 入りの RISC-V 用 ISO"
        }
    }

    /// SF Symbol 名
    var systemImage: String {
        switch self {
        case .biosISO, .riscvISO: return "opticaldisc"
        case .uefi, .uefi2, .uefi3, .uefi4, .uefi5, .lfn: return "app.badge"
        default: return "cpu"
        }
    }

    /// 配布サンプルと同一であることを示す SHA-256（16 進小文字）。
    var sha256: String {
        switch self {
        case .kernel: return "a4d4e9afc8c680ae84c4d277fb3a367d160397bc74ce2ca06a227383b47fc221"
        case .lm: return "b08d8b591fe2ca948d60464250b356194882ea7935f3b79a4cdb5759bc431e7a"
        case .ring: return "8c6b4006205e235347470a5d0cacb48b65d167d9b7d84ba172e438904a7eeddf"
        case .devices: return "ee81491f322c09aedbd87d38c62fe0b1f6eaadf70e5dce8596fcef58514b5c7d"
        case .dma: return "8c6541849a9501d3176805532a4aa803e5fc3f32a3dd48e30c7b7a06d93e26c0"
        case .task: return "795627e5628ccfb579ca2b7b7c80cb0e067264c5593fbf0c5b2c1e6c0d64429d"
        case .fpu: return "4be9dc2406888c4e7a9ed50a1c9c5c4d740c596f89a7330263e53a69b23b30ff"
        case .cpux: return "69465a96a1bb05b0b27b158fc570f535b06c6be75c755656ca5eb07903675f1a"
        case .osx: return "a58507bc55f389bb105d2405cb06bcc50aa04c10837cf38e4cc17e152c101bd0"
        case .biosISO: return "9bb97151ebf15b1d839c630235cb8d77c6c206a6043c55ea23be57c67ac3da7a"
        case .uefi: return "bec86ae9fd989c60f1570b90f5c186da09cea56d460f46f59225eeb163135e49"
        case .uefi2: return "a35b4653ccaa5d76831c092ae073fa1a95b2a398878b947c34863f8d8a1f3e47"
        case .uefi3: return "991d5f41aaedfa2963d15cc50fc0f29ab7e3b0d7de695a0e7ff6859158452303"
        case .uefi4: return "af22c1d5de206daf5ad70ba3f0d7c738a7704311ffec5778997f400a37736c1a"
        case .uefi5: return "776a3a80ec2c1ee37a4db443dd077636b4187aa6f06d73398141fa54288d89c8"
        case .lfn: return "3a446ba0c46be1d3410bd726e22cb13638ce623a2a08dcc93d18716012fca9b7"
        case .riscvISO: return "e94879be89cac56a63f8600cb0d0d34e8dee0540350ebe24a6e729d0e318ddfa"
        }
    }

    /// Base64 文字列（生成ファイル側）。
    private var base64: String {
        switch self {
        case .kernel: return BuiltInSampleData.kernel
        case .lm: return BuiltInSampleData.lm
        case .ring: return BuiltInSampleData.ring
        case .devices: return BuiltInSampleData.devices
        case .dma: return BuiltInSampleData.dma
        case .task: return BuiltInSampleData.task
        case .fpu: return BuiltInSampleData.fpu
        case .cpux: return BuiltInSampleData.cpux
        case .osx: return BuiltInSampleData.osx
        case .biosISO: return BuiltInSampleData.biosISO
        case .uefi: return BuiltInSampleData.uefi
        case .uefi2: return BuiltInSampleData.uefi2
        case .uefi3: return BuiltInSampleData.uefi3
        case .uefi4: return BuiltInSampleData.uefi4
        case .uefi5: return BuiltInSampleData.uefi5
        case .lfn: return BuiltInSampleData.lfn
        case .riscvISO: return BuiltInSampleData.riscvISO
        }
    }

    /// 復号済みデータのキャッシュ（スレッド安全）。
    private static let cacheLock = NSLock()
    private static var cache: [BuiltInSample: [UInt8]] = [:]

    /// サンプルのバイナリデータ。
    var data: [UInt8] {
        Self.cacheLock.lock()
        if let cached = Self.cache[self] {
            Self.cacheLock.unlock()
            return cached
        }
        Self.cacheLock.unlock()
        let decoded = [UInt8](Data(base64Encoded: base64) ?? Data())
        Self.cacheLock.lock()
        Self.cache[self] = decoded
        Self.cacheLock.unlock()
        return decoded
    }

    /// 指定アーキテクチャ向けの内蔵サンプル一覧。
    static func samples(for architecture: CPUArchitecture) -> [BuiltInSample] {
        allCases.filter { $0.architecture == architecture }
    }
}
