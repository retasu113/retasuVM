#!/usr/bin/env python3
"""Phase 29: add the wqthread SP-store watchpoint (WQTRACE) to src_p29/ARM64CPU.swift.

Grounding (phase 29 desk work, tests/logs/wqthread_phase29_20261126.md):
- The pthread kext's _workq_setup_thread (unslid VA 0xfffffe000a280910)
  computes the wqthread's initial SP as
      x27 = (stackaddr + vm_map_page_size + 0x83000) & ~0xF
  (16-byte aligned by construction) and passes it in a 3-field struct to
  _workq_set_register_state (0xfffffe000a280b24), which builds an
  arm_thread_state64 on its kernel stack and stores:
      stp x8, x21, [sp, #0x118]   ; __sp = x8 (the aligned top), __pc = x21
  at unslid VA 0xfffffe000a280bcc, slid (KASLR 0x182B4000)
  0xfffffe0022534bcc. Expected word: STP x8, x21, [sp, #0x118] = 0xA911D7E8.
  thread_set_wq_state64 (osfmk/arm64/status.c) then copies the SP
  verbatim into the thread's upcb (SS64_SP at saved-state +0xF8).
- This watchpoint logs, at every wqthread state install, the SP value in
  x8 together with TTBR0_EL1 (process attribution via the phase-28
  ttbrmap method), x21 (entry PC), x19 (thread), x26 (proc) and x0-x7.
  No halt: the boot runs until the SFVTRACE backstop fires at the spin,
  so the log holds EVERY wqthread install of the run.
- Harness-only; no engine semantics changed. Env WQTRACE=1, off by
  default. Log file wqtrace.txt (WQTRACE_PATH override). Cap 8192.
"""
import sys

path = sys.argv[1]
src = open(path).read()

assert "WQTRACE" not in src, "patch already applied"
assert "p29Wq" not in src, "patch already applied"
assert "p29Log" not in src, "patch already applied"

# ---------- 1. top-level section (after the p27 block) ----------
anchor1 = """    p27Handle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[p27trace] " + s + "\\n").utf8))
}
"""
assert src.count(anchor1) == 1, f"anchor1 count={src.count(anchor1)}"

block1 = anchor1 + """
// MARK: - Phase-29 diagnostic: kext _workq_set_register_state SP-store watchpoint (env WQTRACE=1; unset = no-op)
// The pthread kext installs a wqthread's initial SP in
// _workq_set_register_state (unslid 0xfffffe000a280b24):
//   stp x8, x21, [sp, #0x118]   ; arm_thread_state64.__sp = x8, __pc = x21
// at unslid VA 0xfffffe000a280bcc, slid (KASLR 0x182B4000) 0xfffffe0022534bcc.
// Expected word: STP x8, x21, [sp, #0x118] = 0xA911D7E8.
// Desk analysis (phase 29) shows the value in x8 is 16-byte aligned by
// construction in the kext ((stackaddr + page_size + 0x83000) & ~0xF);
// this watchpoint measures what is ACTUALLY installed at runtime, with
// TTBR0_EL1 for process attribution. No halt on install — the boot runs
// until the SFVTRACE backstop fires at the spin. First hit verifies the
// instruction word (slide check). Cap 8192 entries.
let p29WqTraceEnabled = ProcessInfo.processInfo.environment["WQTRACE"] != nil
// NOTE: named UInt64 constant (see the p27 note about literal inference).
private let p29WqSpStorePC: UInt64 = 0xfffffe0022534bcc
private var p29WqInstallLogged = 0
private var p29WqWordVerified = false
private var p29WqWatchpointDisabled = false
private var p29WqHandle: FileHandle? = nil
func p29Log(_ s: String) {
    guard p29WqTraceEnabled else { return }
    if p29WqHandle == nil {
        let path = ProcessInfo.processInfo.environment["WQTRACE_PATH"] ?? "wqtrace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p29WqHandle = FileHandle(forWritingAtPath: path)
    }
    p29WqHandle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[wqtrace] " + s + "\\n").utf8))
}
"""
src = src.replace(anchor1, block1, 1)

