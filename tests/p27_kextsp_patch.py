#!/usr/bin/env python3
"""Phase 27: add the kext bsdthread_create SP-store watchpoint (P27TRACE) to src_p27/ARM64CPU.swift.

Grounding (phase 27 desk work, tests/logs/sp_origin_phase27_20261123.md):
- The __sfvwrite spin (phase 24) is caused by SP_EL0 misaligned by 8 in a
  launchd worker thread. The pthread kext's __bsdthread_create installs the
  initial SP verbatim from the userspace-supplied stack address:
    str x26, [x25, #0xf8]   (arm_thread_state64.__sp slot)
  at unslid VA 0xfffffe000a27fce4 (kernelcache.macho fileoff 0x327ba38 +
  0x4ac), slid (KASLR 0x182B4000) 0xfffffe0022533ce4.
  Expected word: STR x26, [x25, #0xF8] = 0xF9007F3A.
- The kext performs NO arithmetic on SP (disassembled); libpthread's
  _pthread_allocate arithmetic guarantees SP%16==0 for a regular pthread;
  the exec path is empirically exonerated. The desk work does NOT convict
  an engine delta, so NO engine code is changed (ABSOLUTE fix rule).
- This watchpoint logs, at thread-creation time, the SP value the kext
  installs together with the calling process (TTBR0_EL1) and the state
  buffer, for every pthread creation. Offline analysis maps each TTBR0 to
  a process and finds the launchd worker's install.

Design (harness-only, no engine semantics changed):
- Env-gated P27TRACE=1, off by default. Log file p27trace.txt
  (P27TRACE_PATH override). Harness-only.
- Step-start check in step(): when the about-to-execute PC equals
  0xfffffe0022533ce4, log instr + TTBR0_EL1 + x26 (SP being installed) +
  x25 (state buffer) + x0-x6 + misaligned flag. First hit verifies the
  instruction word == 0xF9007F3A (a mismatch = slide changed -> capture
  invalid, logged once, watchpoint disabled). Cap 128 entries.
- No halt on install: the boot runs until the SFVTRACE backstop fires at
  the spin, so the log holds EVERY pthread install.
- SPTRACE must be OFF for the p27 boot (it would halt on fsck's first
  dispatch before the worker's creation). ILLTRACE=1 and SFVTRACE=1 stay on.
"""
import sys

path = sys.argv[1]
src = open(path).read()

assert "P27TRACE" not in src, "patch already applied"
assert "p27KextSp" not in src, "patch already applied"
assert "p27Log" not in src, "patch already applied"

# ---------- 1. top-level section (after the p23 SFVTRACE block) ----------
anchor1 = """func p23SfvLog(_ s: String) {
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
assert src.count(anchor1) == 1, f"anchor1 count={src.count(anchor1)}"

block1 = anchor1 + """
// MARK: - Phase-27 diagnostic: kext bsdthread_create SP-store watchpoint (env P27TRACE=1; unset = no-op)
// The __sfvwrite spin (phase 24) is caused by SP_EL0 misaligned by 8 in a
// launchd worker thread. The pthread kext's __bsdthread_create installs the
// initial SP verbatim from the userspace-supplied stack address:
//   str x26, [x25, #0xf8]   (arm_thread_state64.__sp slot)
// at unslid VA 0xfffffe000a27fce4, slid (KASLR 0x182B4000) 0xfffffe0022533ce4.
// Expected word: STR x26, [x25, #0xF8] = 0xF9007F3A.
// This watchpoint logs every execution of that store (instr, TTBR0_EL1,
// the SP value in x26, the state buffer in x25, x0-x6) so the offline
// analysis can map each TTBR0 to a process and find the launchd worker's
// install. No halt on install — the boot runs until the SFVTRACE backstop
// fires at the spin. First hit verifies the instruction word (slide check).
let p27TraceEnabled = ProcessInfo.processInfo.environment["P27TRACE"] != nil
// NOTE: do NOT inline this literal into a `!=` comparison — Swift 5.10
// fails to infer the literal as UInt64 there ("integer literal overflows
// when stored into 'Int'"); a named UInt64 constant (or `==`) compiles.
private let p27KextSpStorePC: UInt64 = 0xfffffe0022533ce4
private var p27InstallLogged = 0
private var p27WordVerified = false
private var p27WatchpointDisabled = false
private var p27Handle: FileHandle? = nil
func p27Log(_ s: String) {
    guard p27TraceEnabled else { return }
    if p27Handle == nil {
        let path = ProcessInfo.processInfo.environment["P27TRACE_PATH"] ?? "p27trace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p27Handle = FileHandle(forWritingAtPath: path)
    }
    p27Handle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[p27trace] " + s + "\\n").utf8))
}
"""
src = src.replace(anchor1, block1, 1)

# ---------- 2. step-start check in step() (after the p25 step-start block) ----------
anchor2 = """        p25LastPC = instructionPC
        // [p25] SP_EL0 misalignment logger (SPTRACE=1): step-start check —
        // catches exception-entry changes and userspace executing with a
        // misaligned SP (see p25SpCheckStart).
        if p25SpTraceEnabled && !p25SpFired {
            p25SpCheckStart(instructionPC: instructionPC)
        }
