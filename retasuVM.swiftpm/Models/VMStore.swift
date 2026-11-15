import Foundation

/// 管理イベントのログ 1 行分（詳細画面の「最近の記録」用）。
struct ConsoleLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
}

/// 仮想マシン一覧と実行セッションを管理するストア。
///
/// - 一覧は JSON としてアプリのドキュメントフォルダに保存し、再起動後も保持する。
/// - 起動すると `EmulatorSession` が RISC-V エミュレータ上でゲスト OS
///   （retasuOS）を実際に走らせる。コンソール入出力はセッション経由。
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var consoleLogs: [UUID: [ConsoleLine]] = [:]
    /// コンソール（ターミナル）の表示内容。ゲストの出力がそのまま流れる。
    @Published private(set) var consoleText: [UUID: String] = [:]
    @Published private(set) var transitioning: Set<UUID> = []

    private var sessions: [UUID: EmulatorSession] = [:]
    private let fileURL: URL?

    init() {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.fileURL = documents.appendingPathComponent("virtual-machines.json")
        } else {
            self.fileURL = nil
        }
        load()
    }

    // MARK: - 取得

    func machine(id: UUID) -> VirtualMachine? {
        machines.first { $0.id == id }
    }

    func log(for id: UUID) -> [ConsoleLine] {
        consoleLogs[id] ?? []
    }

    func terminalText(for id: UUID) -> String {
        consoleText[id] ?? ""
    }

    func isTransitioning(_ vm: VirtualMachine) -> Bool {
        transitioning.contains(vm.id)
    }

    // MARK: - 作成・編集・削除

    func add(name: String, configuration: VMConfiguration) {
        let vm = VirtualMachine(name: name, configuration: configuration)
        machines.append(vm)
        appendLog(for: vm.id, lines: ["[retasuVM] \(name) を作成しました"])
        save()
    }

    func update(_ vm: VirtualMachine, name: String, configuration: VMConfiguration) {
        guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }
        machines[index].name = name
        machines[index].configuration = configuration
        save()
    }

    func delete(_ vm: VirtualMachine) {
        sessions[vm.id]?.terminate()
        sessions[vm.id] = nil
        machines.removeAll { $0.id == vm.id }
        consoleLogs[vm.id] = nil
        consoleText[vm.id] = nil
        save()
    }

    // MARK: - 状態遷移

    /// 起動: エミュレータセッションを作り、ゲスト OS をブートする。
    func start(_ vm: VirtualMachine) {
        guard vm.state == .stopped || vm.state == .error else { return }
        guard sessions[vm.id] == nil else { return }
        guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }

        consoleText[vm.id] = ""
        let session = EmulatorSession()
        let vmID = vm.id
        session.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.consoleText[vmID, default: ""] += text
            }
        }
        session.onClear = { [weak self] in
            Task { @MainActor [weak self] in
                self?.consoleText[vmID] = ""
            }
        }
        session.onHalt = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.handleGuestHalt(vmID: vmID, exitCode: exitCode)
            }
        }
        session.onFault = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleGuestFault(vmID: vmID, message: message)
            }
        }

        do {
            try session.boot()
        } catch {
            machines[index].state = .error
            machines[index].errorMessage = error.localizedDescription
            appendLog(for: vm.id, lines: ["[retasuVM] 起動に失敗しました: \(error.localizedDescription)"])
            save()
            return
        }

        sessions[vm.id] = session
        machines[index].state = .running
        machines[index].errorMessage = nil
        machines[index].lastStartedAt = Date()
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を起動しました（retasuOS ブート）"])
        save()
    }

    /// 停止: セッションを終了する（電源断）。
    func stop(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        endSession(vmID: vm.id)
        setState(vmID: vm.id, .stopped)
        consoleText[vm.id, default: ""] += "\n[retasuVM] 停止しました\n"
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を停止しました"])
        save()
    }

    /// 一時停止: CPU の実行を止める（メモリ内容は保持される）。
    func pause(_ vm: VirtualMachine) {
        guard vm.state == .running, let session = sessions[vm.id] else { return }
        session.setPaused(true)
        setState(vmID: vm.id, .paused)
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を一時停止しました"])
        save()
    }

    func resume(_ vm: VirtualMachine) {
        guard vm.state == .paused, let session = sessions[vm.id] else { return }
        session.setPaused(false)
        setState(vmID: vm.id, .running)
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を再開しました"])
        save()
    }

    /// 再起動: セッションを作り直してブートし直す。
    func restart(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        endSession(vmID: vm.id)
        setState(vmID: vm.id, .stopped)
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を再起動します"])
        if let fresh = machine(id: vm.id) {
            start(fresh)
        }
    }

    /// 強制停止。実行中・一時停止中どちらからでも停止状態へ移す。
    func forceStop(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        endSession(vmID: vm.id)
        setState(vmID: vm.id, .stopped)
        consoleText[vm.id, default: ""] += "\n[retasuVM] 強制停止しました\n"
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を強制停止しました"])
        save()
    }

    // MARK: - コンソール入力

    /// コンソールからの入力をゲストへ送る。
    func sendInput(_ vm: VirtualMachine, text: String) {
        sessions[vm.id]?.sendInput(text)
    }

    // MARK: - セッション終了イベント

    private func handleGuestHalt(vmID: UUID, exitCode: Int32) {
        guard sessions[vmID] != nil else { return }
        sessions[vmID] = nil
        setState(vmID: vmID, .stopped)
        consoleText[vmID, default: ""] += "\n[retasuVM] ゲスト OS が終了しました（終了コード \(exitCode)）\n"
        if let vm = machine(id: vmID) {
            appendLog(for: vmID, lines: ["[retasuVM] \(vm.name) のゲスト OS が終了しました（終了コード \(exitCode)）"])
        }
        save()
    }

    private func handleGuestFault(vmID: UUID, message: String) {
        guard sessions[vmID] != nil else { return }
        sessions[vmID] = nil
        if let index = machines.firstIndex(where: { $0.id == vmID }) {
            machines[index].state = .error
            machines[index].errorMessage = message
        }
        consoleText[vmID, default: ""] += "\n[retasuVM] エラーで停止しました: \(message)\n"
        appendLog(for: vmID, lines: ["[retasuVM] エラー: \(message)"])
        save()
    }

    private func endSession(vmID: UUID) {
        sessions[vmID]?.terminate()
        sessions[vmID] = nil
    }

    private func setState(vmID: UUID, _ state: VMState) {
        guard let index = machines.firstIndex(where: { $0.id == vmID }) else { return }
        machines[index].state = state
        if state != .error {
            machines[index].errorMessage = nil
        }
    }

    // MARK: - ログ

    private func appendLog(for id: UUID, lines: [String]) {
        var log = consoleLogs[id] ?? []
        let now = Date()
        log += lines.map { ConsoleLine(date: now, text: $0) }
        consoleLogs[id] = log
    }

    // MARK: - 永続化

    private func load() {
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VirtualMachine].self, from: data) {
            // 前回終了時に実行中だった VM は、再起動後は停止中として扱う。
            machines = decoded.map { vm in
                var vm = vm
                if vm.state == .running || vm.state == .paused {
                    vm.state = .stopped
                }
                return vm
            }
            return
        }
        machines = Self.sampleData
    }

    private func save() {
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(machines) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// 初回起動時に表示するサンプルデータ。
    static var sampleData: [VirtualMachine] {
        [
            VirtualMachine(
                name: "retasuOS ゲスト",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 1,
                    diskGB: 1,
                    guestOS: .linux,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            ),
            VirtualMachine(
                name: "テスト用 VM",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 1,
                    diskGB: 1,
                    guestOS: .other,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            )
        ]
    }
}
