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
/// - 起動するとアーキテクチャに応じたセッション（RISC-V / x86 / ARM）が
///   自作エミュレータ上でゲストを実際に走らせる。コンソール入出力はセッション経由。
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var consoleLogs: [UUID: [ConsoleLine]] = [:]
    /// コンソール（ターミナル）の表示内容。ゲストの出力がそのまま流れる。
    @Published private(set) var consoleText: [UUID: String] = [:]
    @Published private(set) var transitioning: Set<UUID> = []

    private var sessions: [UUID: any GuestSession] = [:]
    /// セッションの世代番号。再起動をまたいだ古いコールバックを弾く。
    private var sessionGenerations: [UUID: Int] = [:]
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

    /// ゲストの画面スナップショット（画面表示用、対応セッションのみ）。
    func screenSnapshot(for id: UUID) -> GuestScreenSnapshot? {
        sessions[id]?.screenSnapshot()
    }

    /// 画面の変化カウンタ（変化通知のたびに増える）。
    @Published private(set) var screenRevisions: [UUID: Int] = [:]

    func screenRevision(for id: UUID) -> Int {
        screenRevisions[id] ?? 0
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
        // 実行中・一時停止中の VM は、稼働中セッションと構成が食い違うため編集しない
        guard machines[index].state == .stopped || machines[index].state == .error else { return }
        machines[index].name = name
        machines[index].configuration = configuration
        save()
    }

    func delete(_ vm: VirtualMachine) {
        sessions[vm.id]?.terminate()
        sessions[vm.id] = nil
        if let isoFileName = vm.configuration.isoFileName {
            deleteISOFile(named: isoFileName)
        }
        machines.removeAll { $0.id == vm.id }
        consoleLogs[vm.id] = nil
        consoleText[vm.id] = nil
        save()
    }

    // MARK: - 状態遷移

    /// セッションのコールバックをストアへ接続する（全アーキテクチャ共通）。
    private func wireCallbacks(session: any GuestSession, vmID: UUID, generation: Int) {
        session.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.consoleText[vmID, default: ""] += text
            }
        }
        session.onScreenChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screenRevisions[vmID, default: 0] += 1
            }
        }
        session.onClear = { [weak self] in
            Task { @MainActor [weak self] in
                self?.consoleText[vmID] = ""
            }
        }
        session.onHalt = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.handleGuestHalt(vmID: vmID, generation: generation, exitCode: exitCode)
            }
        }
        session.onFault = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleGuestFault(vmID: vmID, generation: generation, message: message)
            }
        }
    }

    /// 起動: アーキテクチャに応じたセッションを作り、ゲストをブートする。
    func start(_ vm: VirtualMachine) {
        guard vm.state == .stopped || vm.state == .error else { return }
        guard sessions[vm.id] == nil else { return }
        guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }

        let generation = (sessionGenerations[vm.id] ?? 0) + 1
        sessionGenerations[vm.id] = generation
        transitioning.insert(vm.id)
        consoleText[vm.id] = ""
        let session: any GuestSession
        let bootDescription: String

        switch vm.configuration.architecture {
        case .riscv:
            let emulatorSession = EmulatorSession()
            wireCallbacks(session: emulatorSession, vmID: vm.id, generation: generation)
            if vm.configuration.useISO {
                // ISO ブート: ISO 9660 を解析し、ルート直下の BOOT.BIN を起動する
                // 内蔵サンプルが選ばれている場合はそのデータを使う
                let isoData: [UInt8]?
                if let sample = vm.configuration.builtInSample, sample.architecture == .riscv {
                    isoData = sample.data
                } else {
                    isoData = loadISOData(for: vm)
                }
                guard let isoData else {
                    failStart(index: index, vm: vm, message: "ISO ファイルが見つかりません")
                    return
                }
                let image: ISO9660Image
                do {
                    image = try ISO9660Image(data: isoData)
                } catch {
                    failStart(index: index, vm: vm, message: error.localizedDescription)
                    return
                }
                guard let bootBinary = image.file(named: "BOOT.BIN") else {
                    failStart(index: index, vm: vm, message: "ISO 内に BOOT.BIN がありません（retasuVM 形式の ISO が必要です）")
                    return
                }
                guard bootBinary.count <= 1 << 20 else {
                    failStart(index: index, vm: vm, message: "BOOT.BIN がゲストメモリ（1 MiB）より大きいため起動できません")
                    return
                }
                emulatorSession.boot(program: bootBinary, entry: 0, diskImage: isoData)
                bootDescription = "ISO「\(image.volumeLabel.isEmpty ? (vm.configuration.isoDisplayName ?? "名称なし") : image.volumeLabel)」"
            } else {
                do {
                    try emulatorSession.boot(guestImage: vm.configuration.guestImage)
                } catch {
                    failStart(index: index, vm: vm, message: error.localizedDescription)
                    return
                }
                bootDescription = vm.configuration.guestImage.displayName
            }
            session = emulatorSession
        case .x86:
            // x86 は BIOS ブート: El Torito ISO または raw イメージから起動する
            // 内蔵サンプルが選ばれている場合はそのデータを起動する
            let imageData: [UInt8]?
            let sampleName: String?
            if let sample = vm.configuration.builtInSample, sample.architecture == .x86 {
                imageData = sample.data
                sampleName = sample.displayName
            } else {
                imageData = loadISOData(for: vm)
                sampleName = nil
            }
            guard let imageData else {
                failStart(index: index, vm: vm, message: "ISO / イメージファイルが見つかりません")
                return
            }
            let imageDisplayName = sampleName ?? vm.configuration.isoDisplayName
            let x86Session = X86Session()
            x86Session.initialUEFIVariables = vm.configuration.uefiVariables.map {
                X86UEFI.Variable(guid: $0.guid, name: $0.name,
                                 attributes: $0.attributes, data: $0.data)
            }
            wireCallbacks(session: x86Session, vmID: vm.id, generation: generation)
            do {
                try x86Session.boot(imageData: imageData)
            } catch {
                failStart(index: index, vm: vm, message: error.localizedDescription)
                return
            }
            if Multiboot.isMultibootKernel(imageData) {
                bootDescription = "Multiboot（\(imageDisplayName ?? "カーネル")）"
            } else if X86UEFI.isUEFIApplication(imageData) {
                bootDescription = "UEFI（\(imageDisplayName ?? "アプリケーション")）"
            } else {
                bootDescription = "BIOS（\(imageDisplayName ?? "イメージ")）"
            }
            session = x86Session
        case .arm:
            let armSession = ARMSession()
            wireCallbacks(session: armSession, vmID: vm.id, generation: generation)
            do {
                try armSession.boot(source: ARMDemoOS.source)
            } catch {
                failStart(index: index, vm: vm, message: error.localizedDescription)
                return
            }
            bootDescription = "ArmDemoOS"
            session = armSession
        case .arm64:
            let arm64Session = ARM64Session()
            wireCallbacks(session: arm64Session, vmID: vm.id, generation: generation)
            do {
                try arm64Session.boot(source: ARM64DemoOS.source)
            } catch {
                failStart(index: index, vm: vm, message: error.localizedDescription)
                return
            }
            bootDescription = "Arm64DemoOS"
            session = arm64Session
        }

        sessions[vm.id] = session
        transitioning.remove(vm.id)
        machines[index].state = .running
        machines[index].errorMessage = nil
        machines[index].lastStartedAt = Date()
        appendLog(for: vm.id, lines: ["[retasuVM] \(vm.name) を起動しました（\(bootDescription) ブート）"])
        save()
    }

    private func failStart(index: Int, vm: VirtualMachine, message: String) {
        transitioning.remove(vm.id)
        machines[index].state = .error
        machines[index].errorMessage = message
        consoleText[vm.id, default: ""] += "\n[retasuVM] 起動に失敗しました: \(message)\n"
        appendLog(for: vm.id, lines: ["[retasuVM] 起動に失敗しました: \(message)"])
        save()
    }

    // MARK: - ISO ファイルの管理

    /// ISO の保存先ディレクトリ（ドキュメント/ISOs）。
    private var isoDirectory: URL? {
        guard let fileURL else { return nil }
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("ISOs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 選択された ISO / イメージをアプリ内へコピーし、検証して保存名を返す。
    ///
    /// 検証はアーキテクチャごとに異なる:
    /// - RISC-V: retasuVM 形式（ISO 9660 でルート直下に BOOT.BIN がある）
    /// - x86: El Torito ブート可能な ISO、またはブートセクタ（55 AA）付き raw イメージ
    func importISO(from url: URL, architecture: CPUArchitecture = .riscv) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        switch architecture {
        case .riscv:
            let image = try ISO9660Image(data: bytes)
            guard image.file(named: "BOOT.BIN") != nil else {
                throw ISO9660Error.missingBootBinary
            }
        case .x86:
            if Multiboot.isMultibootKernel(bytes) {
                // Multiboot カーネル（ELF32）はそのまま起動できる
            } else if X86UEFI.isUEFIApplication(bytes) {
                // UEFI アプリケーション（PE32+ / x86-64）はそのまま起動できる
            } else if ElTorito.isISO9660(bytes) {
                if let iso = try? ISO9660Image(data: bytes), let kernel = iso.file(named: "KERNEL.ELF"), Multiboot.isMultibootKernel(kernel) {
                    // ISO 内の Multiboot カーネルを起動できる
                } else {
                    _ = try ElTorito.bootImage(fromISO: bytes)
                }
            } else {
                guard bytes.count >= 512, bytes[510] == 0x55, bytes[511] == 0xAA else {
                    throw X86BootError.notBootable("ブート可能なイメージではありません。El Torito 対応の ISO、ブートセクタ付きの raw イメージ（.img）、Multiboot 対応カーネル（ELF32）、または UEFI アプリケーション（.efi）を選んでください")
                }
            }
        case .arm, .arm64:
            throw X86BootError.notBootable("ARM ではイメージファイルは使いません")
        }
        guard let directory = isoDirectory else {
            throw ISO9660Error.storageUnavailable
        }
        let storedName = UUID().uuidString + ".iso"
        try data.write(to: directory.appendingPathComponent(storedName), options: [.atomic])
        return storedName
    }

    /// 保存済み ISO のデータを読み込む。
    func loadISOData(for vm: VirtualMachine) -> [UInt8]? {
        guard let fileName = vm.configuration.isoFileName,
              let directory = isoDirectory else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            return nil
        }
        return [UInt8](data)
    }

    /// 保存済み ISO を削除する（VM の削除時や差し替え時）。
    func deleteISOFile(named fileName: String) {
        guard let directory = isoDirectory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// 停止: セッションを終了する（電源断）。
    func stop(_ vm: VirtualMachine) {
        guard vm.state == .running || vm.state == .paused else { return }
        transitioning.insert(vm.id)
        defer { transitioning.remove(vm.id) }
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
        transitioning.insert(vm.id)
        defer { transitioning.remove(vm.id) }
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

    private func handleGuestHalt(vmID: UUID, generation: Int, exitCode: Int32) {
        guard sessions[vmID] != nil, sessionGenerations[vmID] == generation else { return }
        harvestUEFIVariables(vmID: vmID)
        sessions[vmID] = nil
        setState(vmID: vmID, .stopped)
        consoleText[vmID, default: ""] += "\n[retasuVM] ゲスト OS が終了しました（終了コード \(exitCode)）\n"
        if let vm = machine(id: vmID) {
            appendLog(for: vmID, lines: ["[retasuVM] \(vm.name) のゲスト OS が終了しました（終了コード \(exitCode)）"])
        }
        save()
    }

    private func handleGuestFault(vmID: UUID, generation: Int, message: String) {
        guard sessions[vmID] != nil, sessionGenerations[vmID] == generation else { return }
        harvestUEFIVariables(vmID: vmID)
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
        harvestUEFIVariables(vmID: vmID)
        sessions[vmID]?.terminate()
        sessions[vmID] = nil
    }

    /// x86 セッションから UEFI 変数を回収し、VM の構成へ反映する（永続化）。
    private func harvestUEFIVariables(vmID: UUID) {
        guard let session = sessions[vmID] as? X86Session,
              let index = machines.firstIndex(where: { $0.id == vmID }) else { return }
        machines[index].configuration.uefiVariables = session.uefiVariables.map {
            UEFIVariableRecord(guid: $0.guid, name: $0.name,
                               attributes: $0.attributes, data: $0.data)
        }
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
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([VirtualMachine].self, from: data) {
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
            // デコードできない保存ファイルは、次の保存で失わないよう退避する
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        machines = Self.sampleData
    }

    private func save() {
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(machines) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// 初回起動時に表示するサンプルデータ。各ゲストイメージを 1 台ずつ用意する。
    static var sampleData: [VirtualMachine] {
        [
            VirtualMachine(
                name: "retasuOS ゲスト",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 1,
                    diskGB: 1,
                    guestOS: .linux,
                    guestImage: .retasuOS,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            ),
            VirtualMachine(
                name: "ゲーム用 VM",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 1,
                    diskGB: 1,
                    guestOS: .other,
                    guestImage: .playOS,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            ),
            VirtualMachine(
                name: "計算用 VM",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 1,
                    diskGB: 1,
                    guestOS: .other,
                    guestImage: .calcOS,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            ),
            VirtualMachine(
                name: "ARM デモ VM",
                configuration: VMConfiguration(
                    cpuCount: 1,
                    memoryMB: 4,
                    diskGB: 1,
                    architecture: .arm,
                    guestOS: .other,
                    guestImage: .retasuOS,
                    networkEnabled: false,
                    sharedFolderEnabled: false
                )
            )
        ]
    }
}
