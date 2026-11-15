import SwiftUI

/// ルート画面。画面幅に応じてレイアウトを切り替える（HIG: Adaptivity）。
///
/// - 横幅が広い環境（iPad など）: `NavigationSplitView` でサイドバー＋詳細表示
/// - 横幅が狭い環境（iPhone）: `TabView` ＋ `NavigationStack` で片手操作に配慮
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: VMStore
    @State private var selectedID: VirtualMachine.ID?

    var body: some View {
        if horizontalSizeClass == .regular {
            splitView
        } else {
            tabView
        }
    }

    // MARK: - iPad など（スプリットビュー）

    private var splitView: some View {
        NavigationSplitView {
            VMListView(selection: $selectedID)
        } detail: {
            if let selectedID, let vm = store.machine(id: selectedID) {
                VMDetailView(vm: vm)
                    .id(vm.id)
            } else {
                ContentUnavailableView(
                    "仮想マシンが選択されていません",
                    systemImage: "desktopcomputer",
                    description: Text("左の一覧から仮想マシンを選ぶか、新しく作成してください。")
                )
            }
        }
    }

    // MARK: - iPhone（タブバー）

    private var tabView: some View {
        TabView {
            NavigationStack {
                VMListView(selection: $selectedID)
                    .navigationDestination(for: VirtualMachine.ID.self) { id in
                        if let vm = store.machine(id: id) {
                            VMDetailView(vm: vm)
                        }
                    }
            }
            .tabItem {
                Label("仮想マシン", systemImage: "desktopcomputer")
            }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
    }
}
