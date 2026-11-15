import SwiftUI

/// 仮想マシンのコンソール画面。
///
/// RISC-V エミュレータ上で動くゲスト OS（retasuOS）の入出力を表示する
/// 対話型ターミナル。コマンドを入力するとゲストが実際に実行する。
/// Reduce Motion が有効な場合はスクロールアニメーションを行わない。
struct VMConsoleView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let vmID: VirtualMachine.ID

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    private var vm: VirtualMachine? {
        store.machine(id: vmID)
    }

    private var isRunning: Bool {
        vm?.state == .running || vm?.state == .paused
    }

    var body: some View {
        VStack(spacing: 0) {
            terminal
            Divider()
            if isRunning {
                quickCommands
                inputBar
            } else {
                stoppedBar
            }
        }
        .navigationTitle("コンソール")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - ターミナル表示

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(store.terminalText(for: vmID).isEmpty
                     ? "（コンソール出力はまだありません）"
                     : store.terminalText(for: vmID))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .id("terminal-bottom")
                    .accessibilityLabel("コンソール出力")
            }
            .background(Color.black)
            .onChange(of: store.terminalText(for: vmID)) { _, _ in
                if reduceMotion {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                } else {
                    withAnimation {
                        proxy.scrollTo("terminal-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - クイックコマンド

    private var quickCommands: some View {
        HStack(spacing: 8) {
            ForEach(vm.map { $0.configuration.useISO ? ["info", "help"] : $0.configuration.guestImage.quickCommands } ?? [], id: \.self) { command in
                Button(command) {
                    send(command + "\n")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - 入力バー

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("コマンドを入力（例: fib 10）", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .onSubmit { submit() }
                .accessibilityLabel("コマンド入力")
            Button {
                submit()
            } label: {
                Label("送信", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputText.isEmpty)
        }
        .padding(12)
    }

    private var stoppedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
            Text("仮想マシンが停止しています。詳細画面から起動すると、ここでゲスト OS を操作できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - 送信

    private func submit() {
        let line = inputText
        inputText = ""
        send(line + "\n")
        inputFocused = true
    }

    private func send(_ text: String) {
        guard let vm else { return }
        store.sendInput(vm, text: text)
    }
}
