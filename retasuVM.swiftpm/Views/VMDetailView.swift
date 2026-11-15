import SwiftUI

/// 仮想マシンの詳細画面。
///
/// - 現在の状態をバッジと文章で明示する（色だけに頼らない）
/// - 起動・停止などの操作は、内容が分かるラベル付きボタンで提供する
/// - 削除・強制停止のような破壊的操作には確認ダイアログを挟む
struct VMDetailView: View {
    @EnvironmentObject private var store: VMStore
    let vmID: VirtualMachine.ID

    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingForceStopConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(vm: VirtualMachine) {
        self.vmID = vm.id
    }

    private var vm: VirtualMachine? {
        store.machine(id: vmID)
    }

    var body: some View {
        Group {
            if let vm {
                content(for: vm)
            } else {
                ContentUnavailableView(
                    "仮想マシンが見つかりません",
                    systemImage: "questionmark.folder",
                    description: Text("削除された可能性があります。一覧に戻ってください。")
                )
            }
        }
    }

    private func content(for vm: VirtualMachine) -> some View {
        List {
            headerSection(for: vm)
            actionsSection(for: vm)
            configurationSection(for: vm)
            consoleSection(for: vm)
            dangerSection(for: vm)
        }
        .navigationTitle(vm.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("編集") { showingEditor = true }
                    .disabled(vm.state == .running || vm.state == .paused || store.isTransitioning(vm))
            }
        }
        .sheet(isPresented: $showingEditor) {
            VMEditorView(editing: vm)
        }
        .confirmationDialog(
            "「\(vm.name)」を削除しますか？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                store.delete(vm)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。仮想マシンの設定が完全に削除されます。")
        }
        .confirmationDialog(
            "「\(vm.name)」を強制停止しますか？",
            isPresented: $showingForceStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("強制停止", role: .destructive) {
                store.forceStop(vm)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存されていない作業は失われる可能性があります。通常の停止が効かない場合にだけ使ってください。")
        }
    }

    // MARK: - セクション

    private func headerSection(for vm: VirtualMachine) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: vm.configuration.bootSystemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.name)
                            .font(.title3.weight(.semibold))
                        Text("\(vm.configuration.architecture.label) / \(vm.configuration.bootTargetName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VMStatusBadge(state: vm.state)
                }

                if store.isTransitioning(vm) {
                    ProgressView("処理中…")
                        .accessibilityLabel("処理中です")
                }

                if vm.state == .error, let message = vm.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if let lastStartedAt = vm.lastStartedAt {
                    Text("最終起動: \(lastStartedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func actionsSection(for vm: VirtualMachine) -> some View {
        Section("操作") {
            let busy = store.isTransitioning(vm)
            switch vm.state {
            case .stopped, .error:
                Button {
                    store.start(vm)
                } label: {
                    Label("起動", systemImage: "play.fill")
                }
                .disabled(busy)
            case .running:
                Button {
                    store.pause(vm)
                } label: {
                    Label("一時停止", systemImage: "pause.fill")
                }
                .disabled(busy)

                Button {
                    store.restart(vm)
                } label: {
                    Label("再起動", systemImage: "arrow.clockwise")
                }
                .disabled(busy)

                Button {
                    store.stop(vm)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(busy)
            case .paused:
                Button {
                    store.resume(vm)
                } label: {
                    Label("再開", systemImage: "play.fill")
                }
                .disabled(busy)

                Button {
                    store.stop(vm)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(busy)
            }
        }
    }

    private func configurationSection(for vm: VirtualMachine) -> some View {
        Section("構成") {
            LabeledContent("CPU アーキテクチャ", value: "\(vm.configuration.architecture.label)（\(vm.configuration.architecture.detail)）")
            switch vm.configuration.architecture {
            case .riscv:
                if let sample = vm.configuration.builtInSample {
                    LabeledContent("起動方法", value: "内蔵サンプル")
                    LabeledContent("サンプル", value: sample.displayName)
                } else {
                    LabeledContent("起動方法", value: vm.configuration.useISO ? "ISO ファイル" : "ゲストイメージ")
                    if vm.configuration.useISO {
                        LabeledContent("ISO", value: vm.configuration.isoDisplayName ?? "未選択")
                    } else {
                        LabeledContent("ゲストイメージ", value: vm.configuration.guestImage.displayName)
                    }
                }
            case .x86:
                if let sample = vm.configuration.builtInSample {
                    LabeledContent("起動方法", value: "内蔵サンプル")
                    LabeledContent("サンプル", value: sample.displayName)
                } else {
                    LabeledContent("起動方法", value: "BIOS / Multiboot（ISO・イメージ・ELF）")
                    LabeledContent("イメージ", value: vm.configuration.isoDisplayName ?? "未選択")
                }
            case .arm:
                LabeledContent("ゲスト", value: "ArmDemoOS")
            case .arm64:
                LabeledContent("ゲスト", value: "Arm64DemoOS")
            }
            LabeledContent("CPU", value: "\(vm.configuration.cpuCount) コア")
            LabeledContent("メモリ", value: vm.configuration.memoryText)
            LabeledContent("ディスク", value: "\(vm.configuration.diskGB) GB")
            LabeledContent("ネットワーク", value: vm.configuration.networkEnabled ? "有効" : "無効")
            LabeledContent("共有フォルダ", value: vm.configuration.sharedFolderEnabled ? "有効" : "無効")
            LabeledContent("作成日", value: vm.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private func consoleSection(for vm: VirtualMachine) -> some View {
        Section("コンソール") {
            NavigationLink {
                VMConsoleView(vmID: vm.id)
            } label: {
                Label("コンソールを開く", systemImage: "terminal")
            }
            let tail = store.terminalText(for: vm.id)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(4)
            if tail.isEmpty {
                Text("コンソール出力はまだありません。起動するとゲスト OS（\(vm.configuration.bootTargetName)）を操作できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func dangerSection(for vm: VirtualMachine) -> some View {
        Section {
            if vm.state == .running || vm.state == .paused {
                Button(role: .destructive) {
                    showingForceStopConfirmation = true
                } label: {
                    Label("強制停止", systemImage: "exclamationmark.octagon")
                }
                .disabled(store.isTransitioning(vm))
            }
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("この仮想マシンを削除", systemImage: "trash")
            }
            .disabled(vm.state == .running || store.isTransitioning(vm))
        } footer: {
            Text("実行中の仮想マシンは削除できません。先に停止してください。")
        }
    }
}
