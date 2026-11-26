import Foundation
import Glibc

// usage: h_xnu <kernelcache.macho> <devicetree.bin> [memMB] [maxInstrMillions] [bootargs]
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: h_xnu <kc> <dt> [memMB] [maxM] [bootargs]"); exit(2) }
let kc = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let dt = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[2])))
let memMB = args.count > 3 ? Int(args[3])! : 2048
let maxM = args.count > 4 ? Int(args[4])! : 200
let bootArgs = args.count > 5 ? args[5] : "-v serial=3"
let panicVA: UInt64 = args.count > 6 ? (UInt64(args[6], radix: 16) ?? 0xFFFFFE000848B2B4) : 0xFFFFFE000848B2B4
let haltVA: UInt64 = args.count > 7 ? (UInt64(args[7], radix: 16) ?? 0) : 0
var haltCalls = 0

let cpu = ARM64CPU(memorySize: memMB * 1024 * 1024)
do {
    let info = try VMAppleBoot.prepare(cpu: cpu, kernelcache: kc, deviceTree: dt, commandLine: bootArgs)
    print(String(format: "[boot] entry=0x%llX bootArgs=0x%llX adt=0x%llX topKD=0x%llX gicD=0x%llX gicR=0x%llX uart=0x%llX",
                 info.entryPA, info.bootArgsPA, info.deviceTreePA, info.topOfKernelData,
                 info.gicDistPA, info.gicRedistPA, info.uartPA))
} catch {
    print("[boot] FAILED:", error)
    exit(1)
}
var outBuffer: [UInt8] = []
cpu.onChar = { byte in
    outBuffer.append(byte)
    if byte == 0x0A || outBuffer.count >= 4096 {
        FileHandle.standardOutput.write(Data(outBuffer))
        outBuffer.removeAll()
    }
}
var trace: [String] = []
var fetchWords: [UInt64: UInt32] = [:]
var fetchRing: [(UInt64, UInt32)] = []
var panicDumped = false
var panicCalls = 0
var vfCalls = 0
var vfRets = 0
var peCalls = 0
var vfReturns = Set<UInt64>()
var undefDumpCount = 0
var fipsLogCalls = 0
var sha3regT = [Int](repeating: 0, count: 8)
var sha3regW = [Int](repeating: 0, count: 8)
var sha2regT = [Int](repeating: 0, count: 8)
var sha2regW = [Int](repeating: 0, count: 8)
var sha512T = 0
var sha512W = 0
var aesT = 0
var aesW = 0
var fipsCalls = 0
var abortCalls = 0
var pathCalls = 0
var signCalls = 0
var verifyCalls = 0
func imageString(_ va: UInt64) -> String? {
    let base: UInt64 = 0xFFFFFE0007004000
    guard va >= base && va < base + UInt64(kc.count) else { return nil }
    var bytes: [UInt8] = []
    var i = Int(va - base)
    while i < kc.count && kc[i] != 0 && bytes.count < 300 {
        let b = kc[i]
        guard b == 10 || (b >= 32 && b < 127) else { return nil }
        bytes.append(b)
        i += 1
    }
    guard bytes.count >= 4 else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}
func dumpGuestString(_ va: UInt64) -> String? {
    guard let pa = cpu.debugTranslate(va) else { return nil }
    let off = Int(pa - cpu.ramBaseAddress)
    guard off >= 0 && off < cpu.memory.count else { return nil }
    var bytes: [UInt8] = []
    var i = off
    while i < cpu.memory.count && cpu.memory[i] != 0 && bytes.count < 200 {
        let b = cpu.memory[i]
        guard b == 10 || (b >= 32 && b < 127) else { return nil }
        bytes.append(b)
        i += 1
    }
    guard bytes.count >= 4 else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}
