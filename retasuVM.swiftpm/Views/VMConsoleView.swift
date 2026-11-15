import SwiftUI

/// 仮想マシンのコンソール画面。
///
/// ゲスト画面のプレースホルダと、操作ログを表示する。
/// Reduce Motion が有効な場合はカーソルの点滅アニメーションを行わない。
struct VMConsoleView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let vmID: VirtualMachine.ID

    private var vm: VirtualMachine? {
        store.machine(id: vmID)
    }

    var body: some View {
        VStack(spacing: 0) {
            guestScreen
            Divider()
            logList
        }
        .navigationTitle("コンソール")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - ゲスト画面（プレースホルダ）

    private var guestScreen: some View {
        ZStack {
            Color.black
            if let vm {
                VStack(spacing: 10) {
                    Image(systemName: vm.state.systemImage)
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(vm.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(vm.state.label)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                    if vm.state == .running {
                        Text("ゲスト画面はシミュレーションです。実際の画面描画は今後の実装で対応します。")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(vm.name)、状態は\(vm.state.label)")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
    }

    // MARK: - ログ

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let lines = store.log(for: vmID)
                    if lines.isEmpty {
                        Text("ログはまだありません。仮想マシンを起動すると、ここに記録されます。")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.date.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                            Text(line.text)
                        }
                        .font(.footnote.monospaced())
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(.secondarySystemBackground))
            .onChange(of: store.log(for: vmID).count) { _, _ in
                guard let last = store.log(for: vmID).last else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
