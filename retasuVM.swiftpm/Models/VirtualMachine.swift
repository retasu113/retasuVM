import Foundation

/// 仮想マシンの状態。
///
/// 状態は色だけに頼らず、必ずラベル（文字列）とシンボルでも表す
/// （HIG: 色のみで情報を伝えない）。
enum VMState: String, Codable, CaseIterable {
    case stopped
    case running
    case paused
    case error

    /// 画面表示・VoiceOver 共通のラベル
    var label: String {
        switch self {
        case .stopped: return "停止中"
        case .running: return "実行中"
        case .paused: return "一時停止中"
        case .error: return "エラー"
        }
    }

    /// 状態を表す SF Symbol 名
    var systemImage: String {
        switch self {
        case .stopped: return "stop.circle.fill"
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// ゲスト OS の種類。
enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case linux
    case macOS
    case windows
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .other: return "その他"
        }
    }

    var systemImage: String {
        switch self {
        case .linux: return "terminal"
        case .macOS: return "macwindow"
        case .windows: return "pc"
        case .other: return "desktopcomputer"
        }
    }
}

/// エミュレーションする CPU アーキテクチャ。
enum CPUArchitecture: String, Codable, CaseIterable, Identifiable {
    case riscv
    case x86
    case arm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .riscv: return "RISC-V"
        case .x86: return "x86"
        case .arm: return "ARM"
        }
    }

    /// 仕様の要約（設定画面や詳細画面の表示用）
    var detail: String {
        switch self {
        case .riscv: return "RV32IM ソフトウェア CPU"
        case .x86: return "16 ビット リアルモード + BIOS"
        case .arm: return "ARMv7-A (A32) サブセット"
        }
    }

    var systemImage: String {
        switch self {
        case .riscv: return "terminal"
        case .x86: return "desktopcomputer"
        case .arm: return "cpu"
        }
    }
}

/// 仮想マシンのハードウェア構成。
struct VMConfiguration: Equatable {
    var cpuCount: Int = 2
    var memoryMB: Int = 4096
    var diskGB: Int = 32
    /// エミュレーションする CPU アーキテクチャ
    var architecture: CPUArchitecture = .riscv
    var guestOS: GuestOS = .linux
    /// 起動するゲスト OS イメージ（実際にエミュレータで動くもの）
    var guestImage: GuestImage = .retasuOS
    /// ISO ファイルから起動するか（true の場合は guestImage より優先）
    var useISO: Bool = false
    /// アプリ内にコピーした ISO の保存名（useISO のときのみ）
    var isoFileName: String? = nil
    /// 選択した ISO の元のファイル名（表示用）
    var isoDisplayName: String? = nil
    var networkEnabled: Bool = true
    var sharedFolderEnabled: Bool = false

    var memoryText: String {
        if memoryMB >= 1024 {
            let gb = Double(memoryMB) / 1024.0
            return String(format: "%.0f GB", gb)
        }
        return "\(memoryMB) MB"
    }

    var summary: String {
        "\(cpuCount) CPU / \(memoryText) / \(diskGB) GB"
    }

    /// 一覧・詳細で使う起動対象の表示名。
    var bootTargetName: String {
        switch architecture {
        case .riscv:
            return useISO ? (isoDisplayName ?? "ISO ファイル") : guestImage.displayName
        case .x86:
            return isoDisplayName ?? "イメージファイル"
        case .arm:
            return "ArmDemoOS"
        }
    }

    /// 一覧・詳細で使うアイコン名。
    var bootSystemImage: String {
        switch architecture {
        case .riscv:
            return useISO ? "opticaldisc" : guestImage.systemImage
        case .x86:
            return "opticaldisc"
        case .arm:
            return "cpu"
        }
    }

    /// コンソールのクイックコマンド。
    var quickCommands: [String] {
        switch architecture {
        case .riscv:
            return useISO ? ["info", "help"] : guestImage.quickCommands
        case .x86:
            return []
        case .arm:
            return ["fact", "help", "quit"]
        }
    }
}

extension VMConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case cpuCount, memoryMB, diskGB, architecture, guestOS, guestImage
        case useISO, isoFileName, isoDisplayName
        case networkEnabled, sharedFolderEnabled
    }

    /// 旧バージョンの保存データ（新しいキーが無い）も読み込めるよう、
    /// 各キーを任意としてデコードする。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2
        memoryMB = try container.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 4096
        diskGB = try container.decodeIfPresent(Int.self, forKey: .diskGB) ?? 32
        architecture = try container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture) ?? .riscv
        guestOS = try container.decodeIfPresent(GuestOS.self, forKey: .guestOS) ?? .linux
        guestImage = try container.decodeIfPresent(GuestImage.self, forKey: .guestImage) ?? .retasuOS
        useISO = try container.decodeIfPresent(Bool.self, forKey: .useISO) ?? false
        isoFileName = try container.decodeIfPresent(String.self, forKey: .isoFileName)
        isoDisplayName = try container.decodeIfPresent(String.self, forKey: .isoDisplayName)
        networkEnabled = try container.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        sharedFolderEnabled = try container.decodeIfPresent(Bool.self, forKey: .sharedFolderEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memoryMB, forKey: .memoryMB)
        try container.encode(diskGB, forKey: .diskGB)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(guestOS, forKey: .guestOS)
        try container.encode(guestImage, forKey: .guestImage)
        try container.encode(useISO, forKey: .useISO)
        try container.encodeIfPresent(isoFileName, forKey: .isoFileName)
        try container.encodeIfPresent(isoDisplayName, forKey: .isoDisplayName)
        try container.encode(networkEnabled, forKey: .networkEnabled)
        try container.encode(sharedFolderEnabled, forKey: .sharedFolderEnabled)
    }
}

/// 仮想マシン 1 台分のデータ。
struct VirtualMachine: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var configuration: VMConfiguration
    var state: VMState
    var createdAt: Date
    var lastStartedAt: Date?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        name: String,
        configuration: VMConfiguration = VMConfiguration(),
        state: VMState = .stopped,
        createdAt: Date = Date(),
        lastStartedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.state = state
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
        self.errorMessage = errorMessage
    }
}
