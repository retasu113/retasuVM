import Foundation
import Glibc

// usage: h_rom <AVPBooter.bin> [memMB] [maxInstrMillions] [installer 0/1]
// AVPBooter（VM ブート ROM）を QEMU vmapple / Henge と同じ開始状態で実行し、
// シリアル出力（PL011）と到達地点を観察するハーネス。
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: h_rom <rom> [memMB] [maxM] [installer]"); exit(2) }
let rom = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let memMB = args.count > 2 ? Int(args[2])! : 2048
let maxM = args.count > 3 ? Int(args[3])! : 100
let installer = args.count > 4 ? args[4] != "0" : false

// VMAPPLE_ECID: 10進数、または 0x 始まりの16進数。未設定時は従来デフォルト。
let vmappleECID: UInt64 = {
    guard let s = ProcessInfo.processInfo.environment["VMAPPLE_ECID"], !s.isEmpty else {
        return 0x0001_0203_0405_0607
    }
    let v: UInt64?
    if s.hasPrefix("0x") || s.hasPrefix("0X") { v = UInt64(s.dropFirst(2), radix: 16) } else { v = UInt64(s) }
    return v ?? 0x0001_0203_0405_0607
}()
FileHandle.standardError.write(Data("[romboot] VMAPPLE_ECID=\(vmappleECID)\n".utf8))

