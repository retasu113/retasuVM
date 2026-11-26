import Foundation

/// 起動できるゲスト OS のイメージ。
///
/// どの VM も同じ RISC-V エミュレータで動くが、起動時に読み込む
/// ゲストプログラム（イメージ）を選べる。
enum GuestImage: String, Codable, CaseIterable, Identifiable {
    case retasuOS
    case playOS
    case calcOS

    var id: String { rawValue }

    /// 表示名
    var displayName: String {
        switch self {
        case .retasuOS: return "retasuOS"
        case .playOS: return "PlayOS"
        case .calcOS: return "CalcOS"
        }
    }

    /// イメージの説明
    var detail: String {
        switch self {
        case .retasuOS: return "対話型モニタ（help / echo / fib など）"
        case .playOS: return "数当てゲームとサイコロ"
        case .calcOS: return "スタック式（RPN）計算機"
        }
    }

    /// SF Symbol 名
    var systemImage: String {
        switch self {
        case .retasuOS: return "terminal"
        case .playOS: return "gamecontroller"
        case .calcOS: return "plus.forwardslash.minus"
        }
    }

    /// アセンブル対象のゲストソース
    var assemblySource: String {
        switch self {
        case .retasuOS: return RetasuOS.source
        case .playOS: return PlayOS.source
        case .calcOS: return CalcOS.source
        }
    }

    /// コンソールのクイックコマンド
    var quickCommands: [String] {
        switch self {
        case .retasuOS: return ["help", "fib 10", "about", "clear"]
        case .playOS: return ["help", "guess", "dice"]
        case .calcOS: return ["help", "3 4 + p", "clear"]
        }
    }
}