var dtInitCalls = 0
var dtFindCalls = 0
var lockEvents = 0
var orderSeen = Set<UInt64>()
let orderWatch: [UInt64: String] = [
    0xFFFFFE000845620C: "dt-init entry",
    0xFFFFFE0007C40C88: "set_ttbr0 helper",
    0xFFFFFE0007C40C78: "set_ttbr1 helper",
    0xFFFFFE0008453990: "dt-find entry",
]
cpu.onFetch = { pc, insn in
    if let label = orderWatch[pc], !orderSeen.contains(pc) {
        orderSeen.insert(pc)
        stderr.write(Data(String(format: "[order] %@ at instr %lld x0=0x%llX\n", label, cpu.instructionsExecuted, cpu.registers[0]).utf8))
    }
    if pc == 0xFFFFFE000845620C {
        dtInitCalls += 1
        if dtInitCalls <= 20 {
            stderr.write(Data(String(format: "[dtinit] call #%d at instr %lld x0=0x%llX x1=0x%llX lr=0x%llX\n", dtInitCalls, cpu.instructionsExecuted, cpu.registers[0], cpu.registers[1], cpu.registers[30]).utf8))
        }
    }
    if pc == 0xFFFFFE0007C40C88 || pc == 0xFFFFFE0007C40C78 {
        stderr.write(Data(String(format: "[setttbr] %@ at instr %lld x0=0x%llX lr=0x%llX\n", pc == 0xFFFFFE0007C40C88 ? "ttbr0" : "ttbr1", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[30]).utf8))
    }
    if pc == 0xFFFFFE0007DB6CF4 {
        stderr.write(Data(String(format: "[defaults] entry at instr %lld lr=0x%llX\n", cpu.instructionsExecuted, cpu.registers[30]).utf8))
    }
    if pc == 0xFFFFFE0007CA5754 || pc == 0xFFFFFE0007CA5160 || pc == 0xFFFFFE0007CA5194 {
        let ptr = pc == 0xFFFFFE0007CA5754 ? cpu.registers[1] : cpu.registers[8]
        if ptr == 0xFFFFFE000A2D4ECC && lockEvents < 80 {
            lockEvents += 1
            var w: UInt64 = 0
            for b in 0..<4 { w |= UInt64(cpu.readGuestMemory(address: 0x8042D4ECC + UInt64(b), size: 1)) << (b * 8) }
            var own: UInt64 = 0
            for b in 0..<8 { own |= UInt64(cpu.readGuestMemory(address: 0x8042D4ED0 + UInt64(b), size: 1)) << (b * 8) }
            let site = pc == 0xFFFFFE0007CA5754 ? "ldadda-A" : (pc == 0xFFFFFE0007CA5160 ? "ldadda-B" : "stlrb-unlock")
            stderr.write(Data(String(format: "[lockev] #%d instr %lld %@ word=0x%08llX owner=0x%llX lr=0x%llX\n", lockEvents, cpu.instructionsExecuted, site, w, own, cpu.registers[30]).utf8))
        }
    }
    if pc == 0xFFFFFE0007CA5D1C || pc == 0xFFFFFE0007CA5778 {
        let obj = pc == 0xFFFFFE0007CA5D1C ? cpu.registers[0] : 0xFFFFFE000A2D4EC4
        if obj == 0xFFFFFE000A2D4EC4 && lockEvents < 120 {
            lockEvents += 1
            var w: UInt64 = 0
            for b in 0..<4 { w |= UInt64(cpu.readGuestMemory(address: 0x8042D4ECC + UInt64(b), size: 1)) << (b * 8) }
            var own: UInt64 = 0
            for b in 0..<8 { own |= UInt64(cpu.readGuestMemory(address: 0x8042D4ED0 + UInt64(b), size: 1)) << (b * 8) }
            let site = pc == 0xFFFFFE0007CA5D1C ? "UNLOCK-entry" : "ACQUIRE-done"
            stderr.write(Data(String(format: "[lockev] #%d instr %lld %@ word=0x%08llX owner=0x%llX lr=0x%llX\n", lockEvents, cpu.instructionsExecuted, site, w, own, cpu.registers[30]).utf8))
        }
    }
    if pc == 0xFFFFFE0007DCA10C {
        stderr.write(Data(String(format: "[pmapboot] entry at instr %lld lr=0x%llX\n", cpu.instructionsExecuted, cpu.registers[30]).utf8))
    }
    if pc == 0xFFFFFE0008453990 {
        dtFindCalls += 1
        if dtFindCalls <= 30 {
            stderr.write(Data(String(format: "[dtfind] call #%d at instr %lld x0=0x%llX lr=0x%llX\n", dtFindCalls, cpu.instructionsExecuted, cpu.registers[0], cpu.registers[30]).utf8))
        }
    }
    fetchWords[pc] = insn
    fetchRing.append((pc, insn))
    let inWin = cpu.instructionsExecuted >= 420_000_000
    if (insn & 0xFF20_8C00) == 0x5E00_0000 {
        let op = Int((insn >> 12) & 7)
        sha3regT[op] += 1
        if inWin { sha3regW[op] += 1 }
    } else if (insn & 0xFF20_8C00) == 0x5E20_0800 {
        let op = Int((insn >> 12) & 7)
        sha2regT[op] += 1
        if inWin { sha2regW[op] += 1 }
    } else if (insn & 0xFFE0_F000) == 0xCE60_8000 || (insn & 0xFFE0_FC00) == 0xCEC0_8000 {
        sha512T += 1
        if inWin { sha512W += 1 }
    } else if (insn & 0xFFFF_8C00) == 0x4E28_0800 {
        aesT += 1
        if inWin { aesW += 1 }
    }
    if fetchRing.count > 4096 { fetchRing.removeFirst(2048) }
    pollCounter += 1
    let n = cpu.instructionsExecuted
    let pollInterval = (n > 31781550 && n < 31782000) ? 8 : (n > 31700000 ? 512 : 8192)
    if pollCounter >= pollInterval {
        pollCounter = 0
        let e = cpu.readGuestMemory(address: 0x8050EC000 + 0x3F00, size: 8)
        if e != rawWatchedEntry {
            stderr.write(Data(String(format: "[rawwatch] entry 0x%llX -> 0x%llX at instr ~%lld pc=0x%llX\n", rawWatchedEntry, e, cpu.instructionsExecuted, pc).utf8))
            for (fpc, finsn) in fetchRing.suffix(80) {
                stderr.write(Data(String(format: "  fetch 0x%llX: 0x%08X\n", fpc, finsn).utf8))
            }
            rawWatchedEntry = e
        }
    }
    if (pc == 0xFFFFFE0007DC8E98 || pc == 0xFFFFFE0007DC90F4) && !phystokvDumped {
        phystokvDumped = true
        stderr.write(Data(String(format: "[phystokv-panic] site=0x%llX lr=0x%llX\n", pc, cpu.registers[30]).utf8))
        if let spPA = cpu.debugTranslate(cpu.currentSP) {
            for o in stride(from: 0, to: 0x30, by: 8) {
                let v = cpu.readGuestMemory(address: spPA + UInt64(o), size: 8)
                stderr.write(Data(String(format: "  [sp+0x%llX] = 0x%llX\n", UInt64(o), v).utf8))
            }
        }
        for (fpc, finsn) in fetchRing.suffix(60) {
            stderr.write(Data(String(format: "  fetch 0x%llX: 0x%08X\n", fpc, finsn).utf8))
        }
    }
    // panic() 本体への突入を記録する（最初の数回のみ）
    if pc == 0xFFFFFE0007C3CE90 && pathCalls < 4 {
        pathCalls += 1
        stderr.write(Data(String(format: "[path] FAST handler instr=%lld\n", cpu.instructionsExecuted).utf8))
    }
    if pc == 0xFFFFFE0007C3CD08 && pathCalls < 4 {
        pathCalls += 1
        stderr.write(Data(String(format: "[path] GENERIC shim instr=%lld\n", cpu.instructionsExecuted).utf8))
    }
    if pc == 0xFFFFFE0007DD16B0 && pathCalls < 4 {
        pathCalls += 1
        stderr.write(Data(String(format: "[path] STACKCHECK instr=%lld\n", cpu.instructionsExecuted).utf8))
    }
    if pc == 0xFFFFFE0007C410E8 && signCalls < 6 {
        signCalls += 1
        stderr.write(Data(String(format: "[sign] instr=%lld frame=0x%llX elr=0x%llX spsr=0x%llX lr=0x%llX x4=0x%llX x5=0x%llX\n", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[4], cpu.registers[5]).utf8))
    }
    if pc == 0xFFFFFE0007C41110 && verifyCalls < 6 {
        verifyCalls += 1
        var stored: UInt64 = 0xDEAD
        if let pa = cpu.debugTranslate(cpu.registers[0] + 0x128) { stored = cpu.readGuestMemory(address: pa, size: 8) }
        stderr.write(Data(String(format: "[verify] instr=%lld frame=0x%llX elr=0x%llX spsr=0x%llX lr=0x%llX x4=0x%llX x5=0x%llX stored=0x%llX\n", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[4], cpu.registers[5], stored).utf8))
    }
    if pc == 0xFFFFFE0008456B6C && fipsLogCalls < 300 {
        if let s = imageString(cpu.registers[0]) ?? dumpGuestString(cpu.registers[0]), s.contains("FIPSPOST") || s.contains("fipspost") {
            fipsLogCalls += 1
            let a0 = Int64(bitPattern: readVA64(cpu.currentSP) ?? 0)
            let a1 = Int64(bitPattern: readVA64(cpu.currentSP + 8) ?? 0)
            stderr.write(Data(String(format: "[fipslog] instr=%lld a0=%lld a1=%lld | %@\n", cpu.instructionsExecuted, a0, a1, s.trimmingCharacters(in: .newlines)).utf8))
        }
    }
    if pc == 0xFFFFFE0009DFF808 && fipsCalls < 3 {
        fipsCalls += 1
        let ring = fetchRing.suffix(48).map { String(format: "%llX", $0.0) }.joined(separator: " ")
        stderr.write(Data(String(format: "[fipsfail] instr=%lld code=0x%llX (%lld) x1=%llX x2=%llX x3=%llX x19=%llX x20=%llX ring=%@\n", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[19], cpu.registers[20], ring).utf8))
    }
    if pc == 0xFFFFFE0009DF70CC && abortCalls < 6 {
        abortCalls += 1
        stderr.write(Data(String(format: "[ccabort] instr=%lld what=%@\n", cpu.instructionsExecuted, (imageString(cpu.registers[0]) ?? dumpGuestString(cpu.registers[0]) ?? "?")).utf8))
    }
    if pc == 0xFFFFFE0007D396C0 && vfCalls < 30 {
        vfCalls += 1
        vfReturns.insert(cpu.registers[30])
        stderr.write(Data(String(format: "[vfault] instr=%lld map=0x%llX addr=0x%llX prot=0x%llX x3=0x%llX lr=0x%llX\n", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[30]).utf8))
    }
    if vfReturns.contains(pc) && vfRets < 30 {
        vfRets += 1
        stderr.write(Data(String(format: "[vfret] instr=%lld ret=0x%llX\n", cpu.instructionsExecuted, cpu.registers[0]).utf8))
    }
    if pc == 0xFFFFFE0008495B80 && peCalls < 4 {
        peCalls += 1
        let t = dumpGuestString(cpu.registers[0]) ?? "<unreadable>"
        stderr.write(Data(String(format: "[pereport] instr=%lld type=%s frame=0x%llX\n", cpu.instructionsExecuted, t, cpu.registers[1]).utf8))
    }
    if pc == panicVA && panicCalls < 6 {
        panicCalls += 1
        let fmt = imageString(cpu.registers[0]) ?? dumpGuestString(cpu.registers[0]) ?? "<unreadable>"
        stderr.write(Data(String(format: "[panic #%d] instr=%lld lr=0x%llX fmt=%s x1=0x%llX x2=0x%llX x3=0x%llX x4=0x%llX x5=0x%llX x6=0x%llX x7=0x%llX\n", panicCalls, cpu.instructionsExecuted, cpu.registers[30], fmt, cpu.registers[1], cpu.registers[2], cpu.registers[3], cpu.registers[4], cpu.registers[5], cpu.registers[6], cpu.registers[7]).utf8))
        var pregLine = "[pregs]"
        for r in 19...29 { pregLine += String(format: " x%d=0x%llX", r, cpu.registers[r]) }
        pregLine += String(format: " sp=0x%llX", cpu.currentSP)
        stderr.write(Data((pregLine + "\n").utf8))
        var fpv = cpu.registers[29]
        var chainStr = "[pchain]"
        func rdq(_ va: UInt64) -> UInt64 {
            let pa = va &- 0xFFFFFE0006000000 &+ 0x70000000
            var v: UInt64 = 0
            for b in 0..<8 { v |= cpu.readGuestMemory(address: pa + UInt64(b), size: 1) << (b * 8) }
            return v
        }
        for _ in 0..<12 {
            if fpv == 0 { break }
            let sfp = rdq(fpv); let slr = rdq(fpv + 8)
            chainStr += String(format: " lr=0x%llX", slr)
            if sfp <= fpv { break }
            fpv = sfp
        }
        stderr.write(Data((chainStr + "\n").utf8))
        var entLine = "[entry]"
        let e3 = cpu.registers[3]
        for off in [0x0, 0x8, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38] {
            entLine += String(format: " +0x%X=0x%llX", off, rdq(e3 + UInt64(off)))
        }
        stderr.write(Data((entLine + "\n").utf8))
        var mapLine = "[map]"
        let m0 = cpu.registers[0]
        for off in [0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x68] {
            mapLine += String(format: " +0x%X=0x%llX", off, rdq(m0 + UInt64(off)))
        }
        stderr.write(Data((mapLine + "\n").utf8))
        // 衝突エントリの前後をリンクリストでたどり、kernel_map の配置を出す
        if cpu.registers.count > 3 {
            var lines: [String] = []
            var cur: UInt64? = cpu.registers[3]
            var back: [(UInt64, UInt64)] = []
            var hops = 0
            while let e = cur, hops < 14, e > 0xFFFFFE0000000000 {
                let s = rdq(e + 0x10), en = rdq(e + 0x18)
                if en <= s { break }
                back.append((s, en))
                cur = rdq(e + 0x0)
                hops += 1
            }
            for (s, en) in back.reversed() { lines.append(String(format: "[walk] - [%llX,%llX)", s, en)) }
            cur = cpu.registers[3]
            hops = 0
            while let e = cur, hops < 14, e > 0xFFFFFE0000000000 {
                let s = rdq(e + 0x10), en = rdq(e + 0x18)
                if en <= s { break }
                if hops > 0 { lines.append(String(format: "[walk] + [%llX,%llX)", s, en)) }
                cur = rdq(e + 0x8)
                hops += 1
            }
            for l in lines { stderr.write(Data((l + "\n").utf8)) }
        }
    }
    if haltVA != 0 && pc == haltVA && haltCalls < 4 {
        haltCalls += 1
        stderr.write(Data(String(format: "[halt] instr=%lld w0=0x%llX lr=0x%llX\n", cpu.instructionsExecuted, cpu.registers[0], cpu.registers[30]).utf8))
    }
    if pc >= 0xFFFFFE0007C87000 && pc < 0xFFFFFE0007C89000 && !panicDumped {
        panicDumped = true
        stderr.write(Data(String(format: "[panicfmt] reached site pc=0x%llX\n", pc).utf8))
        for i in 0..<31 {
            let v = cpu.registers[i]
            stderr.write(Data(String(format: "  x%d=0x%llX", i, v).utf8))
            if let s = dumpGuestString(v) {
                stderr.write(Data("  str=\"\(s)\"".utf8))
            }
            stderr.write(Data("\n".utf8))
        }
        // x20 が指す saved state をダンプする
        let ssVA = cpu.registers[20]
        if let ssPA = cpu.debugTranslate(ssVA) {
            stderr.write(Data(String(format: "[savedstate] at VA 0x%llX PA 0x%llX\n", ssVA, ssPA).utf8))
            for o in stride(from: 0, to: 0x140, by: 8) {
                let v = cpu.readGuestMemory(address: ssPA + UInt64(o), size: 8)
                stderr.write(Data(String(format: "  +0x%llX: 0x%llX\n", UInt64(o), v).utf8))
            }
        }
        for (fpc, finsn) in fetchRing.suffix(300) {
            stderr.write(Data(String(format: "  fetch 0x%llX: 0x%08X\n", fpc, finsn).utf8))
        }
    }
}
var phystokvDumped = false
var pollCounter = 0
var rawWatchedEntry: UInt64 = 0
var watchedTablePtr: UInt64 = 0
var watchedEntry: UInt64 = 0
var walkDumped = false
var ec0Info: [(UInt64, UInt32)] = []
var esrHistogram: [UInt64: Int] = [:]
var elrHistogram: [UInt64: Int] = [:]
var ec0Dumped = false
var v0Dumped = false
var fullEsrHistogram: [UInt64: Int] = [:]
var abortDumped = false
var iabortDumped = false
var dabortDumped = false
cpu.onException = { vector, esr, elr in
    let ec0 = (esr >> 26) & 0x3F
    if ec0 == 0 && undefDumpCount < 8 {
        undefDumpCount += 1
        var word: UInt32 = 0
        if let pa = cpu.debugTranslate(elr) { word = UInt32(cpu.readGuestMemory(address: pa, size: 4)) }
        let ringTail = fetchRing.suffix(3).map { String(format: "(0x%llX,0x%08X)", $0.0, $0.1) }.joined(separator: " ")
        stderr.write(Data(String(format: "[undef] instr=%lld elr=0x%llX esr=0x%llX word=0x%08X ring=%@\n", cpu.instructionsExecuted, elr, esr, word, ringTail).utf8))
    }

    let ec = esr >> 26
    if (ec == 0x25 || ec == 0x24) && !dabortDumped {
        dabortDumped = true
        stderr.write(Data(String(format: "[dabort] instr=%lld vector=0x%llX esr=0x%llX elr=0x%llX far=0x%llX sp=0x%llX el=%d\n", cpu.instructionsExecuted, vector, esr, elr, cpu.farEL1, cpu.currentSP, cpu.currentEL).utf8))
        for i in 0..<31 {
            stderr.write(Data(String(format: "  x%d=0x%llX\n", i, cpu.registers[i]).utf8))
        }
        for (pc, insn) in fetchRing.suffix(40) {
            stderr.write(Data(String(format: "  fetch 0x%llX: 0x%08X\n", pc, insn).utf8))
        }
        // Walk the fault VA through the current tables (16K granule layout).
        let fva = cpu.farEL1
        let ttbr = (fva & 0xFFFF_0000_0000_0000) != 0 ? cpu.ttbr1EL1 : cpu.ttbr0EL1
        func rd8(_ pa: UInt64) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= cpu.readGuestMemory(address: pa + UInt64(i), size: 1) << (i * 8) }
            return v
        }
        let i1 = (fva >> 36) & 0x7FF
        let i2 = (fva >> 25) & 0x7FF
        let i3 = (fva >> 14) & 0x7FF
        let d1 = rd8((ttbr & 0x0000_FFFF_FFFF_C000) + i1 * 8)
        stderr.write(Data(String(format: "[dwalk] ttbr=0x%llX L1[%lld]=0x%llX\n", ttbr, i1, d1).utf8))
        if d1 & 0x3 == 0x3 {
            let d2 = rd8((d1 & 0x0000_FFFF_FFFF_C000) + i2 * 8)
            stderr.write(Data(String(format: "[dwalk] L2[%lld]=0x%llX\n", i2, d2).utf8))
            if d2 & 0x3 == 0x3 {
                let l3base = d2 & 0x0000_FFFF_FFFF_C000
                var line = ""
                var k = max(0, Int(i3) - 2)
                while k <= min(2047, Int(i3) + 2) {
                    line += String(format: " [%d]=0x%llX", k, rd8(l3base + UInt64(k) * 8))
                    k += 1
                }
                stderr.write(Data(("[dwalk] L3 base=0x" + String(l3base, radix: 16) + line + "\n").utf8))
            }
        }
    }
    if (esr >> 26) == 0x21 && !iabortDumped {
        iabortDumped = true
        stderr.write(Data(String(format: "[iabort] vector=0x%llX esr=0x%llX elr=0x%llX sp=0x%llX el=%d\n", vector, esr, elr, cpu.currentSP, cpu.currentEL).utf8))
        for i in 0..<31 {
            stderr.write(Data(String(format: "  x%d=0x%llX\n", i, cpu.registers[i]).utf8))
        }
        let x29 = cpu.registers[29]
        if x29 > 0x60, let pa = cpu.debugTranslate(x29 - 0x60) {
            let v = cpu.readGuestMemory(address: pa, size: 8)
            stderr.write(Data(String(format: "  [x29-0x60] va=0x%llX pa=0x%llX value=0x%llX\n", x29 - 0x60, pa, v).utf8))
        }
        for (pc, insn) in fetchRing.suffix(30) {
            stderr.write(Data(String(format: "  fetch 0x%llX: 0x%08X\n", pc, insn).utf8))
        }
    }
    if vector == 0x200 {
        esrHistogram[esr >> 26, default: 0] += 1
        elrHistogram[elr, default: 0] += 1
    }
    fullEsrHistogram[(UInt64(vector) << 32) | (esr & 0xFFFF_FFFF), default: 0] += 1
    if vector == 0 && !v0Dumped {
        v0Dumped = true
        stderr.write(Data(String(format: "[v0] first SP0 sync: esr=0x%llX elr=0x%llX\n", esr, elr).utf8))
        for (pc, insn) in fetchRing.suffix(40) {
            stderr.write(Data(String(format: "  0x%llX: 0x%08X\n", pc, insn).utf8))
        }
    }
    if vector == 0x200 && (esr >> 26) == 0x25 && elr == 0xFFFFFE0006C96E84 && !abortDumped {
        abortDumped = true
        stderr.write(Data("[aborttrace] fetches before first data abort:\n".utf8))
        for (pc, insn) in fetchRing.suffix(100) {
            stderr.write(Data(String(format: "  0x%llX: 0x%08X\n", pc, insn).utf8))
        }
    }
    if vector == 0x200 && (esr >> 26) == 0 {
        if ec0Info.count < 8 { ec0Info.append((elr, fetchWords[elr] ?? 0)) }
        if !ec0Dumped {
            ec0Dumped = true
            stderr.write(Data("[fetchtrace] last fetches before first EC0:\n".utf8))
            for (pc, insn) in fetchRing.suffix(120) {
                stderr.write(Data(String(format: "  0x%llX: 0x%08X\n", pc, insn).utf8))
            }
        }
    }
}
cpu.onSysRegAccess = { isRead, key, value, pc in
    trace.append(String(format: "%@ key=0x%04X value=0x%llX pc=0x%llX", isRead ? "MRS" : "MSR", key, value, pc))
    if trace.count > 200000 { trace.removeFirst(100000) }
}
var total = 0
let chunk = 5_000_000
let stderr = FileHandle.standardError
// SIGILL（Swift トラップ）時に直前のフェッチ列を残す診断ハンドラ
let trapHandler: @convention(c) (Int32) -> Void = { _ in
    var s = String(format: "[sigtrap] cpu.pc=0x%llX instrCount=%lld\n", cpu.pc, cpu.instructionsExecuted)
    for i in 0..<31 { s += String(format: "  x%d=0x%llX\n", i, cpu.registers[i]) }
    s += "[sigtrap] last fetches (oldest first):\n"
    for (p, w) in fetchRing.suffix(60) {
        s += String(format: "  pc=0x%llX insn=0x%08X\n", p, w)
    }
    s.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
    _exit(99)
}
var trackA: UInt64 = 0; var trackB: UInt64 = 0; var trackC1: UInt64 = 0; var trackC2: UInt64 = 0
signal(SIGILL, trapHandler)
signal(SIGTRAP, trapHandler)
while total < maxM * 1_000_000 {
    do {
        try cpu.run(maxInstructions: chunk)
    } catch {
        stderr.write(Data("[run] threw: \(error)\n".utf8))
        break
    }
    total += chunk
    // [track] ブート進捗グローバル（[0x775F248]=A: ループ上限の源, [0x775F250]=B,
    // [0xA2B3BB0]=C1, [0xA2B3BB8]=C2）の変化をチャンク毎に監視する
    let tA = cpu.readGuestMemory(address: 0x80175F248, size: 8)
    let tB = cpu.readGuestMemory(address: 0x80175F250, size: 8)
    let tC1 = cpu.readGuestMemory(address: 0x80427FBB0, size: 4)
    let tC2 = cpu.readGuestMemory(address: 0x80427FBB8, size: 4)
    if tA != trackA || tB != trackB || tC1 != trackC1 || tC2 != trackC2 {
        stderr.write(Data(String(format: "[track] %dM A:0x%llX->0x%llX B:0x%llX->0x%llX C1:0x%llX->0x%llX C2:0x%llX->0x%llX pc=0x%llX\n",
                                 total / 1_000_000, trackA, tA, trackB, tB, trackC1, tC1, trackC2, tC2, cpu.pc).utf8))
        trackA = tA; trackB = tB; trackC1 = tC1; trackC2 = tC2
    }
    stderr.write(Data(String(format: "[chunk] %dM pc=0x%llX el=%d sp=0x%llX exc=%@\n",
                             total / 1_000_000, cpu.pc, cpu.currentEL, cpu.currentSP,
                             cpu.exceptionCounts.map { String(format: "v%llX:%d", $0.key, $0.value) }.sorted().joined(separator: ",")).utf8))
    if cpu.halted { break }
    if cpu.idle {
        stderr.write(Data("[run] idle (WFI) at \(total/1_000_000)M instr\n".utf8))
        break
    }
}
if !outBuffer.isEmpty { FileHandle.standardOutput.write(Data(outBuffer)) }
stderr.write(Data(String(format: "[crypto-count] total sha3reg=%@ sha2reg=%@ sha512=%d aes=%d | window(>=420M) sha3reg=%@ sha2reg=%@ sha512=%d aes=%d\n", sha3regT.map(String.init).joined(separator: ","), sha2regT.map(String.init).joined(separator: ","), sha512T, aesT, sha3regW.map(String.init).joined(separator: ","), sha2regW.map(String.init).joined(separator: ","), sha512W, aesW).utf8))
stderr.write(Data(String(format: "[done] executed ~%dM instr (exact %llu), halted=%@ exit=%d pc=0x%llX el=%d sp=0x%llX\n",
                         total / 1_000_000, cpu.instructionsExecuted, cpu.halted ? "true" : "false", cpu.exitCode,
                         cpu.pc, cpu.currentEL, cpu.currentSP).utf8))
