import SwiftUI
import UniformTypeIdentifiers

/// 仮想マシンの新規作成・編集フォーム。
///
/// 標準の `Form` を使い、キーボード表示時もレイアウトが崩れない構成にする。
/// 名前が空の場合は保存できないようバリデーションする。
/// CPU アーキテクチャを選び、RISC-V では起動方法（ゲストイメージ / ISO）、
/// x86 では BIOS ブート用イメージ、ARM では固定のデモゲストになる。
struct VMEditorView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    /// 編集対象。nil の場合は新規作成。
    let editing: VirtualMachine?

    @State private var name: String
    @State private var architecture: CPUArchitecture
    @State private var guestImage: GuestImage
    @State private var useISO: Bool
    @State private var isoFileName: String?
    @State private var isoDisplayName: String?
    @State private var cpuCount: Int
    @State private var memoryMB: Int
    @State private var diskGB: Int
    @State private var networkEnabled: Bool
    @State private var sharedFolderEnabled: Bool

    @State private var showingISOImporter = false
    @State private var importError: String?
    @State private var showingImportError = false

    init(editing: VirtualMachine?) {
        self.editing = editing
        let config = editing?.configuration ?? VMConfiguration()
        _name = State(initialValue: editing?.name ?? "")
        _architecture = State(initialValue: config.architecture)
        _guestImage = State(initialValue: config.guestImage)
        _useISO = State(initialValue: config.useISO)
        _isoFileName = State(initialValue: config.isoFileName)
        _isoDisplayName = State(initialValue: config.isoDisplayName)
        _cpuCount = State(initialValue: config.cpuCount)
        _memoryMB = State(initialValue: config.memoryMB)
        _diskGB = State(initialValue: config.diskGB)
        _networkEnabled = State(initialValue: config.networkEnabled)
        _sharedFolderEnabled = State(initialValue: config.sharedFolderEnabled)
    }

    /// ISO / イメージファイルが必須かどうか（RISC-V の ISO 起動と x86）
    private var needsImageFile: Bool {
        architecture == .x86 || (architecture == .riscv && useISO)
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if needsImageFile && isoFileName == nil { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $name)
                        .textInputAutocapitalization(.never)
                    Picker("CPU アーキテクチャ", selection: $architecture) {
                        ForEach(CPUArchitecture.allCases) { architecture in
                            Label(architecture.label, systemImage: architecture.systemImage)
                                .tag(architecture)
                        }
                    }
                    switch architecture {
                    case .riscv:
                        Picker("起動方法", selection: $useISO) {
                            Text("ゲストイメージ").tag(false)
                            Text("ISO ファイル").tag(true)
                        }
                        if useISO {
                            isoPickerRows(buttonTitle: "ISO ファイルを選ぶ")
                        } else {
                            Picker("ゲストイメージ", selection: $guestImage) {
                                ForEach(GuestImage.allCases) { image in
                                    Label(image.displayName, systemImage: image.systemImage)
                                        .tag(image)
                                }
                            }
                        }
                    case .x86:
                        isoPickerRows(buttonTitle: "ISO / イメージファイルを選ぶ")
                    case .arm:
                        LabeledContent("ゲスト", value: "ArmDemoOS")
                    }
                } header: {
                    Text("基本情報")
                } footer: {
                    Text(footerText)
                }

                Section("ハードウェア") {
                    Stepper(value: $cpuCount, in: 1...16) {
                        LabeledContent("CPU", value: "\(cpuCount) コア")
                    }
                    Stepper(value: $memoryMB, in: 1...32768, step: 256) {
                        LabeledContent("メモリ", value: memoryText)
                    }
                    Stepper(value: $diskGB, in: 1...512, step: 1) {
                        LabeledContent("ディスク", value: "\(diskGB) GB")
                    }
                }

                Section("オプション") {
                    Toggle("ネットワーク", isOn: $networkEnabled)
                    Toggle("共有フォルダ", isOn: $sharedFolderEnabled)
                }

                if !isValid {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingISOImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "iso") ?? .data,
                    UTType(filenameExtension: "img") ?? .data,
                    .data,
                ]
            ) { result in
                handleISOImport(result)
            }
            .alert("ファイルを読み込めませんでした", isPresented: $showingImportError) {
                Button("OK") {}
            } message: {
                Text(importError ?? "")
            }
            .navigationTitle(editing == nil ? "仮想マシンを追加" : "仮想マシンを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    /// 選択中イメージの表示とファイル選択ボタン（ISO 起動で共通）。
    @ViewBuilder
    private func isoPickerRows(buttonTitle: String) -> some View {
        LabeledContent("イメージ", value: isoDisplayName ?? "未選択")
        Button {
            showingISOImporter = true
        } label: {
            Label(buttonTitle, systemImage: "opticaldisc")
        }
    }

    private var footerText: String {
        switch architecture {
        case .riscv:
            if useISO {
                return "ISO 9660 イメージのルート直下にある BOOT.BIN（RISC-V フラットバイナリ）を起動します。試作用のサンプル ISO は GitHub Releases から入手できます。"
            }
            return "ゲストイメージは、起動時にエミュレータへ読み込む OS です。\(guestImage.displayName): \(guestImage.detail)"
        case .x86:
            return "内蔵 BIOS が El Torito 対応 ISO（またはブートセクタ付き raw イメージ）からブートセクタを読み込んで実行します。Multiboot 対応カーネル（ELF32 ファイル、または ISO 内の KERNEL.ELF）は 32 ビット プロテクトモードで直接起動します。試作用のサンプルは GitHub Releases から入手できます。"
        case .arm:
            return "ARMv7-A エミュレータ上で、内蔵のデモゲスト「ArmDemoOS」が動きます（fact で 12! の計算、echo、help が使えます）。"
        }
    }

    private var validationMessage: String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "名前を入力してください"
        }
        return "イメージファイルを選んでください"
    }

    private var memoryText: String {
        VMConfiguration(cpuCount: cpuCount, memoryMB: memoryMB, diskGB: diskGB).memoryText
    }

    private func handleISOImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                // 古い ISO の削除は保存時に行う（キャンセル時に元の VM が
                // 参照するファイルを消してしまわないため）
                isoFileName = try store.importISO(from: url, architecture: architecture)
                isoDisplayName = url.lastPathComponent
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUseISO = architecture == .x86 ? true : useISO
        let effectiveISOFileName: String?
        let effectiveISODisplayName: String?
        switch architecture {
        case .riscv:
            effectiveISOFileName = useISO ? isoFileName : editing?.configuration.isoFileName
            effectiveISODisplayName = useISO ? isoDisplayName : editing?.configuration.isoDisplayName
        case .x86:
            effectiveISOFileName = isoFileName
            effectiveISODisplayName = isoDisplayName
        case .arm:
            effectiveISOFileName = editing?.configuration.isoFileName
            effectiveISODisplayName = editing?.configuration.isoDisplayName
        }
        let configuration = VMConfiguration(
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            diskGB: diskGB,
            architecture: architecture,
            guestOS: editing?.configuration.guestOS ?? .linux,
            guestImage: guestImage,
            useISO: effectiveUseISO,
            isoFileName: effectiveISOFileName,
            isoDisplayName: effectiveISODisplayName,
            networkEnabled: networkEnabled,
            sharedFolderEnabled: sharedFolderEnabled
        )
        if let editing {
            store.update(editing, name: trimmedName, configuration: configuration)
            // ISO を差し替えた場合は、元の保存ファイルを片付ける
            if let oldFileName = editing.configuration.isoFileName,
               oldFileName != configuration.isoFileName {
                store.deleteISOFile(named: oldFileName)
            }
        } else {
            store.add(name: trimmedName, configuration: configuration)
        }
        dismiss()
    }
}
