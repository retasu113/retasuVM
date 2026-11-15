import SwiftUI

/// 設定・情報画面（iPhone のタブバーから表示）。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("retasuVM について") {
                    LabeledContent("バージョン", value: "0.1.0")
                    LabeledContent("対応 OS", value: "iOS 17 / iPadOS 17 以降")
                    Text("retasuVM は、iPhone と iPad で仮想マシンを管理するためのアプリです。現在のバージョンの実行エンジンはシミュレーションであり、実際の仮想化は行いません。")
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