stderr.write(Data(String(format: "[regs] sctlrEL2=0x%llX tcrEL2=0x%llX ttbr0EL2=0x%llX ttbr1EL2=0x%llX hcrEL2=0x%llX vbarEL2=0x%llX elrEL2=0x%llX esrEL2=0x%llX farEL2=0x%llX\n",
                         cpu.sctlrEL2, cpu.tcrEL2, cpu.ttbr0EL2, cpu.ttbr1EL2, cpu.hcrEL2, cpu.vbarEL2, cpu.elrEL2, cpu.esrEL2, cpu.farEL2).utf8))
stderr.write(Data(String(format: "[regs] sctlrEL1=0x%llX tcrEL1=0x%llX ttbr0EL1=0x%llX ttbr1EL1=0x%llX vbarEL1=0x%llX\n",
                         cpu.sctlrEL1, cpu.tcrEL1, cpu.ttbr0EL1, cpu.ttbr1EL1, cpu.vbarEL1).utf8))
// 最終 ELR の VA→PA を TTBR1 から手動でたどる（16K グラニュル、47 ビット VA）
func xlateVA(_ va: UInt64) -> UInt64? {
    let ttbr = (va & 0xFFFF_0000_0000_0000) != 0 ? cpu.ttbr1EL1 : cpu.ttbr0EL1
    func rd(_ pa: UInt64) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(cpu.readGuestMemory(address: pa + UInt64(i), size: 1)) << (i * 8) }
        return v
    }
    let d0 = rd(ttbr + ((va >> 36) & 0x7FF) * 8)
    if d0 & 0x3 != 0x3 { return nil }
    let d1 = rd((d0 & 0x0000_FFFF_FFFF_C000) + ((va >> 25) & 0x7FF) * 8)
    if d1 & 0x3 == 0x1 { return (d1 & 0x0000_FFFF_FFE0_0000) | (va & 0x1FF_FFFF) }
    if d1 & 0x3 != 0x3 { return nil }
    let d2 = rd((d1 & 0x0000_FFFF_FFFF_C000) + ((va >> 14) & 0x7FF) * 8)
    if d2 & 0x3 != 0x3 { return nil }
    return (d2 & 0x0000_FFFF_FFFF_C000) | (va & 0x3FFF)
}
func readVA64(_ va: UInt64) -> UInt64? {
    guard let pa = xlateVA(va) else { return nil }
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(cpu.readGuestMemory(address: pa + UInt64(i), size: 1)) << (i * 8) }
    return v
}
func walkVA(_ va: UInt64, ttbr: UInt64) {
    let l1idx = (va >> 36) & 0x7FF
    let l2idx = (va >> 25) & 0x7FF
    let l3idx = (va >> 14) & 0x7FF
    func rd(_ pa: UInt64) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(cpu.readGuestMemory(address: pa + UInt64(i), size: 1)) << (i * 8) }
        return v
    }
    let d1 = rd(ttbr + l1idx * 8)
    stderr.write(Data(String(format: "[walk] L1 idx=0x%llX desc=0x%llX\n", l1idx, d1).utf8))
    if d1 & 0x3 != 0x3 { return }
    let l2base = d1 & 0x0000_FFFF_FFFF_C000
    let d2 = rd(l2base + l2idx * 8)
    stderr.write(Data(String(format: "[walk] L2 idx=0x%llX desc=0x%llX\n", l2idx, d2).utf8))
    if d2 & 0x3 == 0x1 {
        let pa = (d2 & 0x0000_FFFF_FFE0_0000) | (va & 0x1FF_FFFF)
        stderr.write(Data(String(format: "[walk] L2 block -> PA 0x%llX\n", pa).utf8))
        return
    }
    if d2 & 0x3 != 0x3 { return }
    let l3base = d2 & 0x0000_FFFF_FFFF_C000
    let d3 = rd(l3base + l3idx * 8)
    let pa = (d3 & 0x0000_FFFF_FFFF_C000) | (va & 0x3FFF)
    stderr.write(Data(String(format: "[walk] L3 idx=0x%llX desc=0x%llX -> PA 0x%llX\n", l3idx, d3, pa).utf8))
}
if cpu.lastExceptionELR != 0 {
    if let pa = cpu.debugTranslate(cpu.lastExceptionELR) {
        let w = cpu.readGuestMemory(address: pa, size: 4)
        stderr.write(Data(String(format: "[xlate] elr VA 0x%llX -> PA 0x%llX word=0x%08X\n", cpu.lastExceptionELR, pa, UInt32(w & 0xFFFF_FFFF)).utf8))
    } else {
        stderr.write(Data("[xlate] elr VA does not translate\n".utf8))
    }
}
stderr.write(Data("[ttbr0walk] VA 0x8050D8004 via TTBR0:\n".utf8))
walkVA(0x8050D8004, ttbr: cpu.ttbr0EL1)
stderr.write(Data("[ttbr0walk] VA 0x8050D8004 via bootstrap TTBR0 0x801650000:\n".utf8))
walkVA(0x8050D8004, ttbr: 0x801650000)
for (name, tablePA) in [("bootstrapTTBR0", UInt64(0x801650000)), ("newTTBR0", cpu.ttbr0EL1), ("newTTBR1", cpu.ttbr1EL1)] {
    var nz: [String] = []
    for i in 0..<2048 {
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(cpu.readGuestMemory(address: tablePA + UInt64(i * 8 + b), size: 1)) << (b * 8) }
        if v != 0 { nz.append(String(format: "[0x%X]=0x%llX", i, v)) }
    }
    stderr.write(Data("[l0dump] \(name) PA 0x\(String(tablePA, radix: 16)) nonzero=\(nz.count): \(nz.prefix(24).joined(separator: " "))\n".utf8))
}
// スピン解析用: 全 GPR と x19（ロック想定）のワード、スタック 32 スロット
var gregLine = "[gregs]"
for i in 0..<31 { gregLine += String(format: " x%d=0x%llX", i, cpu.registers[i]) }
stderr.write(Data((gregLine + "\n").utf8))
if let lockPA = xlateVA(cpu.registers[19]) {
    var w: UInt64 = 0
    for b in 0..<8 { w |= UInt64(cpu.readGuestMemory(address: lockPA + UInt64(b), size: 1)) << (b * 8) }
    stderr.write(Data(String(format: "[lock] x19 VA=0x%llX PA=0x%llX word=0x%llX w20=0x%llX\n", cpu.registers[19], lockPA, w, cpu.registers[20]).utf8))
}
var spLine = "[stack]"
let spVA = cpu.currentSP
for i in 0..<32 {
    let va = spVA + UInt64(i * 8)
    if let v = readVA64(va) {
        spLine += String(format: " +0x%X=0x%llX", i * 8, v)
    }
}
stderr.write(Data((spLine + "\n").utf8))
// フレームポインタチェーンを辿る
var fp = cpu.registers[29]
var chain = "[frames]"
for _ in 0..<10 {
    guard fp != 0, let savedFP = readVA64(fp), let savedLR = readVA64(fp + 8) else { break }
    chain += String(format: " lr=0x%llX", savedLR)
    if savedFP <= fp { break }
    fp = savedFP
}
stderr.write(Data((chain + "\n").utf8))
for (name, tablePA) in [("bootstrapTTBR1-L1", UInt64(0x80165C000)), ("bootstrapTTBR0-L1", UInt64(0x801658000))] {
    var nz: [String] = []
    for i in 0..<2048 {
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(cpu.readGuestMemory(address: tablePA + UInt64(i * 8 + b), size: 1)) << (b * 8) }
        if v != 0 { nz.append(String(format: "[0x%X]=0x%llX", i, v)) }
    }
    stderr.write(Data("[l1dump] \(name) nonzero=\(nz.count): \(nz.prefix(40).joined(separator: " "))\n".utf8))
}
for (key, count) in fullEsrHistogram.sorted(by: { $0.value > $1.value }).prefix(8) {
    stderr.write(Data(String(format: "[full-esr] vector=0x%llX esr=0x%llX count=%d\n", key >> 32, key & 0xFFFF_FFFF, count).utf8))
}
for (ec, count) in esrHistogram.sorted(by: { $0.value > $1.value }) {
    stderr.write(Data(String(format: "[esr-ec] EC=0x%llX count=%d\n", ec, count).utf8))
}
for (elr, count) in elrHistogram.sorted(by: { $0.value > $1.value }).prefix(6) {
    stderr.write(Data(String(format: "[elr-top] elr=0x%llX count=%d\n", elr, count).utf8))
}
for (elr, word) in ec0Info {
    stderr.write(Data(String(format: "[ec0] elr=0x%llX insn=0x%08X\n", elr, word).utf8))
}

