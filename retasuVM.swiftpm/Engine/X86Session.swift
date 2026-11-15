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
    var onScreenChange: (() -> Void)?
    private var lastScreenChecksum: UInt64 = 0
    var onClear: (() -> Void)?
    var onHalt: ((Int32) -> Void)?
    var onFault: ((String) -> Void)?

    private var runTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var pausedFlag = false
    private var terminatedFlag = false
    private var outputBuffer = ""
    private let bufferLock = NSLock()

    /// 起動時にファームウェアへ渡す UEFI 変数（永続化の復元用）。
    var initialUEFIVariables: [X86UEFI.Variable] = []
    /// 実行中に更新された UEFI 変数の最新状態（永続化の保存用）。
    private(set) var uefiVariables: [X86UEFI.Variable] = []

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

    /// イメージから起動して実行を開始する。
    ///
    /// Multiboot カーネル（ELF32 ファイルそのもの、または ISO のルートに
    /// 置かれた KERNEL.ELF）は Multiboot ローダで、それ以外は BIOS
    /// ブート（El Torito / raw イメージ）で起動する。
    func boot(imageData: [UInt8]) throws {
        // 二重に起動された場合は前の実行を止めてから始める
        runTask?.cancel()
        stateLock.lock()
        terminatedFlag = false
        pausedFlag = false
        stateLock.unlock()
        X86ACPI.install(cpu: cpu)
        if Multiboot.isMultibootKernel(imageData) {
            try Multiboot.boot(cpu: cpu, imageData: imageData)
            attachRAMDiskIfNeeded()
        } else if let iso = try? ISO9660Image(data: imageData),
                  let kernel = iso.file(named: "KERNEL.ELF"),
                  Multiboot.isMultibootKernel(kernel) {
            try Multiboot.boot(cpu: cpu, imageData: kernel)
            attachRAMDiskIfNeeded()
        } else if X86UEFI.isUEFIApplication(imageData) {
            uefiVariables = initialUEFIVariables
            try X86UEFI.boot(cpu: cpu, imageData: imageData,
                             initialVariables: initialUEFIVariables,
                             onVariablesChanged: { [weak self] variables in
                                 guard let self else { return }
                                 self.stateLock.lock()
                                 self.uefiVariables = variables
                                 self.stateLock.unlock()
                             })
        } else {
            try bios.boot(imageData: imageData)
        }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Multiboot 起動時はブートイメージがディスクにならないため、
    /// IDE 用に RAM ディスク（16 MiB、内容は VM の停止で消える）を接続する。
    private func attachRAMDiskIfNeeded() {
        if cpu.attachedDisk == nil {
            cpu.attachDisk(X86DiskImage(data: [UInt8](repeating: 0, count: 16 << 20)))
        }
    }

    private func runLoop() async {
        while !isTerminated {
            if isPaused {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            do {
                try cpu.run(maxInstructions: 200_000)
            } catch {
                flushOutput()
                if !isTerminated { onFault?((error as? X86Fault)?.description ?? error.localizedDescription) }
                return
            }
            if cpu.halted {
                flushOutput()
                if !isTerminated { onHalt?(cpu.exitCode) }
                return
            }
            X86UEFI.deliverPendingNotifications(cpu: cpu)
            let screenChecksum = currentScreenChecksum()
            if screenChecksum != lastScreenChecksum {
                lastScreenChecksum = screenChecksum
                onScreenChange?()
            }
            if cpu.waitingForInterrupt {
                // OS のアイドル状態: 割り込み（タイマ・キーボード等）を待つ
                try? await Task.sleep(nanoseconds: 5_000_000)
                do {
                    _ = try cpu.pollInterrupts()
                } catch {
                    flushOutput()
                    if !isTerminated { onFault?((error as? X86Fault)?.description ?? error.localizedDescription) }
                    return
                }
            } else if cpu.waitingForInput {
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
        cpu.provideInput([UInt8](text.utf8))
        X86UEFI.pushConInText(cpu: cpu, text: text)
    }

    /// 画面スナップショット: UEFI 起動時は GOP フレームバッファ、
    /// それ以外は VGA テキストメモリ（0xB8000、80×25）を読む。
    /// 画面の変化検出用チェックサム（FNV-1a、サンプリング）。
    private func currentScreenChecksum() -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        if let gop = X86UEFI.gopFramebufferInfo(cpu: cpu) {
            mix(UInt8(gop.width & 0xFF))
            mix(UInt8(gop.height & 0xFF))
            let total = gop.width * gop.height * 4
            var offset = 0
            while offset < total {
                mix(UInt8((try? cpu.readMemoryValue(at: gop.base + offset, size: 1)) ?? 0))
                offset += 4093
            }
            return hash
        }
        if cpu.devices.biosVideoMode == 0x13 || cpu.devices.vgaChain4Graphics {
            for offset in stride(from: 0, to: 0xFA00, by: 251) {
                mix(UInt8((try? cpu.readMemoryValue(at: 0xA0000 + offset, size: 1)) ?? 0))
            }
            for byte in cpu.devices.vgaPalette { mix(byte) }
            return hash
        }
        for offset in 0..<4000 {
            mix(UInt8((try? cpu.readMemoryValue(at: 0xB8000 + offset, size: 1)) ?? 0))
        }
        return hash
    }

    func screenSnapshot() -> GuestScreenSnapshot? {
        if let gop = X86UEFI.gopFramebufferInfo(cpu: cpu) {
            let count = gop.width * gop.height * 4
            var pixels = [UInt8]()
            pixels.reserveCapacity(count)
            var offset = 0
            while offset < count {
                let value = (try? cpu.readMemoryValue(at: gop.base + offset, size: 8)) ?? 0
                for i in 0..<8 { pixels.append(UInt8((value >> (8 * i)) & 0xFF)) }
                offset += 8
            }
            return .framebuffer(width: gop.width, height: gop.height, bgra: pixels)
        }
        if let vga = cpu.vgaMode13hFrame() {
            return .framebuffer(width: vga.width, height: vga.height, bgra: vga.bgra)
        }
        var lines: [String] = []
        for row in 0..<25 {
            var line = ""
            for column in 0..<80 {
                let byte = (try? cpu.readMemoryValue(at: 0xB8000 + row * 160 + column * 2, size: 1)) ?? 0
                if byte >= 0x20, byte < 0x7F {
                    line.append(Character(UnicodeScalar(UInt8(byte))))
                } else {
                    line.append(" ")
                }
            }
            lines.append(line)
        }
        return .text(lines: lines)
    }
}
