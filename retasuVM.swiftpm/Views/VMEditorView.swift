import SwiftUI

/// 仮想マシンの新規作成・編集フォーム。
///
/// 標準の `Form` を使い、キーボード表示時もレイアウトが崩れない構成にする。
/// 名前が空の場合は保存できないようバリデーションする。
struct VMEditorView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    /// 編集対象。nil の場合は新規作成。
    let editing: VirtualMachine?

    @State private var name: String
    @State private var guestOS: GuestOS
    @State private var cpuCount: Int
    @State private var memoryMB: Int
    @State private var diskGB: Int
    @State private var networkEnabled: Bool
    @State private var sharedFolderEnabled: Bool

    init(editing: VirtualMachine?) {
        self.editing = editing
        let config = editing?.configuration ?? VMConfiguration()
        _name = State(initialValue: editing?.name ?? "")
        _guestOS = State(initialValue: config.guestOS)
        _cpuCount = State(initialValue: config.cpuCount)
        _memoryMB = State(initialValue: config.memoryMB)
        _diskGB = State(initialValue: config.diskGB)
        _networkEnabled = State(initialValue: config.networkEnabled)
        _sharedFolderEnabled = State(initialValue: config.sharedFolderEnabled)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本情報") {
                    TextField("名前", text: $name)
                        .textInputAutocapitalization(.never)
                    Picker("ゲスト OS", selection: $guestOS) {
                        ForEach(GuestOS.allCases) { os in
                            Label(os.label, systemImage: os.systemImage)
                                .tag(os)
                        }
                    }
                }

                Section("ハードウェア") {
                    Stepper(value: $cpuCount, in: 1...16) {
                        LabeledContent("CPU", value: "\(cpuCount) コア")
                    }
                    Stepper(value: $memoryMB, in: 512...32768, step: 512) {
                        LabeledContent("メモリ", value: memoryText)
                    }
                    Stepper(value: $diskGB, in: 8...512, step: 8) {
                        LabeledContent("ディスク", value: "\(diskGB) GB")
                    }
                }

                Section("オプション") {
                    Toggle("ネットワーク", isOn: $networkEnabled)
                    Toggle("共有フォルダ", isOn: $sharedFolderEnabled)
                }

                if !isValid {
                    Section {
                        Label("名前を入力してください", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
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

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = VMConfiguration(
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            diskGB: diskGB,
            guestOS: guestOS,
            networkEnabled: networkEnabled,
            sharedFolderEnabled: sharedFolderEnabled
        )
        if let editing {
            store.update(editing, name: trimmedName, configuration: configuration)
        } else {
            store.add(name: trimmedName, configuration: configuration)
        }
        dismiss()
    }
}
