import SwiftUI

/// 設定・情報画面（iPhone のタブバーから表示）。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("retasuVM について") {
                    LabeledContent("バージョン", value: "0.12.0")
                    LabeledContent("対応 OS", value: "iOS 17 / iPadOS 17 以降")
                    LabeledContent("RISC-V", value: "RV32IM（メモリ 1 MiB）")
                    LabeledContent("x86", value: "リアル / プロテクト / ロングモード（64 ビット）")
                    LabeledContent("ARM", value: "ARMv7-A サブセット（メモリ 4 MiB）")
                    LabeledContent("ISO 起動", value: "BOOT.BIN 形式 / El Torito 対応")
                    LabeledContent("カーネル起動", value: "Multiboot（ELF32）対応")
                    LabeledContent("特権レベル", value: "リング 0〜3（TSS タスクスイッチ / SYSCALL・SYSRET / SWAPGS）")
                    LabeledContent("浮動小数点", value: "x87 FPU / MMX / SSE / SSE2 / SSE3 / SSSE3 / SSE4.1（FXSAVE・FXRSTOR・XSAVE）")
                    LabeledContent("UEFI", value: "ConIn / Loaded Image / LoadImage（デバイスパス対応）/ GOP（3 モード）/ イベント通知・グループ / ドライバ接続 / Block I/O / FAT（LFN 書込）/ 変数（永続化）/ Secure Boot（イメージハッシュ方式）/ メモリアロケータ / SetVirtualAddressMap")
                    LabeledContent("周辺デバイス", value: "PIC / APIC / PIT / PCI / IDE（DMA 対応）/ キーボード / RTC / VGA（モード 13h）")
                    LabeledContent("ACPI", value: "RSDP / XSDT / FADT / DSDT / MADT")
                    Text("retasuVM は、iPhone と iPad で仮想マシンを管理するためのアプリです。実行エンジンはすべて自作のソフトウェアエミュレータ（RISC-V / x86 / ARM）で、ゲストが実際に動作します。x86 は 64 ビット ロングモード、特権リング（リング 3 + SYSCALL / SYSRET）、LAPIC / IOAPIC、ACPI テーブル、UEFI ファームウェア（プロトコルデータベース、Loaded Image、LoadImage / StartImage、ConIn、イベント通知関数の呼び出し、ドライババインディング、GOP、本物のメモリアロケータ、Secure Boot（イメージハッシュ方式）、SetVirtualAddressMap、Block I/O、FAT ファイルシステム、永続化される変数サービス）まで備えました。ただし証明書方式の Secure Boot や TPM などは未提供のため、Windows や現在の Linux のような一般の OS はまだ実行できません。")
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
