import SwiftUI

/// 設定・情報画面（iPhone のタブバーから表示）。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("retasuVM について") {
                    LabeledContent("バージョン", value: "0.7.0")
                    LabeledContent("対応 OS", value: "iOS 17 / iPadOS 17 以降")
                    LabeledContent("RISC-V", value: "RV32IM（メモリ 1 MiB）")
                    LabeledContent("x86", value: "リアルモード + プロテクトモード（32 ビット）")
                    LabeledContent("ARM", value: "ARMv7-A サブセット（メモリ 4 MiB）")
                    LabeledContent("ISO 起動", value: "BOOT.BIN 形式 / El Torito 対応")
                    LabeledContent("カーネル起動", value: "Multiboot（ELF32）対応")
                    LabeledContent("周辺デバイス", value: "PIC / PIT / PCI / IDE / キーボード / RTC")
                    Text("retasuVM は、iPhone と iPad で仮想マシンを管理するためのアプリです。実行エンジンはすべて自作のソフトウェアエミュレータ（RISC-V / x86 / ARM）で、ゲストが実際に動作します。x86 は 32 ビット プロテクトモードと Multiboot カーネル起動に加え、割り込みコントローラ・タイマ・PCI・IDE ディスクなどの PC 周辺デバイスを再現しました。iOS ではハードウェア仮想化が使えないため、Windows や現在の Linux のような一般の OS は実行できません。")
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