"""
assert src.count(anchor2) == 1, f"anchor2 count={src.count(anchor2)}"

block2 = anchor2 + """        // [p27] kext SP-store watchpoint (P27TRACE=1): logs every
        // bsdthread_create SP install (see p27KextSpCheck).
        if p27TraceEnabled && !p27WatchpointDisabled {
            p27KextSpCheck(instructionPC: instructionPC)
        }
"""
src = src.replace(anchor2, block2, 1)

# ---------- 3. helper method (after p25SpCheckEnd) ----------
anchor3 = """    // Step-end check: the faulting instruction is the one just executed.
    private func p25SpCheckEnd() {
        let prevAligned = (p25PrevSpEL0 & 15) == 0
        let curMisaligned = (spEL0 & 15) != 0
        if prevAligned && curMisaligned {
            if p25UserspaceStarted {
                p25SpFire(kind: "insn", faultPC: p25LastPC, word: p25LastInsn)
            } else {
                p25SpNoteTransition(kind: "insn", faultPC: p25LastPC, word: p25LastInsn)
            }
        } else if !prevAligned && !curMisaligned {
            p25SpNoteRealign()
        }
        p25PrevSpEL0 = spEL0
    }
"""
assert src.count(anchor3) == 1, f"anchor3 count={src.count(anchor3)}"

block3 = anchor3 + """
    // [p27] kext bsdthread_create SP-store watchpoint (P27TRACE=1).
    // Fires when the CPU is about to execute the kext's SP store
    // (slid PC 0xfffffe0022533ce4, STR x26, [x25, #0xF8]). At step-start
    // x26 already holds the SP value that will be installed, so logging
    // it here captures the exact userspace-supplied stack address.
    // First hit verifies the instruction word == 0xF9007F3A (slide check).
    // Cap 128 entries; never halts.
    private func p27KextSpCheck(instructionPC: UInt64) {
        if instructionPC != p27KextSpStorePC { return }
        let word = p25SpPeekWord(instructionPC)
        if !p27WordVerified {
            p27WordVerified = true
            p27Log("instr=\\(instructionsExecuted) ev=WORD-CHECK pc=0x\\(String(instructionPC, radix: 16)) word=0x\\(String(UInt64(word), radix: 16)) expected=0xf9007f3a")
            if word != 0xF9007F3A {
                p27Log("instr=\\(instructionsExecuted) ev=PC-MISMATCH word=0x\\(String(UInt64(word), radix: 16)) — slide changed; watchpoint disabled")
                p27WatchpointDisabled = true
                return
            }
        }
        if p27InstallLogged >= 128 { return }
        p27InstallLogged &+= 1
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        var args = ""
        for i in 0..<7 {
            args += "x\\(i)=0x\\(hx(registers[i])) "
        }
        let sp = registers[26]
        let mis = (sp & 15) != 0
        p27Log("instr=\\(instructionsExecuted) ev=INSTALL ttbr0el1=0x\\(hx(ttbr0EL1)) ttbr1el1=0x\\(hx(ttbr1EL1)) sp=0x\\(hx(sp)) mis=\\(mis ? 1 : 0) x25(statebuf)=0x\\(hx(registers[25])) el=\\(currentEL) | \\(args)")
    }
"""
src = src.replace(anchor3, block3, 1)

open(path, "w").write(src)
print("p27 kextsp patch applied")
