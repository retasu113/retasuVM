#!/usr/bin/env python3
"""Phase 23: add the __sfvwrite watchpoint (SFVTRACE) to src_p24/ARM64CPU.swift.

Grounding (phase 22, tests/logs/userspace_spin_phase22_20261123.md):
- __sfvwrite(FILE *fp=x19, struct __suio *uio=x20) loops while
  [x20,#0xC] (uio_resid) != 0; back-edge at unslid 0x180308b64
  (`b.ne #0x1803089ec`); function entry unslid 0x18030897c.
- struct __suio (BSD fvwrite.h): uio_iov @+0x00 (ptr), uio_iovcnt @+0x08
  (int), uio_resid @+0x0C (int). struct __sFILE: _p @+0x00, _r @+0x08,
  _w @+0x0C, _flags @+0x10 (short), _file (fd) @+0x12 (short).
- Prologue bytes at unslid 0x18030897c (read from the p23 dump, PA
  0x83e8897c and 0x845f497c, both copies identical):
    b9400c28 34000f68 d503237f a9ba6ffc
  = ldr w8,[x1,#0xc] (uio_resid); cbz w8,ret; pacibsp;
    stp x28,x27,[sp,#-0x60]!
  The slide is per-boot random (p20: 0x1B208000, p22: 0x1b574000), so it is
  detected at runtime by probing candidate VAs (0x18030897c + slide) for
  these prologue bytes via the TTBR0 translator. The dyld cache header
  magic is NOT used: the header (file offset 0) is not mapped at the cache
  base VA (the __TEXT segment starts there instead).

Design (harness-only, no engine semantics changed):
- Slide scan: when SFVTRACE=1, in EL0, slide unknown, retry every 500M
  instr; slide is page-aligned (0x4000 step), range [0, 0x80000000).
- Per-invocation back-edge counter: reset when PC == __sfvwrite entry,
  increment when PC == back-edge. A normal __sfvwrite call iterates once
  per iovec entry (a handful); the spin iterates forever. Fire at
  1,000,000 iterations (~94M loop instructions, ~3 min into the spin).
- On fire: log once (live x19/x20/x26/x21/x22/x23, PC/LR, TTBR0s, and the
  __suio + FILE fields read via the translator), then halt the CPU
  (the capture is the goal; no 6.5 h run needed).
"""
import sys

path = sys.argv[1]
src = open(path).read()

assert "SFVTRACE" not in src, "patch already applied"

# ---------- 1. top-level section (after the p20 ILLTRACE block) ----------
anchor1 = """    p20IllHandle?.write(Data((p20IllLines.joined(separator: "\\n") + "\\n").utf8))
    p20IllLines.removeAll()
}
"""
assert src.count(anchor1) == 1, f"anchor1 count={src.count(anchor1)}"

block1 = anchor1 + """
// MARK: - Phase-23 diagnostic: __sfvwrite watchpoint (env SFVTRACE=1; unset = no-op)
// Fires when the PC first enters the __sfvwrite loop (unslid 0x1803089ec,
// slid by the per-boot dyld cache slide, detected at runtime by probing
// candidate VAs for the __sfvwrite prologue bytes). On fire, logs once the
// live registers and the __suio / FILE fields read via the TTBR0
// translator, then halts the CPU (the capture is the goal).
let p23SfvTraceEnabled = ProcessInfo.processInfo.environment["SFVTRACE"] != nil
private var p23SfvSlide: UInt64? = nil
private var p23SfvFired = false
private var p23SfvScanNext: UInt64 = 0
private var p23SfvIterCount: UInt64 = 0
private var p23SfvHandle: FileHandle? = nil
func p23SfvLog(_ s: String) {
    guard p23SfvTraceEnabled else { return }
    if p23SfvHandle == nil {
        let path = ProcessInfo.processInfo.environment["SFVTRACE_PATH"] ?? "sfvtrace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p23SfvHandle = FileHandle(forWritingAtPath: path)
    }
    p23SfvHandle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[sfvtrace] " + s + "\\n").utf8))
}
"""
src = src.replace(anchor1, block1, 1)