var cpu = ARM64CPU(memorySize: memMB * 1024 * 1024)
cpu.setupROMBoot(rom: rom, installer: installer, ecid: vmappleECID)
if let ts = ProcessInfo.processInfo.environment["TIMESCALE"], let v = Double(ts), v > 0 {
    cpu.timeScale = v
    FileHandle.standardError.write(Data("[romboot] TIMESCALE=\(v)\n".utf8))
}
let disksDir = (ProcessInfo.processInfo.environment["HOME"] ?? "/home/hatch") + "/workspace/retasuvm/disks"
try? FileManager.default.createDirectory(atPath: disksDir, withIntermediateDirectories: true)
let rootDiskPath = disksDir + "/root.img"
let auxDiskPath = disksDir + "/aux.img"
func diskFileSize(_ path: String, fallback: Int) -> Int {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let n = attrs[.size] as? NSNumber { return n.intValue }
    return fallback
}
let rootDiskSize = diskFileSize(rootDiskPath, fallback: 64 * 1024 * 1024 * 1024)
let auxDiskSize = diskFileSize(auxDiskPath, fallback: 64 * 1024 * 1024)
cpu.attachBdifDiskFiles(rootPath: rootDiskPath, rootSize: rootDiskSize, auxPath: auxDiskPath, auxSize: auxDiskSize)
FileHandle.standardError.write(Data("[romboot] bdif root=\(rootDiskPath) (\(rootDiskSize)) aux=\(auxDiskPath) (\(auxDiskSize))\n".utf8))
// MARK: USB ブリッジ（VUSB_SOCK 指定時: リストア用クライアントと Unix ソケットで接続）
let bridgePath = ProcessInfo.processInfo.environment["VUSB_SOCK"]
var bridgeServerFD: Int32 = -1
var bridgeClientFD: Int32 = -1
var bridgeRx: [UInt8] = []
var bridgeSession: UInt32 = 0
var bridgeOnline = false
var bridgeDrainStale = false
var bridgeSawRequest = false
func bridgeSend(_ bytes: [UInt8]) {
    guard bridgeClientFD >= 0 else { return }
    bytes.withUnsafeBytes { raw in
        var sent = 0
        while sent < bytes.count {
            let n = send(bridgeClientFD, raw.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
            if n <= 0 { return }
            sent += n
        }
    }
}
func bridgeSendState() {
    var f: [UInt8] = [3, bridgeOnline ? 1 : 0]
    for i in 0..<4 { f.append(UInt8((bridgeSession >> UInt32(8 * i)) & 0xFF)) }
    bridgeSend(f)
}
func bridgeSetup() {
    guard let path = bridgePath else { return }
    unlink(path)
    bridgeServerFD = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pb = Array(path.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: Int8.self, capacity: 108) { q in
            for i in 0..<min(pb.count, 107) { q[i] = Int8(bitPattern: pb[i]) }
        }
    }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(bridgeServerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 || listen(bridgeServerFD, 4) != 0 {
        FileHandle.standardError.write(Data("[romboot] bridge setup failed rc=\(rc)\n".utf8))
        bridgeServerFD = -1
        return
    }
    let fl = fcntl(bridgeServerFD, F_GETFL)
    _ = fcntl(bridgeServerFD, F_SETFL, fl | O_NONBLOCK)
    FileHandle.standardError.write(Data("[romboot] bridge listening at \(path)\n".utf8))
}
func bridgeService() {
    guard bridgeServerFD >= 0 else { return }
    if bridgeClientFD < 0 {
        let c = accept(bridgeServerFD, nil, nil)
        if c >= 0 {
            bridgeClientFD = c
            FileHandle.standardError.write(Data("[romboot] bridge client connected\n".utf8))
            // 新しいホストセッションはクリーンに始める: 前クライアント宛の残留応答を捨てる
            // （残ると要求/応答の対応がずれ、列挙が自己永続的に失敗する）。ゲストの Q1 に
            // まだ残っている分は、最初の要求が来るまで転送せず破棄し続ける。
            bridgeDrainStale = true
            bridgeSawRequest = false
            var drained = 0
            while cpu.vusbTakeResponse() != nil { drained += 1 }
            if drained > 0 {
                FileHandle.standardError.write(Data("[romboot] bridge: drained \(drained) stale responses\n".utf8))
            }
            bridgeSendState()
        }
    }
    if bridgeClientFD >= 0 {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let cap = tmp.count
        var sawEOF = false
        while true {
            let n = tmp.withUnsafeMutableBytes { recv(bridgeClientFD, $0.baseAddress!, cap, Int32(MSG_DONTWAIT)) }
            if n > 0 { bridgeRx += tmp[0..<n] } else {
                if n == 0 { sawEOF = true }
                break
            }
        }
        if sawEOF {
            FileHandle.standardError.write(Data("[romboot] bridge client disconnected\n".utf8))
            close(bridgeClientFD)
            bridgeClientFD = -1
            bridgeRx = []
            if installer { scanGuestLog(cpu.memory, tag: "glog-disc") }
        }
        while bridgeRx.count >= 11 {
            guard bridgeRx[0] == 1 else { bridgeRx.removeFirst(); continue }
            let type = bridgeRx[1], ep = bridgeRx[2]
            let len = UInt32(bridgeRx[3]) | UInt32(bridgeRx[4]) << 8 | UInt32(bridgeRx[5]) << 16 | UInt32(bridgeRx[6]) << 24
            let plen = Int(UInt32(bridgeRx[7]) | UInt32(bridgeRx[8]) << 8 | UInt32(bridgeRx[9]) << 16 | UInt32(bridgeRx[10]) << 24)
            guard bridgeRx.count >= 11 + plen else { break }
            let payload: [UInt8]? = plen > 0 ? [UInt8](bridgeRx[11..<11 + plen]) : nil
            bridgeRx.removeFirst(11 + plen)
            let ok = cpu.vusbSendRequest(type: type, ep: ep, data: payload, len: payload != nil ? UInt32(plen) : len)
            if !ok { FileHandle.standardError.write(Data("[romboot] bridge: request dropped (offline/full) type=\(type) ep=0x\(String(ep, radix: 16))\n".utf8)) }
            bridgeSawRequest = true
        }
        var sawAnyRsp = false
        while let rsp = cpu.vusbTakeResponse() {
            sawAnyRsp = true
            if bridgeDrainStale { continue }
            let data = rsp.data ?? []
            var f: [UInt8] = [2, rsp.type, rsp.ep]
            for i in 0..<4 { f.append(UInt8((UInt32(data.count) >> UInt32(8 * i)) & 0xFF)) }
            f += data
            bridgeSend(f)
        }
        // 最初の要求が届いたあと、残留応答が一度途切れたら破棄を終える
        if bridgeDrainStale && bridgeSawRequest && !sawAnyRsp { bridgeDrainStale = false }

    }
    // 状態フレームはエンジン側セッションの変化でも送る（iBSS が UNK2 を書き直して
    // セッションだけ進めた場合も、ホスト側 shim が再列挙できるように）。
    let on = cpu.vusbOnline
    let sess = cpu.vusbSession
    if on != bridgeOnline || sess != bridgeSession {
        bridgeOnline = on
        bridgeSession = sess
        bridgeSendState()
    }
}

/// ゲストリセット時に CPU を作り直して再起動する（インストーラ用）。ディスクはファイル裏付けで引き継がれる。
var seenLogStrings = Set<String>()
func scanGuestLog(_ mem: [UInt8], tag: String) {
    // DRAM オフセット 0x20000-GLOG_HI の可読文字列のうち未出のものを出す（iBoot 系ログ回収用）
    var cur: [UInt8] = []
    let hiCap = ProcessInfo.processInfo.environment["GLOG_HI"].flatMap { UInt64($0, radix: 16) } ?? 0x200000
    let lo = 0x20000, hi = min(Int(hiCap), mem.count)
    guard hi > lo else { return }
    func flush() {
        if cur.count >= 8 {
            let s = String(decoding: cur, as: UTF8.self)
            if !seenLogStrings.contains(s) {
                seenLogStrings.insert(s)
                FileHandle.standardError.write(Data("[romboot] \(tag): \(s)\n".utf8))
            }
        }
        cur = []
    }
    for i in lo..<hi {
        let b = mem[i]
        if b >= 0x20 && b < 0x7F { cur.append(b) } else { flush() }
    }
    flush()
}

func dumpROMLog(_ mem: [UInt8]) {
    // ROM のログリング周辺（DRAM オフセット 0x20000-0x40000）の可読文字列を出す
    var runs: [String] = []
    var cur: [UInt8] = []
    let lo = 0x20000, hi = min(0x40000, mem.count)
    guard hi > lo else { return }
    for i in lo..<hi {
        let b = mem[i]
        if b >= 0x20 && b < 0x7F { cur.append(b) } else {
            if cur.count >= 6 { runs.append(String(decoding: cur, as: UTF8.self)) }
            cur = []
        }
    }
    if cur.count >= 6 { runs.append(String(decoding: cur, as: UTF8.self)) }
    for s in runs.suffix(48) {
        FileHandle.standardError.write(Data("[romboot] romlog: \(s)\n".utf8))
    }
}


func scanPanicLog(_ mem: [UInt8], tag: String) {
    let keys: [[UInt8]] = [Array("panic(cpu ".utf8), Array("panic(cpu".utf8),
                           Array("Debugger called: <panic>".utf8), Array("panic: ".utf8)]
    for key in keys {
        var hits = 0
        mem.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let total = buf.count
            var cursor: UnsafePointer<UInt8>? = base
            while hits < 4, let cur = cursor {
                let remaining = total - (cur - base)
                guard remaining >= key.count else { break }
                let found = key.withUnsafeBufferPointer { kb in
                    memmem(cur, remaining, kb.baseAddress!, key.count)
                }
                guard let f = found else { break }
                let hp = f.assumingMemoryBound(to: UInt8.self)
                let hpc = UnsafePointer(hp)
                let off = base.distance(to: hpc)
                var n = 0
                while off + n < total && n < 3000 {
                    let c = hp[n]
                    if c == 0x0A || c == 0x09 || (c >= 32 && c < 127) { n += 1 } else { break }
                }
                if n > 80 {
                    hits += 1
                    var out: [UInt8] = []
                    var i = 0
                    while i < 6000 && off + i < total && out.count < 6000 {
                        let c = hp[i]
                        if c == 0x0A || c == 0x09 || (c >= 32 && c < 127) { out.append(c) }
                        else if c == 0 && !out.isEmpty && out[out.count - 1] != 0x0A { out.append(0x0A) }
                        i += 1
                    }
                    let str = String(decoding: out, as: UTF8.self)
                    FileHandle.standardError.write(Data(String(format: "[panic] %@ key#%d hit #%d at PA 0x%llX runlen=%d:\n%@\n[panic] END hit\n", tag, keys.firstIndex(of: key)!, hits, UInt64(0x70000000 + off), n, str).utf8))
                }
                cursor = hpc + key.count
            }
        }
        if hits > 0 { break }
    }
}

