import Foundation

/// ARM64 ゲストの実行セッション。
///
/// `ARM64Assembler` でゲストを機械語へ変換し、`ARM64CPU` 上で実行する。
/// 仕組みは `ARMSession` と同じ。
final class ARM64Session: GuestSession {
    let cpu: ARM64CPU

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

    init(memorySize: Int = 64 * 1024 * 1024) {
        cpu = ARM64CPU(memorySize: memorySize)
        cpu.onChar = { [weak self] byte in
            self?.appendOutput(byte)
        }
        cpu.onClearScreen = { [weak self] in
            self?.flushOutput()
            self?.onClear?()
        }
    }

    /// アセンブリソースからゲストを組み立てて実行を開始する。
    func boot(source: String) throws {
        runTask?.cancel()
        stateLock.lock()
        terminatedFlag = false
        pausedFlag = false
        stateLock.unlock()
        var assembler = ARM64Assembler()
        let program = try assembler.assemble(source)
        cpu.setRandomSeed(UInt32(Date().timeIntervalSince1970) &* 2654435761 | 1)
        cpu.loadProgram(program.bytes, at: program.entry)
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Mac プラットフォーム方式でゲストを起動する（ADT を配置し、X0 = ADT で開始）。
    func bootMac(source: String) throws {
        runTask?.cancel()
        stateLock.lock()
        terminatedFlag = false
        pausedFlag = false
        stateLock.unlock()
        var assembler = ARM64Assembler()
        let program = try assembler.assemble(source)
        cpu.loadProgram(program.bytes, at: program.entry)
        MacPlatform.installDeviceTree(cpu: cpu)
        cpu.setBootArgument(MacPlatform.adtAddress)
        cpu.attachNVMeDisk([UInt8](repeating: 0, count: 32 * 1024 * 1024))
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !isTerminated && !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            do {
                try cpu.run(maxInstructions: 200_000)
            } catch {
                flushOutput()
                if !isTerminated { onFault?((error as? ARM64Fault)?.description ?? error.localizedDescription) }
                return
            }
            flushOutput()
            if cpu.halted {
                flushOutput()
                if !isTerminated { onHalt?(cpu.exitCode) }
                return
            }
            if cpu.waitingForInput || cpu.idle {
                try? await Task.sleep(nanoseconds: 20_000_000)
            } else {
                await Task.yield()
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
        cpu.enqueueInput(text)
    }
}