// パニックログ探索: RAM 全体から "panic" を含むテキスト領域を抽出する
do {
    let mem = cpu.memory
    let needle: [UInt8] = Array("vm_map_delete(0x".utf8)
    var hits: [Int] = []
    var i = 0
    while i + needle.count <= mem.count && hits.count < 400 {
        if mem[i] == needle[0] {
            var ok = true
            for j in 1..<needle.count where mem[i + j] != needle[j] { ok = false; break }
            if ok { hits.append(i) }
        }
        i += 1
    }
    stderr.write(Data("[panicscan] \(hits.count) raw hits\n".utf8))
    for h in hits { stderr.write(Data(String(format: "[panicscan] hit PA 0x%llX\n", UInt64(h) + cpu.ramBaseAddress).utf8)) }
    var printed = 0
    for h in hits where printed < 8 {
        // テキストらしい領域だけ前後を出す
        let lo = max(0, h - 64)
        let hi = min(mem.count, h + 1200)
        let slice = mem[lo..<hi]
        let head = mem[h..<min(mem.count, h + 128)]
        let printable = head.filter { $0 == 10 || ($0 >= 32 && $0 < 127) }.count
        if printable < head.count * 3 / 4 { continue }
        printed += 1
        stderr.write(Data(String(format: "[panicscan] --- at PA 0x%llX ---\n", UInt64(lo) + cpu.ramBaseAddress).utf8))
        stderr.write(Data(slice.map { ($0 >= 32 && $0 < 127) || $0 == 10 ? $0 : UInt8(ascii: ".") }))
        stderr.write(Data("\n".utf8))
    }
}
stderr.write(Data(String(format: "[exc] last vector=0x%llX esr=0x%llX (EC=0x%llX) elr=0x%llX farEL1=0x%llX esrEL1=0x%llX elrEL1=0x%llX\n",
                         cpu.lastExceptionVector, cpu.lastExceptionESR, cpu.lastExceptionESR >> 26,
                         cpu.lastExceptionELR, cpu.farEL1, cpu.esrEL1, cpu.elrEL1).utf8))
for line in trace { stderr.write(Data(("[sysreg] " + line + "\n").utf8)) }
if !cpu.unknownMMIOAccesses.isEmpty {
    let mmioList = cpu.unknownMMIOAccesses.prefix(32).map { String(format: "0x%llX", $0) }.joined(separator: " ")
    stderr.write(Data(("[unknown-mmio] " + mmioList + "\n").utf8))
}