func rebootCPU() {
    dumpROMLog(cpu.memory)
    // Henge / QEMU と同じリセット意味論: CPU 状態だけをリセットし、DRAM の内容は
    //保持する（ROM が DRAM へステージした次段イメージがリセットを跨いで残る）。
    let savedMemory = cpu.memory
    let savedCfg = cpu.cfgWindow
    let savedROM = cpu.romData
    let fresh = ARM64CPU(memorySize: memMB * 1024 * 1024)
    fresh.setupROMBoot(rom: rom, installer: installer, ecid: vmappleECID)
    fresh.timeScale = cpu.timeScale
    if fresh.memory.count == savedMemory.count {
        fresh.memory = savedMemory
    }
    // ROM ウィンドウも RAM であり、ROM 自身の .data/.bss を含むため保持する
    // （QEMU / Henge では BIOS 用 RAM ブロックはリセットを跨いで残る）。
    if fresh.romData.count == savedROM.count {
        fresh.romData = savedROM
    }
    // cfg ウィンドウ（scratch 領域を含む）もマシン状態として保持する。
    // QEMU / Henge では cfg デバイスはリセットで再生成されない。
    if fresh.cfgWindow.count == savedCfg.count {
        fresh.cfgWindow = savedCfg
    }
    fresh.attachBdifDiskFiles(rootPath: rootDiskPath, rootSize: rootDiskSize, auxPath: auxDiskPath, auxSize: auxDiskSize)
    installHooks(fresh)
    cpu = fresh
}
FileHandle.standardError.write(Data("[romboot] pc=0x100000 mem=\(memMB)MB installer=\(installer) romBytes=\(rom.count)\n".utf8))

var outBuffer: [UInt8] = []
let stderr = FileHandle.standardError
var pcRing: [UInt64] = []
var excCount = 0
var parkDumped = false
var logEntries = 0
let watchEnabled = ProcessInfo.processInfo.environment["WATCH"] != nil
var watchPrev: [UInt64] = [0, 0, 0, 0]
let watchOffs: [Int] = [0x340C8, 0x340D0, 0x340E0, 0x340E8]
func watchQword(_ idx: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(cpu.memory[watchOffs[idx] + i]) << UInt64(i * 8) }
    return v
}
func romString(_ va: UInt64) -> String {
    // ROM データ領域 (0x100000-0x160000) の文字列を読む
    guard va >= 0x100000 && va < 0x160000 else { return "<va 0x\(String(va, radix: 16))>" }
    let off = Int(va - 0x100000)
    var bytes: [UInt8] = []
    var i = off
    while i < rom.count && rom[i] != 0 && bytes.count < 100 { bytes.append(rom[i]); i += 1 }
    return String(bytes: bytes, encoding: .ascii) ?? "<bin>"
}
let traceEnabled = ProcessInfo.processInfo.environment["ROM_TRACE"] != nil
var traceCount = 0

// LLB probe 4 state (scratch only)
var p4InCheck = false
var p4Pend794: UInt64? = nil
var p4Pend884: UInt64? = nil
var p4Pend968: [UInt64] = []
var p5Pend90: [UInt64] = []
var p6LoadRet: [UInt64] = []
var p6ImpRet: [UInt64] = []
var p6MatchRet: [UInt64] = []
var p6LookupDumps = 0
var auditSawTrampoline = false
var auditEntryCaptured = false
var auditVACaptured = false
func auditDumpRegs(_ tag: String, _ pc: UInt64) {
    var msg = String(format: "[audit] %@ pc=0x%llX at instr %lld regs:", tag, pc, cpu.instructionsExecuted)
    for r in 0..<29 {
        msg += String(format: " x%d=0x%llX", r, cpu.registers[r])
    }
    stderr.write(Data((msg + "\n").utf8))
    // For every register pointing into DRAM, dump the first 128 bytes as
    // 16 u64s: one of them is the boot_args pointer (virtBase/physBase pair).
    for r in 0..<29 {
        let a = cpu.registers[r]
        guard a >= 0x7000_0000 && a < 0x1_7000_0000 else { continue }
        var parts: [String] = []
        for i in 0..<16 {
            parts.append(String(format: "%016llX", cpu.readGuestMemory(address: a + UInt64(i * 8), size: 8)))
        }
        stderr.write(Data(String(format: "[audit] %@ x%d -> [%@]\n", tag, r, parts.joined(separator: " ")).utf8))
    }
}

