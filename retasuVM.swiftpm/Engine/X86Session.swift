import Foundation

/// x86 ゲストの実行セッション。
///
/// `X86CPU` と `X86BIOS` を所有し、BIOS ブートから実行ループまでを担う。
/// 出力のバッファリングや一時停止の仕組みは RISC-V 側の
/// `EmulatorSession` と同じ方式。
final class X86Session: GuestSession {
    let cpu = X86CPU()
    let bios: X86BIOS

    var onOutput: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onHalt: ((Int32) -> Void)?
    var onFault: ((String) -> Void)?

    private var runTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var pausedFlag = false
    private var terminatedFlag = false
    private var outputBuffer = ""
    private let bufferLock = NSLock()

    init() {
        bios = X86BIOS(cpu: cpu)
        cpu.interruptHandler = { [bios] vector in
            bios.handleInterrupt(vector)
        }
        cpu.onChar = { [weak self] byte in
            self?.appendOutput(byte)
        }
        cpu.onClearScreen = { [weak self] in
            self?.flushOutput()
            self?.onClear?()
        }
    }

    /// イメージ（ISO / raw）から BIOS ブートして実行を開始する。
    func boot(imageData: [UInt8]) throws {
        try bios.boot(imageData: imageData)
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !isTerminated {
            if isPaused {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            do {
                try cpu.run(maxInstructions: 50_000)
            } catch {
                flushOutput()
                onFault?((error as? X86Fault)?.description ?? error.localizedDescription)
                return
            }
            if cpu.halted {
                flushOutput()
                onHalt?(cpu.exitCode)
                return
            }
            if cpu.waitingForInput {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func appendOutput(_ byte: UInt8) {
        bufferLock.lock()
        outputBuffer += String(UnicodeScalar(byte))
        let shouldFlush = outputBuffer.count >= 64 || byte == 0x0A
        bufferLock.unlock()
        if shouldFlush { flushOutput() }
    }

    private func flushOutput() {
        bufferLock.lock()
        let text = outputBuffer
        outputBuffer = ""
        bufferLock.unlock()
        if !text.isEmpty { onOutput?(text) }
    }

    private var isPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pausedFlag
    }

    private var isTerminated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminatedFlag
    }

    func setPaused(_ paused: Bool) {
        stateLock.lock()
        pausedFlag = paused
        stateLock.unlock()
    }

    func terminate() {
        stateLock.lock()
        terminatedFlag = true
        stateLock.unlock()
        runTask?.cancel()
        runTask = nil
    }

    func sendInput(_ text: String) {
        cpu.provideInput([UInt8](text.utf8))
    }
}