# ---------- 2. watchpoint check in step() (after the p17 block) ----------
anchor2 = """        // [p17] -nobsdmgroot discrimination: patch boot_args CommandLine at the first _nx_mount
        if p17NoBSDmgRoot && !p17PatchAttempted && instructionsExecuted > 2_000_000_000 && instructionPC == 0xFFFFFE002239BE9C {
            p17PatchAttempted = true
            p17PatchBootArgs()
        }
"""
assert src.count(anchor2) == 1, f"anchor2 count={src.count(anchor2)}"

block2 = anchor2 + """        // [p23] __sfvwrite watchpoint (SFVTRACE=1): detect the dyld slide
        // once, then count back-edge executions per __sfvwrite invocation.
        if p23SfvTraceEnabled && !p23SfvFired && currentEL == 0 {
            if p23SfvSlide == nil {
                if instructionsExecuted >= p23SfvScanNext {
                    p23SfvSlide = p23SfvFindSlide()
                    p23SfvScanNext = instructionsExecuted + 500_000_000
                    if let s = p23SfvSlide {
                        p23SfvLog("instr=\\(instructionsExecuted) ev=SLIDE slide=0x\\(String(s, radix: 16)) sfvwrite=0x\\(String(0x18030897C &+ s, radix: 16)) loop=0x\\(String(0x1803089EC &+ s, radix: 16))..0x\\(String(0x180308B64 &+ s, radix: 16))")
                    } else {
                        p23SfvLog("instr=\\(instructionsExecuted) ev=SLIDE-NOT-FOUND next-retry-at=\\(p23SfvScanNext)")
                    }
                }
            } else if let slide = p23SfvSlide {
                let entry = 0x18030897C &+ slide
                let back = 0x180308B64 &+ slide
                if instructionPC == entry {
                    p23SfvIterCount = 0
                } else if instructionPC == back {
                    p23SfvIterCount &+= 1
                    if p23SfvIterCount >= 1_000_000 {
                        p23SfvFired = true
                        p23SfvCapture()
                        halted = true
                    }
                }
            }
        }
"""
src = src.replace(anchor2, block2, 1)

# ---------- 3. helper methods (after p16WatchPeek32) ----------
anchor3 = """    private func p16WatchPeek32(_ va: UInt64) -> UInt32 {
        do {
            let pa = try translate(address: va, isWrite: false, isFetch: false)
            if let b = physReadBytes(pa, 4), b.count == 4 {
                return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            }
        } catch { }
        return 0xFFFF_FFFF
    }
"""
assert src.count(anchor3) == 1, f"anchor3 count={src.count(anchor3)}"