# ---------- 2. step-start check in step() (after the p27 check) ----------
anchor2 = """        // [p27] kext SP-store watchpoint (P27TRACE=1): logs every
        // bsdthread_create SP install (see p27KextSpCheck).
        if p27TraceEnabled && !p27WatchpointDisabled {
            p27KextSpCheck(instructionPC: instructionPC)
        }
"""
assert src.count(anchor2) == 1, f"anchor2 count={src.count(anchor2)}"

block2 = anchor2 + """        // [p29] wqthread SP-store watchpoint (WQTRACE=1): logs every
        // _workq_set_register_state SP install (see p29WqSpCheck).
        if p29WqTraceEnabled && !p29WqWatchpointDisabled {
            p29WqSpCheck(instructionPC: instructionPC)
        }
"""
src = src.replace(anchor2, block2, 1)

# ---------- 3. helper method (after p27KextSpCheck) ----------
anchor3 = """        let sp = registers[26]
        let mis = (sp & 15) != 0
        p27Log("instr=\\(instructionsExecuted) ev=INSTALL ttbr0el1=0x\\(hx(ttbr0EL1)) ttbr1el1=0x\\(hx(ttbr1EL1)) sp=0x\\(hx(sp)) mis=\\(mis ? 1 : 0) x25(statebuf)=0x\\(hx(registers[25])) el=\\(currentEL) | \\(args)")
    }
"""
assert src.count(anchor3) == 1, f"anchor3 count={src.count(anchor3)}"

block3 = anchor3 + """
    // [p29] kext _workq_set_register_state SP-store watchpoint (WQTRACE=1).
    // Fires when the CPU is about to execute the kext's wqthread __sp
    // store (slid PC 0xfffffe0022534bcc, STP x8, x21, [sp, #0x118]).
    // At step-start x8 already holds the SP value that will be installed
    // into the arm_thread_state64 (and then copied verbatim into the
    // thread's upcb by thread_set_wq_state64), x21 the entry PC,
    // x19 the thread, x26 the proc, x20 the caller's 3-field struct.
    // First hit verifies the instruction word == 0xA911D7E8 (slide check).
    // Cap 8192 entries; never halts.
    private func p29WqSpCheck(instructionPC: UInt64) {
        if instructionPC != p29WqSpStorePC { return }
        let word = p25SpPeekWord(instructionPC)
        if !p29WqWordVerified {
            p29WqWordVerified = true
            p29Log("instr=\\(instructionsExecuted) ev=WORD-CHECK pc=0x\\(String(instructionPC, radix: 16)) word=0x\\(String(UInt64(word), radix: 16)) expected=0xa911d7e8")
            if word != 0xA911D7E8 {
                p29Log("instr=\\(instructionsExecuted) ev=PC-MISMATCH word=0x\\(String(UInt64(word), radix: 16)) — slide changed; watchpoint disabled")
                p29WqWatchpointDisabled = true
                return
            }
        }
        if p29WqInstallLogged >= 8192 { return }
        p29WqInstallLogged &+= 1
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        var args = ""
        for i in 0..<8 {
            args += "x\\(i)=0x\\(hx(registers[i])) "
        }
        let sp = registers[8]
        let mis = (sp & 15) != 0
        p29Log("instr=\\(instructionsExecuted) ev=INSTALL ttbr0el1=0x\\(hx(ttbr0EL1)) ttbr1el1=0x\\(hx(ttbr1EL1)) sp=0x\\(hx(sp)) mis=\\(mis ? 1 : 0) pc=0x\\(hx(registers[21])) thread=0x\\(hx(registers[19])) proc=0x\\(hx(registers[26])) structptr=0x\\(hx(registers[20])) kport=0x\\(hx(registers[25])) el=\\(currentEL) | \\(args)")
    }
"""
src = src.replace(anchor3, block3, 1)

open(path, "w").write(src)
print("p29 wqtrace patch applied")
