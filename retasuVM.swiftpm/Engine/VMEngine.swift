import Foundation

/// 仮想マシンの実行エンジン（セッション）。
///
/// 構成:
/// - `RISCVCPU`: RISC-V RV32I ソフトウェア CPU エミュレータ
/// - `RISCVAssembler`: ゲストプログラム用アセンブラ
/// - `GuestOS`: ゲスト OS「retasuOS」のアセンブリソース
///
/// iOS / iPadOS ではハードウェア仮想化（Hypervisor）がアプリに提供されないため、
/// retasuVM は CPU をソフトウェアでエミュレーションし、ゲスト OS を実際に
/// 実行する。起動すると retasuOS がブートし、コンソールから対話できる。
///
/// 1 台の VM につき 1 つのセッションを作り、バックグラウンドで CPU を
/// 回し続ける。出力はコールバック経由でコンソールへ流れる。
final class EmulatorSession {
    private let cpu = RISCVCPU()
    private var runTask: Task<Void, Never>?

    private var outputBuffer: [UInt8] = []
    private let bufferLock = NSLock()
    private let flagLock = NSLock()
    private var pausedFlag = false
    private var terminatedFlag = false

    /// ゲストの出力（文字列）がまとまって届く
    var onOutput: ((String) -> Void)?
    /// ゲストが画面消去を要求した
    var onClear: (() -> Void)?
    /// ゲストが終了した（引数は終了コード）
    var onHalt: ((Int32) -> Void)?
    /// CPU 異常で停止した（引数はエラーメッセージ）
    var onFault: ((String) -> Void)?

    var isPaused: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return pausedFlag
    }

    private var isTerminated: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return terminatedFlag
    }

    /// 指定したゲスト OS イメージをアセンブルして読み込み、実行を開始する。
    func boot(guestImage: GuestImage) throws {
        let program = try RISCVAssembler().assemble(guestImage.assemblySource)
        start(program: program.bytes, entry: program.entry, diskImage: nil)
    }

    /// フラットバイナリを直接読み込んで実行を開始する（ISO ブート用）。
    /// diskImage には ISO 全体を渡し、ゲストがディスク読み取り
    /// システムコールで参照できるようにする。
    func boot(program: [UInt8], entry: UInt32 = 0, diskImage: [UInt8]? = nil) {
        start(program: program, entry: entry, diskImage: diskImage)
    }

    private func start(program: [UInt8], entry: UInt32, diskImage: [UInt8]?) {
        if let diskImage {
            cpu.attachDisk(diskImage)
        }
        // 起動ごとに乱数の種を変える（ゲーム用）。テストでは CPU 側の固定種を使う。
        cpu.setRandomSeed(UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000)))
        cpu.loadProgram(program, at: entry)
        cpu.onChar = { [weak self] byte in
            guard let self else { return }
            self.bufferLock.lock()
            self.outputBuffer.append(byte)
            self.bufferLock.unlock()
        }
        cpu.onClear = { [weak self] in
            self?.onClear?()
        }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if isPaused {
                flushOutput()
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            do {
                _ = try cpu.run(maxInstructions: 20_000)
            } catch let fault as CPUFault {
                flushOutput()
                if !isTerminated { onFault?(fault.description) }
                return
            } catch {
                flushOutput()
                if !isTerminated { onFault?(error.localizedDescription) }
                return
            }
            flushOutput()
            if cpu.halted {
                if !isTerminated { onHalt?(cpu.exitCode) }
                return
            }
            if cpu.waitingForInput {
                try? await Task.sleep(for: .milliseconds(25))
            } else {
                await Task.yield()
            }
        }
    }

    private func flushOutput() {
        bufferLock.lock()
        let bytes = outputBuffer
        outputBuffer = []
        bufferLock.unlock()
        if !bytes.isEmpty {
            onOutput?(String(decoding: bytes, as: UTF8.self))
        }
    }

    // MARK: - 操作

    /// キーボード入力をゲストへ送る。
    func sendInput(_ text: String) {
        cpu.provideInput([UInt8](text.utf8))
    }

    func setPaused(_ paused: Bool) {
        flagLock.lock()
        pausedFlag = paused
        flagLock.unlock()
    }

    /// セッションを破棄する（電源断相当）。onHalt / onFault は呼ばれない。
    func terminate() {
        flagLock.lock()
        terminatedFlag = true
        flagLock.unlock()
        runTask?.cancel()
        runTask = nil
    }
}
