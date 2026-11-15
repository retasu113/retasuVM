import SwiftUI
import UniformTypeIdentifiers

/// 仮想マシンの新規作成・編集フォーム。
///
/// 標準の `Form` を使い、キーボード表示時もレイアウトが崩れない構成にする。
/// 名前が空の場合は保存できないようバリデーションする。
/// 起動方法は「ゲストイメージ」と「ISO ファイル」から選べる。
struct VMEditorView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    /// 編集対象。nil の場合は新規作成。
    let editing: VirtualMachine?

    @State private var name: String
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

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if useISO && isoFileName == nil { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $name)
                        .textInputAutocapitalization(.never)
                    Picker("起動方法", selection: $useISO) {
                        Text("ゲストイメージ").tag(false)
                        Text("ISO ファイル").tag(true)
                    }
                    if useISO {
                        LabeledContent("ISO", value: isoDisplayName ?? "未選択")
                        Button {
                            showingISOImporter = true
                        } label: {
                            Label("ISO ファイルを選ぶ", systemImage: "opticaldisc")
                        }
                    } else {
                        Picker("ゲストイメージ", selection: $guestImage) {
                            ForEach(GuestImage.allCases) { image in
                                Label(image.displayName, systemImage: image.systemImage)
                                    .tag(image)
                            }
                        }
                    }
                } header: {
                    Text("基本情報")
                } footer: {
                    if useISO {
                        Text("ISO 9660 イメージのルート直下にある BOOT.BIN（RISC-V フラットバイナリ）を起動します。試作用のサンプル ISO は GitHub Releases から入手できます。")
                    } else {
                        Text("ゲストイメージは、起動時にエミュレータへ読み込む OS です。\(guestImage.displayName): \(guestImage.detail)")
                    }
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
                        Label(
                            useISO && isoFileName == nil && !name.isEmpty
                                ? "ISO ファイルを選んでください"
                                : "名前を入力してください",
                            systemImage: "exclamationmark.circle"
                        )
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingISOImporter,
                allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, .data]
            ) { result in
                handleISOImport(result)
            }
            .alert("ISO を読み込めませんでした", isPresented: $showingImportError) {
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
                isoFileName = try store.importISO(from: url)
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
        let configuration = VMConfiguration(
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            diskGB: diskGB,
            guestOS: editing?.configuration.guestOS ?? .linux,
            guestImage: guestImage,
            useISO: useISO,
            isoFileName: useISO ? isoFileName : editing?.configuration.isoFileName,
            isoDisplayName: useISO ? isoDisplayName : editing?.configuration.isoDisplayName,
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
