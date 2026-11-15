import Foundation

/// コンソールに表示するログ 1 行分。
struct ConsoleLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
}

/// 仮想マシン一覧と状態遷移を管理するストア。
///
/// - 一覧は JSON としてアプリのドキュメントフォルダに保存し、再起動後も保持する。
/// - 状態遷移は `VMEngine` を通して行い、結果をコンソールログへ追記する。
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var consoleLogs: [UUID: [ConsoleLine]] = [:]
    @Published private(set) var transitioning: Set<UUID> = []

    private let engine: VMEngine
    private let fileURL: URL?

    init(engine: VMEngine = SimulatedVMEngine()) {
        self.engine = engine
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
        machines.removeAll { $0.id == vm.id }
        consoleLogs[vm.id] = nil
        save()
    }

    // MARK: - 状態遷移

    func start(_ vm: VirtualMachine) {
        guard vm.state == .stopped || vm.state == .error else { return }
        perform(vm, busy: true) { engine in
            let lines = try await engine.start(vm)
            return (lines, .running)
        }
    }

    func stop(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        perform(vm, busy: true) { engine in
            let lines = try await engine.stop(vm)
            return (lines, .stopped)
        }
    }

    func pause(_ vm: VirtualMachine) {
        guard vm.state == .running else { return }
        perform(vm, busy: true) { engine in
            let lines = try await engine.pause(vm)
            return (lines, .paused)
        }
    }

    func resume(_ vm: VirtualMachine) {
        guard vm.state == .paused else { return }
        perform(vm, busy: true) { engine in
            let lines = try await engine.resume(vm)
            return (lines, .running)
        }
    }

    func restart(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        perform(vm, busy: true) { engine in
            var lines = try await engine.stop(vm)
            lines += try await engine.start(vm)
            return (lines, .running)
        }
    }

    /// 強制停止。実行中・一時停止中どちらからでも停止状態へ移す。
    func forceStop(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        perform(vm, busy: true) { _ in
            (["[retasuVM] \(vm.name) を強制停止しました"], .stopped)
        }
    }

    private func perform(
        _ vm: VirtualMachine,
        busy: Bool,
        action: @escaping (VMEngine) async throws -> (lines: [String], state: VMState)
    ) {
        guard !transitioning.contains(vm.id) else { return }
        transitioning.insert(vm.id)
        let engine = self.engine
        Task {
            defer { transitioning.remove(vm.id) }
            do {
                let result = try await action(engine)
                guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }
                machines[index].state = result.state
                machines[index].errorMessage = nil
                if result.state == .running {
                    machines[index].lastStartedAt = Date()
                }
                appendLog(for: vm.id, lines: result.lines)
                save()
            } catch {
                guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }
                machines[index].state = .error
                machines[index].errorMessage = error.localizedDescription
                appendLog(for: vm.id, lines: ["[retasuVM] エラー: \(error.localizedDescription)"])
                save()
            }
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
                name: "Ubuntu テスト環境",
                configuration: VMConfiguration(
                    cpuCount: 2,
                    memoryMB: 4096,
                    diskGB: 32,
                    guestOS: .linux,
                    networkEnabled: true,
                    sharedFolderEnabled: true
                )
            ),
            VirtualMachine(
                name: "軽量 Linux",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 2048,
                    diskGB: 16,
                    guestOS: .linux,
                    networkEnabled: true,
                    sharedFolderEnabled: false
                )
            )
        ]
    }
}
