import SwiftUI

/// retasuVM のエントリポイント。
///
/// Apple Human Interface Guidelines に沿い、標準の SwiftUI コンポーネントで
/// 画面を構成する。状態管理は `VMStore` に集約し、環境オブジェクトとして
/// 全画面へ渡す。
@main
struct RetasuVMApp: App {
    @StateObject private var store = VMStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
