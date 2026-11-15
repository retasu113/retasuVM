import SwiftUI

/// 仮想マシンの一覧。
///
/// 標準の `List` を使い、スワイプアクションとツールバーを備える。
/// 選択はスプリットビュー（iPad）とスタック遷移（iPhone）の両方に対応する。
struct VMListView: View {
    @EnvironmentObject private var store: VMStore
    @Binding var selection: VirtualMachine.ID?
    @State private var showingEditor = false
    @State private var searchText = ""

    private var filteredMachines: [VirtualMachine] {
        if searchText.isEmpty { return store.machines }
        return store.machines.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if store.machines.isEmpty {
                ContentUnavailableView {
                    Label("仮想マシンがありません", systemImage: "desktopcomputer")
                } description: {
                    Text("右上の＋ボタンから、最初の仮想マシンを作成してください。")
                }
            } else {
                list
            }
        }
        .navigationTitle("retasuVM")
        .searchable(text: $searchText, prompt: "仮想マシンを検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditor = true
                } label: {
                    Label("仮想マシンを追加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            VMEditorView(editing: nil)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filteredMachines) { vm in
                rowLink(for: vm)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if vm.state == .stopped || vm.state == .error {
                            Button {
                                store.start(vm)
                            } label: {
                                Label("起動", systemImage: "play.fill")
                            }
                            .tint(.green)
                        } else {
                            Button {
                                store.stop(vm)
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .tint(.red)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .animation(.default, value: store.machines)
    }

    @ViewBuilder
    private func rowLink(for vm: VirtualMachine) -> some View {
        if usesSplitSelection {
            VMRowView(vm: vm)
                .tag(vm.id)
        } else {
            NavigationLink(value: vm.id) {
                VMRowView(vm: vm)
            }
            .tag(vm.id)
        }
    }

    /// スプリットビューでは選択ベース、iPhone では NavigationLink ベースで遷移する。
    private var usesSplitSelection: Bool {
        horizontalSizeClassIsRegular
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClassIsRegularEnv
    private var horizontalSizeClassIsRegular: Bool { horizontalSizeClassIsRegularEnv == .regular }
}

/// 一覧の 1 行分。名前・構成サマリ・状態バッジを表示する。
struct VMRowView: View {
    let vm: VirtualMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.configuration.bootSystemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(vm.configuration.architecture.label) / \(vm.configuration.summary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VMStatusBadge(state: vm.state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vm.name)、\(vm.configuration.architecture.label)、\(vm.configuration.bootTargetName)、\(vm.configuration.summary)、状態は\(vm.state.label)")
    }
}