var p6Stored = 0
func p6U32(_ addr: UInt64) -> UInt64 {
    guard addr >= 0x7000_0000 && addr < 0x1_7000_0000 else { return 0 }
    return cpu.readGuestMemory(address: addr, size: 4) & 0xffffffff
}
func p6Bytes(_ addr: UInt64, _ n: Int) -> String {
    guard addr >= 0x7000_0000 && addr < 0x1_7000_0000 else { return "" }
    var bytes: [UInt8] = []
    for i in 0..<n {
        bytes.append(UInt8(cpu.readGuestMemory(address: addr + UInt64(i), size: 1) & 0xff))
    }
    return String(bytes: bytes, encoding: .ascii) ?? ""
}
func p4CString(_ addr: UInt64) -> String {
    let inDRAM = addr >= 0x7000_0000 && addr < 0x7020_0000
    let inROM = addr >= 0x10_0000 && addr < 0x20_0000
    guard inDRAM || inROM else { return "" }
    var bytes: [UInt8] = []
    var a = addr
    while bytes.count < 40 {
        let b = UInt8(cpu.readGuestMemory(address: a, size: 1) & 0xff)
        if b == 0 { break }
        guard b >= 0x20 && b < 0x7f else { return "" }
        bytes.append(b)
        a += 1
    }
    if bytes.count < 2 { return "" }
    return String(bytes: bytes, encoding: .ascii) ?? ""
}
func p4Dump32(_ addr: UInt64) -> String {
    guard addr >= 0x7000_0000 && addr < 0x7020_0000 else { return "" }
    var parts: [String] = []
    for i in 0..<4 {
        parts.append(String(format: "%016llX", cpu.readGuestMemory(address: addr + UInt64(i * 8), size: 8)))
    }
    return parts.joined(separator: " ")
}
func installHooks(_ c: ARM64CPU) {
if ProcessInfo.processInfo.environment["FAST"] != nil {
    // 高速モード: fetch フックを付けない（リストア実行用）
    c.onChar = { byte in
        outBuffer.append(byte)
        if byte == 0x0A || outBuffer.count >= 4096 {
            FileHandle.standardOutput.write(Data(outBuffer))
            outBuffer.removeAll()
        }
    }
    c.onVusbEvent = { msg in
        stderr.write(Data("[romboot] vusb \(msg)\n".utf8))
    }
    return
}
c.onChar = { byte in
    outBuffer.append(byte)
    if byte == 0x0A || outBuffer.count >= 4096 {
        FileHandle.standardOutput.write(Data(outBuffer))
        outBuffer.removeAll()
    }
}
c.onFetch = { pc, _ in
    if traceEnabled && traceCount < 2400000 {
        traceCount += 1
        FileHandle.standardError.write(Data(String(format: "T %llX\n", pc).utf8))
    }
    pcRing.append(pc)
    if pcRing.count > 64 { pcRing.removeFirst() }
    if watchEnabled {
        for i in 0..<4 {
            let v = watchQword(i)
            if v != watchPrev[i] {
                stderr.write(Data(String(format: "[romboot] WATCH 0x%llX <- 0x%llX (was 0x%llX) at pc=0x%llX instr %lld\n", UInt64(0x70000000 + watchOffs[i]), v, watchPrev[i], pc, cpu.instructionsExecuted).utf8))
                watchPrev[i] = v
            }
        }
    }
    if pc == 0x1044ec || pc == 0x1005ac {  // svc サイト: その時点の EL/SPSel
        stderr.write(Data(String(format: "[romboot] SVC site pc=0x%llX pstate=0x%llX el=%d spsel=%d spEL0=0x%llX spEL1=0x%llX at instr %lld\n",
                                 pc, cpu.pstate, cpu.currentEL, cpu.pstate & 1, cpu.spEL0, cpu.spEL1, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x104720 || pc == 0x109f7c {  // TPIDR_EL0 書き込み / 読み取り
        stderr.write(Data(String(format: "[romboot] TPIDR %@ pc=0x%llX x0=0x%llX x1=0x%llX tpidrEL0=0x%llX at instr %lld\n",
                                 pc == 0x104720 ? "WRITE" : "READ", pc, cpu.registers[0], cpu.registers[1], cpu.tpidrEL0, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x109a98 || pc == 0x109ad0 {  // validate_sp 入口 / 失敗分岐
        stderr.write(Data(String(format: "[romboot] VALIDATE pc=0x%llX spEL0=0x%llX spEL1=0x%llX pstate=0x%llX at instr %lld\n",
                                 pc, cpu.spEL0, cpu.spEL1, cpu.pstate, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x106060 && logEntries < 6 {  // ログ/パニック関数の入口
        logEntries += 1
        stderr.write(Data("[romboot] LOG #\(logEntries) at instr \(cpu.instructionsExecuted) x0=0x\(String(cpu.registers[0], radix: 16)) fmt=\"\(romString(cpu.registers[1]))\" x2str=\"\(romString(cpu.registers[2]))\" x2=0x\(String(cpu.registers[2], radix: 16)) x3=0x\(String(cpu.registers[3], radix: 16)) lr=0x\(String(cpu.registers[30], radix: 16))\n".utf8))
        stderr.write(Data("[romboot]   path: \(pcRing.suffix(24).map { "0x" + String($0, radix: 16) }.joined(separator: " "))\n".utf8))
    }
    if (0x115560...0x115578).contains(pc) {  // neg/and の前後を追跡
        stderr.write(Data(String(format: "[romboot] STEP pc=0x%llX x10=0x%llX x11=0x%llX x20=0x%llX at instr %lld\n",
                                 pc, cpu.registers[10], cpu.registers[11], cpu.registers[20], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x115578 || pc == 0x1155b8 {  // 領域セットアップのストア: レジスタを記録
        stderr.write(Data(String(format: "[romboot] SETUP pc=0x%llX x8=0x%llX x9=0x%llX x10=0x%llX x11=0x%llX x20=0x%llX x21=0x%llX at instr %lld\n",
                                 pc, cpu.registers[8], cpu.registers[9], cpu.registers[10], cpu.registers[11], cpu.registers[20], cpu.registers[21], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x115ba0 {  // 割り当て判定分岐: 比較対象を記録
        stderr.write(Data(String(format: "[romboot] ALLOCCHK x0=0x%llX x8=0x%llX x9=0x%llX x19=0x%llX at instr %lld\n",
                                 cpu.registers[0], cpu.registers[8], cpu.registers[9], cpu.registers[19], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x10c728 {  // checked-deref 読み取り関数の入口
        stderr.write(Data(String(format: "[romboot] DEREF x0=0x%llX x1=0x%llX x2=0x%llX w3=0x%llX [x0]=0x%llX at instr %lld\n",
                                 cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3],
                                 cpu.readGuestMemory(address: cpu.registers[0], size: 8), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x10c74c {  // その戻り: w0 が結果
        stderr.write(Data(String(format: "[romboot] DEREFRET w0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    // LLB 0x65 diagnosis probes (scratch only)
    if pc == 0x7006e9ac {  // after ldrb w0, [x21, #0x30]
        stderr.write(Data(String(format: "[llb] GATE byte30=0x%llX entry=0x%llX at instr %lld\n", cpu.registers[0] & 0xff, cpu.registers[21], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7006e9b0 {  // fn 0x7009df64 entry
        stderr.write(Data(String(format: "[llb] CHK enter arg=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7006e9b4 {  // fn 0x7009df64 returned
        stderr.write(Data(String(format: "[llb] CHK ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700923bc {  // record_failure entry
        stderr.write(Data(String(format: "[llb] RECORD reason=0x%llX lr=0x%llX at instr %lld\n", cpu.registers[0], cpu.registers[30], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009dfac {  // after boot-device-info call inside check
        stderr.write(Data(String(format: "[llb] CHK devinfo x0=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX at instr %lld\n", cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009dfc4 {  // after first property query
        stderr.write(Data(String(format: "[llb] CHK prop1 w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009dfd0 {  // after second property query
        stderr.write(Data(String(format: "[llb] CHK prop2 w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e040 {  // after /lpol lookup call
        stderr.write(Data(String(format: "[llb] CHK lpol w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e140 {  // after find-component call
        stderr.write(Data(String(format: "[llb] CHK findcomp x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e1a4 {  // after verify call
        stderr.write(Data(String(format: "[llb] CHK verify w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    // LLB probe 4: pending-return tracking
    if let lr = p4Pend794, pc == lr {
        p4Pend794 = nil
        stderr.write(Data(String(format: "[llb4] E794 ret x0=0x%llX cache6590=[%@] at instr %lld\n", cpu.registers[0], p4Dump32(0x700E6590), cpu.instructionsExecuted).utf8))
    }
    if let lr = p4Pend884, pc == lr {
        p4Pend884 = nil
        stderr.write(Data(String(format: "[llb4] E884 ret x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if let lr = p4Pend968.last, pc == lr {
        p4Pend968.removeLast()
        stderr.write(Data(String(format: "[llb4] PROP ret w0=0x%llX x0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7006e9b0 { p4InCheck = true }
    if pc == 0x7006e9b4 { p4InCheck = false; p4Pend968.removeAll() }
    if pc == 0x7009df64 {
        stderr.write(Data(String(format: "[llb4] DF64 enter x0=0x%llX lr=0x%llX at instr %lld\n", cpu.registers[0], cpu.registers[30], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700968f8 {
        if p4Pend968.count < 16 { p4Pend968.append(cpu.registers[30]) }
        var desc = ""
        for r in 0...5 {
            let str = p4CString(cpu.registers[r])
            if !str.isEmpty { desc += " x\(r)=\"\(str)\"" }
        }
        stderr.write(Data(String(format: "[llb4] PROP enter inChk=%d lr=0x%llX x0=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX x4=0x%llX x5=0x%llX%@ at instr %lld\n", p4InCheck ? 1 : 0, cpu.registers[30], cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[4], cpu.registers[5], desc, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e794 {
        p4Pend794 = cpu.registers[30]
        stderr.write(Data(String(format: "[llb4] E794 enter inChk=%d lr=0x%llX x0=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX x1d=[%@] x2d=[%@] at instr %lld\n", p4InCheck ? 1 : 0, cpu.registers[30], cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], p4Dump32(cpu.registers[1]), p4Dump32(cpu.registers[2]), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e884 {
        p4Pend884 = cpu.registers[30]
        stderr.write(Data(String(format: "[llb4] E884 enter inChk=%d lr=0x%llX x0=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX x4=0x%llX x5=0x%llX x1d=[%@] x2d=[%@] x3d=[%@] at instr %lld\n", p4InCheck ? 1 : 0, cpu.registers[30], cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[4], cpu.registers[5], p4Dump32(cpu.registers[1]), p4Dump32(cpu.registers[2]), p4Dump32(cpu.registers[3]), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e2c8 {
        stderr.write(Data(String(format: "[llb4] DF64 FAIL-EXIT x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e348 {
        stderr.write(Data(String(format: "[llb4] DF64 OK-EXIT x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    // AUDIT: kernel entry / boot-args capture
    if pc >= 0xACA0_0000 && pc < 0xACA1_0000 { auditSawTrampoline = true }
    if !auditEntryCaptured && pc >= 0x7300_0000 && pc < 0x7D00_0000 {
        auditEntryCaptured = true
        stderr.write(Data(String(format: "[audit] PHYS TRANSITION pc=0x%llX trampoline=%d at instr %lld\n", pc, auditSawTrampoline ? 1 : 0, cpu.instructionsExecuted).utf8))
        auditDumpRegs("ENTRY", pc)
    }
    if !auditVACaptured && pc >= 0xFFFF_FE00_0000_0000 {
        auditVACaptured = true
        auditDumpRegs("VA-ENTRY", pc)
    }
    // LLB probe 6: NVRAM env-import path (load fn 0x7009ffc4 and below)
    if let lr = p6LoadRet.last, pc == lr {
        p6LoadRet.removeLast()
        stderr.write(Data(String(format: "[llb6] LOAD ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if let lr = p6ImpRet.last, pc == lr {
        p6ImpRet.removeLast()
        stderr.write(Data(String(format: "[llb6] IMPORT ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if let lr = p6MatchRet.last, pc == lr {
        p6MatchRet.removeLast()
        stderr.write(Data(String(format: "[llb6] MATCH ret x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009ffc4 {
        if p6LoadRet.count < 8 { p6LoadRet.append(cpu.registers[30]) }
        let o = cpu.registers[0]
        stderr.write(Data(String(format: "[llb6] LOAD enter obj=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX lr=0x%llX cfg=[type=%lld count=%lld size=%lld fC=%lld f10=%lld gen=%lld bank=%lld f1C=%lld] x19=0x%llX x20=0x%llX x21=0x%llX at instr %lld\n",
            o, cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[30],
            p6U32(o), p6U32(o + 4), p6U32(o + 8), p6U32(o + 0xc), p6U32(o + 0x10), p6U32(o + 0x14), p6U32(o + 0x18), p6U32(o + 0x1c),
            cpu.registers[19], cpu.registers[20], cpu.registers[21], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0018 {
        stderr.write(Data(String(format: "[llb6] LOAD dtlookup x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0468 {
        stderr.write(Data(String(format: "[llb6] PROBE enter x0=0x%llX x4=0x%llX lr=0x%llX at instr %lld\n", cpu.registers[0], cpu.registers[4], cpu.registers[30], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0080 {
        stderr.write(Data(String(format: "[llb6] PROBE ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0094 {
        stderr.write(Data(String(format: "[llb6] GENOK at instr %lld\n", cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a00e8 {
        stderr.write(Data(String(format: "[llb6] BANKREAD ret x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0138 {
        stderr.write(Data(String(format: "[llb6] ADLER computed=0x%llX stored=0x%llX buf=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.registers[8] & 0xffffffff, cpu.registers[28], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0180 {
        let p = cpu.registers[24]
        stderr.write(Data(String(format: "[llb6] PART hdr=0x%llX sig=0x%llX storedck=0x%llX compck=0x%llX len16=%lld name=\"%@\" cursor=%lld at instr %lld\n",
            p, cpu.readGuestMemory(address: p, size: 1) & 0xff, cpu.readGuestMemory(address: p + 1, size: 1) & 0xff, cpu.registers[0] & 0xff,
            cpu.readGuestMemory(address: p + 2, size: 2) & 0xffff, p6Bytes(p + 4, 12), cpu.registers[22], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009b2bc {
        if p6MatchRet.count < 16 { p6MatchRet.append(cpu.registers[30]) }
        stderr.write(Data(String(format: "[llb6] MATCH enter lr=0x%llX x0=0x%llX partname=\"%@\" x3=0x%llX x5=0x%llX \"%@\" x6=0x%llX \"%@\" x7=0x%llX at instr %lld\n",
            cpu.registers[30], cpu.registers[0], p6Bytes(cpu.registers[0], 12), cpu.registers[3], cpu.registers[5], p6Bytes(cpu.registers[5], 12), cpu.registers[6], p6Bytes(cpu.registers[6], 12), cpu.registers[7], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0288 {
        p6Stored = 1
        stderr.write(Data(String(format: "[llb6] STORE part=0x%llX slot9=0x%llX at instr %lld\n", cpu.registers[24], cpu.registers[9], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a02a0 {
        stderr.write(Data(String(format: "[llb6] PARTNEXT part=0x%llX stored=%d at instr %lld\n", cpu.registers[24], p6Stored, cpu.instructionsExecuted).utf8))
        p6Stored = 0
    }
    if pc == 0x700a0348 {
        stderr.write(Data(String(format: "[llb6] LOAD postloop chosen=0x%llX x19=0x%llX cfg10=%lld cfg14=%lld at instr %lld\n", cpu.registers[8], cpu.registers[19], p6U32(cpu.registers[19] + 0x10), p6U32(cpu.registers[19] + 0x14), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0390 {
        stderr.write(Data(String(format: "[llb6] IMPORT1 call data=0x%llX len=%lld mode=%lld at instr %lld\n", cpu.registers[0], cpu.registers[4], cpu.registers[5], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0394 {
        stderr.write(Data(String(format: "[llb6] IMPORT1 ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0404 {
        stderr.write(Data(String(format: "[llb6] IMPORT2 call data=0x%llX len=%lld mode=%lld at instr %lld\n", cpu.registers[0], cpu.registers[4], cpu.registers[5], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a0408 {
        stderr.write(Data(String(format: "[llb6] IMPORT2 ret w0=0x%llX at instr %lld\n", cpu.registers[0] & 0xffffffff, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009f688 {
        if p6ImpRet.count < 8 { p6ImpRet.append(cpu.registers[30]) }
        stderr.write(Data(String(format: "[llb6] IMPORT enter data=0x%llX len=%lld mode=%lld lr=0x%llX first24=\"%@\" at instr %lld\n", cpu.registers[0], cpu.registers[4], cpu.registers[5], cpu.registers[30], p6Bytes(cpu.registers[0], 24), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x700a1164 && (cpu.registers[30] == 0x7009f96c || cpu.registers[30] == 0x7009f9b8) {
        stderr.write(Data(String(format: "[llb6] SETVAR lr=0x%llX name=\"%@\" nlen=%lld at instr %lld\n", cpu.registers[30], p6Bytes(cpu.registers[0], 24), cpu.registers[4], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x70090f84 && p6LookupDumps < 2 {
        p6LookupDumps += 1
        stderr.write(Data(String(format: "[llb6] LOOKUP#%d A80=[%@] AC0=[%@] B00=[%@] env170=[%@] at instr %lld\n", p6LookupDumps, p4Dump32(0x700E1A80) + " " + p4Dump32(0x700E1AA0), p4Dump32(0x700E1AC0) + " " + p4Dump32(0x700E1AE0), p4Dump32(0x700E1B00) + " " + p4Dump32(0x700E1B20), p4Dump32(0x700CC170) + " " + p4Dump32(0x700CC190), cpu.instructionsExecuted).utf8))
    }
    // LLB probe 5: boot-volume resolution inside E794
    if let lr = p5Pend90.last, pc == lr {
        p5Pend90.removeLast()
        stderr.write(Data(String(format: "[llb5] LKUP ret x0=0x%llX x1=0x%llX x2=0x%llX x3=0x%llX x0s=\"%@\" at instr %lld\n", cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], p4CString(cpu.registers[0]), cpu.instructionsExecuted).utf8))
    }
    if pc == 0x70090f84 {
        if p5Pend90.count < 16 { p5Pend90.append(cpu.registers[30]) }
        stderr.write(Data(String(format: "[llb5] LKUP enter lr=0x%llX x0=\"%@\" x1=\"%@\" x2=\"%@\" x3=0x%llX at instr %lld\n", cpu.registers[30], p4CString(cpu.registers[0]), p4CString(cpu.registers[1]), p4CString(cpu.registers[2]), cpu.registers[3], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e800 {
        stderr.write(Data(String(format: "[llb5] ALTCHK x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e830 {
        stderr.write(Data(String(format: "[llb5] ALT-MISSING x21=0x%llX at instr %lld\n", cpu.registers[21], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e844 {
        stderr.write(Data("[llb5] BOOTVOL-PATH at instr \(cpu.instructionsExecuted)\n".utf8))
    }
    if pc == 0x7009e864 {
        stderr.write(Data(String(format: "[llb5] BOOTVOLCHK x0=0x%llX at instr %lld\n", cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x7009e874 {
        stderr.write(Data("[llb5] BOOTVOL-MISSING-ERR at instr \(cpu.instructionsExecuted)\n".utf8))
    }
    if pc == 0x70091624 || pc == 0x70091710 {
        stderr.write(Data(String(format: "[llb5] PROMOTE fn pc=0x%llX at instr %lld\n", pc, cpu.instructionsExecuted).utf8))
    }
    if pc == 0x104514 {  // trampoline の hvc 直前: FID を記録
        stderr.write(Data(String(format: "[romboot] HVC fid=0x%llX x1=0x%llX at instr %lld\n",
                                 cpu.registers[0], cpu.registers[1], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x104518 {  // hvc 直後: 戻り値
        stderr.write(Data(String(format: "[romboot] HVC ret x0=0x%llX at instr %lld\n",
                                 cpu.registers[0], cpu.instructionsExecuted).utf8))
    }
    if pc == 0x100448 && !parkDumped {
        parkDumped = true
        stderr.write(Data("[romboot] PARK2 at instr \(cpu.instructionsExecuted), path: \(pcRing.map { "0x" + String($0, radix: 16) }.joined(separator: " "))\n".utf8))
        stderr.write(Data("[romboot] park2 regs: \(cpu.registers.enumerated().map { "x\($0.offset)=0x" + String($0.element, radix: 16) }.joined(separator: " "))\n".utf8))
    }
    if pc == 0x109204 && !parkDumped {
        parkDumped = true
        stderr.write(Data("[romboot] PARK at instr \(cpu.instructionsExecuted), path: \(pcRing.map { "0x" + String($0, radix: 16) }.joined(separator: " "))\n".utf8))
        stderr.write(Data(String(format: "[romboot] park pstate=0x%llX daif=0x%llX\n", cpu.pstate, (cpu.pstate >> 6) & 0xF).utf8))
    }
}
c.onVusbEvent = { msg in
    stderr.write(Data("[romboot] vusb \(msg)\n".utf8))
}
c.onSysRegAccess = { isRead, key, value, pc in
    if !isRead && [0x6040, 0x6080, 0x6082, 0x6290].contains(key) {
        let name = [0x6040: "SCTLR", 0x6080: "TTBR0", 0x6082: "TCR", 0x6290: "MAIR"][key]!
        stderr.write(Data(String(format: "[romboot] SYSREG %@ <- 0x%llX at pc=0x%llX instr %lld\n", name, value, pc, cpu.instructionsExecuted).utf8))
    }
}
c.onException = { vector, esr, elr in
    excCount += 1
    if excCount <= 20 {
        stderr.write(Data(String(format: "[romboot] exc #%d at instr %lld vector=0x%llX esr=0x%llX elr=0x%llX\n",
                                 excCount, cpu.instructionsExecuted, vector, esr, elr).utf8))
    }
}
}
installHooks(cpu)
bridgeSetup()
var lastPC: UInt64 = 0
var samePCCount = 0
var lastLogScan: UInt64 = 0
// [stalldiag] idle 忍耐用の状態
var lastProgressInstr: UInt64 = 0
var idleEpisodeStart: Date? = nil
var idlePrintLast = Date()
let wallStart = Date()
var lastStatusInstr: UInt64 = UInt64.max
// インストーラ時: Henge host/usb_host.c の probe 相当（online→reset→GET_DESCRIPTOR）を内蔵で試す
var probeStage = 0
var probeWasOnline = false
var reboots = 0
var leftROM = false
// [idlediag] park 相のエピソード数・DRAM ダンプ管理
var idlediagEpisodes = 0
var idlediagInEpisode = false
var idlediagDumped1 = false
var idlediagDumped2 = false
func idlediagDumpDRAM(_ cpu: ARM64CPU, _ name: String) {
    let path = (ProcessInfo.processInfo.environment["HOME"] ?? ".") + "/" + name
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: path) else {
        stderr.write(Data("[idlediag] DRAM dump open failed: \(path)\n".utf8))
        return
    }
    let chunk = 64 * 1024 * 1024
    var off = 0
    while off < cpu.memory.count {
        let end = min(off + chunk, cpu.memory.count)
        fh.write(Data(cpu.memory[off..<end]))
        off = end
    }
    try? fh.close()
    stderr.write(Data("[idlediag] DRAM dumped to \(path) (\(cpu.memory.count) bytes) at instr \(cpu.instructionsExecuted)\n".utf8))
    stderr.write(Data("[idlediag] GIC at dump:\n\(cpu.diagGICSummary())\n".utf8))
}
var spentInstr: UInt64 = 0
let totalBudget = UInt64(maxM) * 1_000_000
outer: while spentInstr + cpu.instructionsExecuted < totalBudget {
    while !cpu.halted && spentInstr + cpu.instructionsExecuted < totalBudget {
        do {
            try cpu.run(maxInstructions: installer ? (bridgePath != nil ? 2_000 : 200_000) : 10_000_000)
        } catch {
            stderr.write(Data("[romboot] fault: \(error) at instr \(cpu.instructionsExecuted) pc=0x\(String(cpu.pc, radix: 16))\n".utf8))
            break outer
        }
        if installer {
            cpu.pollVMAppleDevices()
            bridgeService()
            let online = cpu.vusbOnline
            if online != probeWasOnline {
                stderr.write(Data("[romboot] vusb online=\(online) session=\(cpu.vusbSession) at instr \(cpu.instructionsExecuted)\n".utf8))
                probeWasOnline = online
            }
            if online && probeStage == 0 && bridgePath == nil && ProcessInfo.processInfo.environment["NORESET"] == nil {
                _ = cpu.vusbSendRequest(type: 2, ep: 0, data: nil, len: 0)   // REQ_RESET
                probeStage = 1
                stderr.write(Data("[romboot] probe: sent RESET\n".utf8))
            }
            if online && probeStage == 15 {
                // リセット後は RSP_RESET を待たず GET_DESCRIPTOR から続行する
                _ = cpu.vusbSendRequest(type: 1, ep: 0, data: [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00], len: 8)
                probeStage = 2
                stderr.write(Data("[romboot] probe: sent GET_DESCRIPTOR setup (post-reset)\n".utf8))
            }
            while let rsp = cpu.vusbTakeResponse() {
                stderr.write(Data("[romboot] vusb RSP type=\(rsp.type) ep=0x\(String(rsp.ep, radix: 16)) len=\(rsp.len) data=\((rsp.data ?? []).map { String(format: "%02x", $0) }.joined(separator: " "))\n".utf8))
                if probeStage == 1 && rsp.type == 4 {
                    // GET_DESCRIPTOR (device, 18 bytes): setup packet 80 06 00 01 00 00 12 00
                    _ = cpu.vusbSendRequest(type: 1, ep: 0, data: [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00], len: 8)
                    probeStage = 2
                    stderr.write(Data("[romboot] probe: sent GET_DESCRIPTOR setup\n".utf8))
                } else if probeStage == 2 && rsp.type == 1 {
                    probeStage = 3
                    stderr.write(Data("[romboot] probe: DEVICE DESCRIPTOR OK\n".utf8))
                }
            }
        }
        if installer && !leftROM && !(cpu.pc >= 0x100000 && cpu.pc < 0x200000) {
            leftROM = true
            stderr.write(Data("[romboot] PC LEFT ROM WINDOW: pc=0x\(String(cpu.pc, radix: 16)) el=\(cpu.currentEL) at instr \(spentInstr + cpu.instructionsExecuted)\n".utf8))
        }
        if cpu.pc == lastPC { samePCCount += 1 } else { samePCCount = 0; lastPC = cpu.pc }
        let totalNow = spentInstr + cpu.instructionsExecuted
        if totalNow != lastStatusInstr {
            lastStatusInstr = totalNow
            stderr.write(Data(String(format: "[romboot] instr=%lld pc=0x%llX el=%d samePC=%d\n",
                                     cpu.instructionsExecuted, cpu.pc, cpu.currentEL, samePCCount).utf8))
        }
        // [stalldiag] idle 忍耐: 進展がなければ wall-clock で待ち、起床を観測する
        if totalNow > lastProgressInstr {
            lastProgressInstr = totalNow
            idleEpisodeStart = nil
            idlediagInEpisode = false
        } else if !cpu.halted {
            // [idlediag] park 相のエピソード開始を数え、節目で DRAM ダンプと
            // GIC 状態を採取する。park は軌道で大きくずれるため、絶対命令数でなく
            // 「3.0B 超 + カーネル空間 PC」で判定し、ダンプは表示初期化通過
            // （固定小数点 FCVT 実行）以降に限る（フォールバック: 60 回）。
            if !idlediagInEpisode {
                idlediagInEpisode = true
                if totalNow > 3_000_000_000 && cpu.pc >= 0xFFFFFE0000000000 {
                    idlediagEpisodes += 1
                    if idlediagEpisodes == 1 || idlediagEpisodes % 25 == 0 {
                        stderr.write(Data("[idlediag] park episode #\(idlediagEpisodes) at instr \(totalNow) fcvtHits=\(cpu.diagFcvtHits)\n[idlediag] GIC:\n\(cpu.diagGICSummary())\n".utf8))
                    }
                    if idlediagEpisodes >= 12 && !idlediagDumped1 && (cpu.diagFcvtHits > 0 || idlediagEpisodes >= 60) {
                        idlediagDumped1 = true
                        idlediagDumpDRAM(cpu, "dram_idlediag1.bin")
                    }
                    if idlediagEpisodes >= 80 && !idlediagDumped2 && idlediagDumped1 {
                        idlediagDumped2 = true
                        idlediagDumpDRAM(cpu, "dram_idlediag2.bin")
                    }
                }
            }
            if idleEpisodeStart == nil { idleEpisodeStart = Date() }
            let ep = Date().timeIntervalSince(idleEpisodeStart!)
            cpu.pollVMAppleDevices()
            if Date().timeIntervalSince(idlePrintLast) > 2 {
                idlePrintLast = Date()
                stderr.write(Data("[stalldiag] idle episode \(Int(ep))s at instr \(totalNow) pc=0x\(String(cpu.pc, radix: 16))\n".utf8))
            }
            if ep > 300 {
                stderr.write(Data("[stalldiag] idle episode exceeded 300s, stop\n".utf8))
                scanPanicLog(cpu.memory, tag: "idlestop")
                break outer
            }
            usleep(50_000)
        }
        if Date().timeIntervalSince(wallStart) > 4.5 * 3600 {
            stderr.write(Data("[stalldiag] wall cap reached, stop\n".utf8))
            scanPanicLog(cpu.memory, tag: "wallcap")
            break outer
        }
        if installer && (spentInstr + cpu.instructionsExecuted) - lastLogScan >= 50_000_000 {
            lastLogScan = spentInstr + cpu.instructionsExecuted
            scanGuestLog(cpu.memory, tag: "glog")
        }
    }
    // ゲストが PSCI SYSTEM_RESET を要求したら再起動して続ける（インストーラ時のみ）。
    // [stalldiag] 非インストーラ時は再起動せず、最初の halt で状態を保全して止める。
    if installer && cpu.halted && cpu.exitCode == 0x5253_5431 && reboots < 64 {
        spentInstr += cpu.instructionsExecuted
        reboots += 1
        if bridgeOnline {
            bridgeSession &+= 1
            bridgeOnline = false
            bridgeSendState()
        }
        stderr.write(Data("[romboot] guest reset #\(reboots), rebooting (spent=\(spentInstr))\n".utf8))
        if probeStage == 1 { probeStage = 15 }
        probeWasOnline = false
        rebootCPU()
        continue outer
    }
    break outer
}
if !outBuffer.isEmpty { FileHandle.standardOutput.write(Data(outBuffer)) }
stderr.write(Data(String(format: "[romboot] done instr=%lld pc=0x%llX halted=%@ exit=0x%llX\n",
                         cpu.instructionsExecuted, cpu.pc, cpu.halted ? "yes" : "no",
                         UInt64(bitPattern: Int64(cpu.exitCode))).utf8))
scanPanicLog(cpu.memory, tag: "final")
let unk = cpu.unknownMMIOAccesses
if !unk.isEmpty {
    stderr.write(Data("[romboot] unknownMMIO: \(unk.map { "0x" + String($0, radix: 16) }.joined(separator: " "))\n".utf8))
}
stderr.write(Data("[romboot] lastPCs: \(pcRing.map { "0x" + String($0, radix: 16) }.joined(separator: " "))\n".utf8))
stderr.write(Data("[romboot] regs: \(cpu.registers.enumerated().map { "x\($0.offset)=0x" + String($0.element, radix: 16) }.joined(separator: " "))\n".utf8))
stderr.write(Data(String(format: "[romboot] spEL1=0x%llX spEL2=0x%llX excTotal=%d\n", cpu.spEL1, cpu.spEL2, excCount).utf8))
// 低位 RAM 全域を走査し、印字可能な文字列をアドレス付きでダンプ（ROM のログバッファ回収）
var cur: [UInt8] = []
var curStart = 0
for i in 0..<min(cpu.memory.count, 0x1000000) {
    let b = cpu.memory[i]
    if (b >= 0x20 && b < 0x7F) || b == 0x0A {
        if cur.isEmpty { curStart = i }
        cur.append(b)
    } else {
        if cur.count >= 4 {
            let s = String(bytes: cur, encoding: .ascii)!.replacingOccurrences(of: "\n", with: "\\n")
            stderr.write(Data("[romboot] ramstr @0x\(String(0x70000000 + curStart, radix: 16)): \(s)\n".utf8))
        }
        cur.removeAll()
    }
}
