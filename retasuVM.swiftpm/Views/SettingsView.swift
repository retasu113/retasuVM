import SwiftUI

/// 設定・情報画面（iPhone のタブバーから表示）。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("retasuVM について") {
                    LabeledContent("バージョン", value: "0.2.0")
                    LabeledContent("対応 OS", value: "iOS 17 / iPadOS 17 以降")
                    LabeledContent("エミュレータ", value: "RISC-V RV32I（メモリ 1 MiB）")
                    Text("retasuVM は、iPhone と iPad で仮想マシンを管理するためのアプリです。実行エンジンは RISC-V CPU のソフトウェアエミュレータで、ゲスト OS「retasuOS」が実際に動作します。iOS ではハードウェア仮想化が使えないため、Linux や Windows のような一般の OS は実行できません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("デザイン") {
                    Text("Apple Human Interface Guidelines に沿って設計しています。ダークモード、Dynamic Type、VoiceOver、Reduce Motion に対応します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("リンク") {
                    Link(destination: URL(string: "https://github.com/retasu113/retasuVM")!) {
                        Label("GitHub リポジトリ", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://developer.apple.com/design/human-interface-guidelines/")!) {
                        Label("Human Interface Guidelines（Apple）", systemImage: "book")
                    }
                }
            }
            .navigationTitle("設定")
        }
    }
}
