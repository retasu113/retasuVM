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
        case .x86: return "リアルモード + 32 ビット プロテクトモード"
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
/// 永続化する UEFI 変数 1 件（x86 UEFI セッションと受け渡す）。
struct UEFIVariableRecord: Codable, Equatable {
    var guid: [UInt8]
    var name: String
    var attributes: UInt32
    var data: [UInt8]
}

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
    /// 永続化された UEFI 変数（x86 の UEFI 起動時に引き継ぐ）
    var uefiVariables: [UEFIVariableRecord] = []

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
        case uefiVariables
    }

    /// 旧バージョンの保存データ（新しいキーが無い）も読み込めるよう、
    /// 各キーを任意としてデコードする。未知の enum 値や型の不一致が
    /// あっても全体が読めなくならないよう、値を 1 つずつ寛容に解釈する。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = Self.tolerantInt(container, .cpuCount) ?? 2
        memoryMB = Self.tolerantInt(container, .memoryMB) ?? 4096
        diskGB = Self.tolerantInt(container, .diskGB) ?? 32
        architecture = Self.tolerantEnum(CPUArchitecture.self, container, .architecture) ?? .riscv
        guestOS = Self.tolerantEnum(GuestOS.self, container, .guestOS) ?? .linux
        guestImage = Self.tolerantEnum(GuestImage.self, container, .guestImage) ?? .retasuOS
        useISO = Self.tolerantBool(container, .useISO) ?? false
        isoFileName = Self.tolerantString(container, .isoFileName)
        isoDisplayName = Self.tolerantString(container, .isoDisplayName)
        networkEnabled = Self.tolerantBool(container, .networkEnabled) ?? true
        sharedFolderEnabled = Self.tolerantBool(container, .sharedFolderEnabled) ?? false
        uefiVariables = (try? container.decodeIfPresent([UEFIVariableRecord].self, forKey: .uefiVariables)) ?? nil ?? []
    }

    /// Int を寛容に読む（数値文字列も受け付ける）。
    private static func tolerantInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }

    /// Bool を寛容に読む（"true" / "false" 文字列も受け付ける）。
    private static func tolerantBool(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let value = (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
            if text == "true" { return true }
            if text == "false" { return false }
        }
        return nil
    }

    /// 文字列 enum を寛容に読む（未知の値は nil として扱い、既定値へ倒す）。
    private static func tolerantEnum<T: RawRepresentable>(_ type: T.Type, _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? where T.RawValue == String {
        guard let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        return T(rawValue: raw)
    }

    /// String を寛容に読む（型が合わなければ nil）。
    private static func tolerantString(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case id, name, configuration, state, createdAt, lastStartedAt, errorMessage
    }

    /// 保存データの一部が壊れていても VM 自体は復元できるよう、
    /// フィールドごとに寛容にデコードする（未知の state は停止中へ）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? nil {
            id = decodedID
        } else if let text = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil,
                  let parsed = UUID(uuidString: text) {
            id = parsed
        } else {
            id = UUID()
        }
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? "VM"
        configuration = (try? container.decodeIfPresent(VMConfiguration.self, forKey: .configuration)) ?? nil ?? VMConfiguration()
        if let raw = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil,
           let parsed = VMState(rawValue: raw) {
            state = parsed
        } else {
            state = .stopped
        }
        if let decodedDate = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil {
            createdAt = decodedDate
        } else if let seconds = (try? container.decodeIfPresent(Double.self, forKey: .createdAt)) ?? nil {
            createdAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            createdAt = Date()
        }
        lastStartedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastStartedAt)) ?? nil
        errorMessage = (try? container.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastStartedAt, forKey: .lastStartedAt)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

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
