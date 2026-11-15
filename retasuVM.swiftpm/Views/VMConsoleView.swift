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

    /// 表示モード（テキストコンソール / グラフィックス・テキスト画面）。
    private enum DisplayMode: String, CaseIterable {
        case console = "コンソール"
        case screen = "画面"
    }

    @State private var displayMode: DisplayMode = .console
    @State private var snapshot: GuestScreenSnapshot?

    private var vm: VirtualMachine? {
        store.machine(id: vmID)
    }

    private var isRunning: Bool {
        vm?.state == .running || vm?.state == .paused
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示モード", selection: $displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if displayMode == .screen {
                screenView
            } else {
                terminal
            }
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
        .task(id: displayMode) {
            // 画面モードの間だけ定期的にスナップショットを更新する（保険のポーリング）
            guard displayMode == .screen else { return }
            while !Task.isCancelled {
                snapshot = store.screenSnapshot(for: vmID)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onChange(of: store.screenRevision(for: vmID)) { _, _ in
            // 画面の変化通知を受けたら即座にスナップショットを取り直す
            if displayMode == .screen {
                snapshot = store.screenSnapshot(for: vmID)
            }
        }
    }

    // MARK: - 画面表示

    private var screenView: some View {
        Group {
            switch snapshot {
            case .framebuffer(let width, let height, let bgra):
                if let image = makeCGImage(width: width, height: height, bgra: bgra) {
                    Image(image, scale: 1.0, label: Text("ゲストの画面"))
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    screenPlaceholder
                }
            case .text(let lines):
                ScrollView([.horizontal, .vertical]) {
                    Text(lines.joined(separator: "\n"))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white)
                        .padding(12)
                        .accessibilityLabel("ゲストのテキスト画面")
                }
            case nil:
                screenPlaceholder
            }
        }
        .background(Color.black)
    }

    private var screenPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("画面はまだありません。x86 の UEFI ゲストでは GOP の画面が、BIOS ゲストではテキスト画面が表示されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// BGRA バイト列から CGImage を作る（GOP フレームバッファ表示用）。
    private func makeCGImage(width: Int, height: Int, bgra: [UInt8]) -> CGImage? {
        guard width > 0, height > 0, bgra.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
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
            ForEach(vm?.configuration.quickCommands ?? [], id: \.self) { command in
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