block3 = anchor3 + """
    // [p23] Find the dyld cache slide by probing candidate VAs
    // (0x18030897c + slide) for the __sfvwrite prologue bytes
    // (b9400c28 34000f68 d503237f a9ba6ffc — ldr w8,[x1,#0xc]; cbz;
    // pacibsp; stp x28,x27,[sp,#-0x60]!). slide is 0x4000-aligned,
    // range [0, 0x80000000). Returns nil if the prologue is not found
    // (cache page not yet mapped in the current process).
    private func p23SfvFindSlide() -> UInt64? {
        let prologue: [UInt8] = [0x28, 0x0c, 0x40, 0xb9, 0x68, 0x0f, 0x00, 0x34, 0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9]
        var k: UInt64 = 0
        while k < 0x80000000 / 0x4000 {
            let va = 0x18030897C &+ k &* 0x4000
            if let pa = debugTranslate(va), let b = physReadBytes(pa, 16), b.count == 16, b == prologue {
                return k &* 0x4000
            }
            k &+= 1
        }
        return nil
    }

    // [p23] Guest-VA peek helpers (same pattern as p16WatchPeek32:
    // translate via the current regime, then read physical bytes).
    private func p23SfvPeekBytes(_ va: UInt64, _ count: Int) -> [UInt8]? {
        do {
            let pa = try translate(address: va, isWrite: false, isFetch: false)
            return physReadBytes(pa, count)
        } catch { return nil }
    }
    private func p23SfvPeek64(_ va: UInt64) -> UInt64? {
        guard let b = p23SfvPeekBytes(va, 8), b.count == 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << UInt64(i * 8) }
        return v
    }
    private func p23SfvPeek32(_ va: UInt64) -> UInt32? {
        guard let b = p23SfvPeekBytes(va, 4), b.count == 4 else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
    private func p23SfvPeek16(_ va: UInt64) -> UInt16? {
        guard let b = p23SfvPeekBytes(va, 2), b.count == 2 else { return nil }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    // [p23] Capture the spinning __sfvwrite call: live regs + __suio/FILE
    // fields. Layouts (phase 22): __suio uio_iov @+0x00, uio_iovcnt @+0x08,
    // uio_resid @+0x0C; __sFILE _p @+0x00, _r @+0x08, _w @+0x0C,
    // _flags @+0x10, _file (fd) @+0x12. Current iovec entry: ptr @ [x26,#-0x10],
    // len @ [x26,#8] (phase-22 disassembly).
    private func p23SfvCapture() {
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        func hxOpt(_ v: UInt64?) -> String { v.map { "0x" + hx($0) } ?? "nil" }
        func u32Opt(_ v: UInt32?) -> String { v.map { String($0) } ?? "nil" }
        let fp = registers[19], uio = registers[20], iovCur = registers[26]
        let x21 = registers[21], x22 = registers[22], x23 = registers[23]
        let lr = registers[30]
        let uioIov = p23SfvPeek64(uio &+ 0x00)
        let uioCnt = p23SfvPeek32(uio &+ 0x08)
        let uioResid = p23SfvPeek32(uio &+ 0x0C)
        var firstPtr: UInt64? = nil, firstLen: UInt64? = nil
        if let base = uioIov {
            firstPtr = p23SfvPeek64(base &+ 0x00)
            firstLen = p23SfvPeek64(base &+ 0x08)
        }
        let curPtr = p23SfvPeek64(iovCur &- 0x10)
        let curLen = p23SfvPeek64(iovCur &+ 0x08)
        let fP = p23SfvPeek64(fp &+ 0x00)
        let fR = p23SfvPeek32(fp &+ 0x08)
        let fW = p23SfvPeek32(fp &+ 0x0C)
        let fFlags = p23SfvPeek16(fp &+ 0x10)
        let fFd = p23SfvPeek16(fp &+ 0x12)
        let s = "instr=\\(instructionsExecuted) ev=CAPTURE pc=0x\\(hx(pc)) lr=0x\\(hx(lr)) el=\\(currentEL) ttbr0el1=0x\\(hx(ttbr0EL1)) ttbr0el2=0x\\(hx(ttbr0EL2)) iters=\\(p23SfvIterCount) x19(FILE)=0x\\(hx(fp)) x20(uio)=0x\\(hx(uio)) x26(iovcur)=0x\\(hx(iovCur)) x21=0x\\(hx(x21)) x22=0x\\(hx(x22)) x23=0x\\(hx(x23)) | uio_iov=\\(hxOpt(uioIov)) uio_iovcnt=\\(u32Opt(uioCnt)) uio_resid=\\(u32Opt(uioResid)) | iov[0] ptr=\\(hxOpt(firstPtr)) len=\\(hxOpt(firstLen)) | iov[cur] ptr=\\(hxOpt(curPtr)) len=\\(hxOpt(curLen)) | FILE _p=\\(hxOpt(fP)) _r=\\(u32Opt(fR)) _w=\\(u32Opt(fW)) _flags=\\(fFlags.map { \"0x\" + hx(UInt64($0)) } ?? \"nil\") _file(fd)=\\(fFd.map { String($0) } ?? \"nil\")"
        p23SfvLog(s)
    }
"""
src = src.replace(anchor3, block3, 1)

open(path, "w").write(src)
print("p24 sfvtrace patch applied")
