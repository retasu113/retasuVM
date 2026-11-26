#!/usr/bin/env python3
"""Phase 25: add the SP_EL0 misalignment transition logger (SPTRACE) to src_p25/ARM64CPU.swift.

Grounding (phase 24, tests/logs/sfvwrite_capture_phase24_20261123.md):
- __sfvwrite spins because SP_EL0 is misaligned by 8 (SP%16 = 8) in a
  launchd worker thread, present from the thread's entry (all FP-chain
  frames %16 = 8). __vfprintf's `orr x1,x23,#8` peephole (valid only if
  x23 is 16-byte aligned) then passes a uio pointer 8 bytes too low.
- The specific engine instruction/transition that introduces the 8-byte
  shift is NOT convicted. ENGINE is favored, but no fix may be made
  without grounding (ABSOLUTE fix rule).
- SP model in this emulator (verified by reading src_p24/ARM64CPU.swift):
  spEL0/spEL1/spEL2 are plain vars; `currentSP` selects by EL/SPSel;
  MSR SP_EL0 writes spEL0 directly (writeSystemRegister case 0x6108);
  enterException() and eret() do NOT touch SP; ERET is the only
  EL-lowering path, so the first ERET to EL0 marks userspace start.
  MSR SP_EL0, Xn encoding: 0xD5184100 | n (op0=3,op1=0,CRn=4,CRm=1,op2=0).

Design (harness-only, no engine semantics changed):
- Edge detection on SP_EL0 after every step: fire on the FIRST
  aligned -> misaligned transition once userspace has started, logging
  the faulting PC + instruction word + EL/pstate/SPSel + SP before/after
  + TTBR0s + all x0-x30 (+ the MSR source register when the faulting
  instruction is MSR SP_EL0), then halt. Transitions before userspace
  starts are logged only (cap 8, incl. re-alignments) as boot-phase
  context.
- Safety nets: (a) step-start check fires kind="el0-exec" if a
  userspace instruction is about to execute with a misaligned SP
  (covers a missed edge); (b) the eret() hook fires kind="eret-el0"
  if an ERET targets EL0 with SP_EL0 already misaligned.
- Env-gated SPTRACE=1, off by default. Log file sptrace.txt
  (SPTRACE_PATH override). Harness-only.
"""
import sys

path = sys.argv[1]
src = open(path).read()

assert "SPTRACE" not in src, "patch already applied"
assert "p25Sp" not in src, "patch already applied"

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
// MARK: - Phase-25 diagnostic: SP_EL0 misalignment transition logger (env SPTRACE=1; unset = no-op)
// The __sfvwrite spin (phase 24) is caused by SP_EL0 misaligned by 8
// (SP%16 = 8) in a launchd worker thread, present from the thread's
// entry. This logger watches every SP_EL0 transition: it records the
// FIRST transition where SP_EL0 goes from 16-byte aligned to misaligned,
// with the faulting PC and instruction, then halts. Transitions before
// userspace starts are logged only (boot-phase context); the logger fires
// once userspace has started (first ERET to EL0), or immediately when
// userspace executes with a bad SP, or when an ERET targets EL0 with a
// bad SP.
let p25SpTraceEnabled = ProcessInfo.processInfo.environment["SPTRACE"] != nil
private var p25SpFired = false
private var p25UserspaceStarted = false
private var p25PrevSpEL0: UInt64 = 0
private var p25TransitionLogged = 0
private var p25LastPC: UInt64 = 0
private var p25LastInsn: UInt32 = 0
private var p25SpHandle: FileHandle? = nil
func p25SpLog(_ s: String) {
    guard p25SpTraceEnabled else { return }
    if p25SpHandle == nil {
        let path = ProcessInfo.processInfo.environment["SPTRACE_PATH"] ?? "sptrace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p25SpHandle = FileHandle(forWritingAtPath: path)
    }
    p25SpHandle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[sptrace] " + s + "\\n").utf8))
}
"""
src = src.replace(anchor1, block1, 1)

# ---------- 2. step-start check in step() (after instructionPC is set) ----------
anchor2 = """        instructionsExecuted &+= 1
        blkLogInstr = instructionsExecuted
        let instructionPC = pc
"""
assert src.count(anchor2) == 1, f"anchor2 count={src.count(anchor2)}"

block2 = anchor2 + """        p25LastPC = instructionPC
        // [p25] SP_EL0 misalignment logger (SPTRACE=1): step-start check —
        // catches exception-entry changes and userspace executing with a
        // misaligned SP (see p25SpCheckStart).
        if p25SpTraceEnabled && !p25SpFired {
            p25SpCheckStart(instructionPC: instructionPC)
        }
"""
src = src.replace(anchor2, block2, 1)

# ---------- 3. record the fetched instruction word (for the step-end check) ----------
anchor3 = """            let insn = try fetch32(at: instructionPC)
"""
assert src.count(anchor3) == 1, f"anchor3 count={src.count(anchor3)}"

block3 = anchor3 + """            p25LastInsn = insn
"""
src = src.replace(anchor3, block3, 1)

# ---------- 4. step-end check in step() (after the abort catch) ----------
anchor4 = """        } catch let abort as AbortSignal {
            // データ / 命令アボートは例外として配送する（セッションは継続）
            let target = exceptionTargetEL
            if target == 2 { farEL2 = abort.address } else { farEL1 = abort.address }
            let fromLower = currentEL < target
            let ec: UInt64 = abort.isInstruction ? (fromLower ? 0x20 : 0x21) : (fromLower ? 0x24 : 0x25)
            enterException(vectorOffset: syncVectorOffset(), elr: instructionPC, esr: (ec << 26) | (1 << 25) | (abort.isWrite ? (1 << 6) : 0) | abort.fsc)
        }
    }
"""
assert src.count(anchor4) == 1, f"anchor4 count={src.count(anchor4)}"

block4 = """        } catch let abort as AbortSignal {
            // データ / 命令アボートは例外として配送する（セッションは継続）
            let target = exceptionTargetEL
            if target == 2 { farEL2 = abort.address } else { farEL1 = abort.address }
            let fromLower = currentEL < target
            let ec: UInt64 = abort.isInstruction ? (fromLower ? 0x20 : 0x21) : (fromLower ? 0x24 : 0x25)
            enterException(vectorOffset: syncVectorOffset(), elr: instructionPC, esr: (ec << 26) | (1 << 25) | (abort.isWrite ? (1 << 6) : 0) | abort.fsc)
        }
        // [p25] SP_EL0 misalignment logger (SPTRACE=1): step-end check —
        // the faulting instruction is the one just executed (p25LastPC).
        if p25SpTraceEnabled && !p25SpFired {
            p25SpCheckEnd()
        }
    }
"""
src = src.replace(anchor4, block4, 1)

# ---------- 5. ERET hook (fire if an ERET targets EL0 with a bad SP) ----------
anchor5 = """    private func eret() {
        if currentEL == 2 {
            pc = elrEL2
            pstate = spsrEL2
        } else {
            pc = elrEL1
            pstate = spsrEL1
        }
    }
"""
assert src.count(anchor5) == 1, f"anchor5 count={src.count(anchor5)}"

block5 = """    private func eret() {
        if currentEL == 2 {
            pc = elrEL2
            pstate = spsrEL2
        } else {
            pc = elrEL1
            pstate = spsrEL1
        }
        // [p25] SP_EL0 misalignment logger (SPTRACE=1): note the first
        // ERET to EL0 (userspace starts) and fire if SP_EL0 is already
        // misaligned at entry.
        if p25SpTraceEnabled && !p25SpFired && currentEL == 0 {
            p25UserspaceStarted = true
            if (spEL0 & 15) != 0 {
                p25SpFire(kind: "eret-el0", faultPC: pc, word: p25SpPeekWord(pc))
            }
        }
    }
"""
src = src.replace(anchor5, block5, 1)

# ---------- 6. helper methods (after p23SfvCapture) ----------
anchor6 = """        p23SfvLog(s)
    }
"""
assert src.count(anchor6) == 1, f"anchor6 count={src.count(anchor6)}"

block6 = anchor6 + """
    // [p25] SP_EL0 misalignment transition logger (SPTRACE=1).
    // Edge detection on SP_EL0: fire on the first aligned -> misaligned
    // transition once userspace has started. Transitions before userspace
    // starts are logged only (cap 8) as boot-phase context.
    private func p25SpFire(kind: String, faultPC: UInt64, word: UInt32) {
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        var regs = ""
        for i in 0..<31 {
            regs += "x\\(i)=0x\\(hx(registers[i])) "
        }
        var msrInfo = ""
        if (word & 0xFFFF_FFE0) == 0xD518_4100 {
            let rt = Int(word & 0x1F)
            msrInfo = " msrSP_EL0 rt=x\\(rt)=0x\\(hx(registers[rt]))"
        }
        let s = "instr=\\(instructionsExecuted) ev=FIRE kind=\\(kind) faultPC=0x\\(hx(faultPC)) word=0x\\(hx(UInt64(word))) el=\\(currentEL) pstate=0x\\(hx(UInt64(pstate))) spsel=\\(pstate & 1) spEL0Prev=0x\\(hx(p25PrevSpEL0)) spEL0=0x\\(hx(spEL0)) spEL1=0x\\(hx(spEL1)) ttbr0el1=0x\\(hx(ttbr0EL1)) ttbr1el1=0x\\(hx(ttbr1EL1)) ttbr0el2=0x\\(hx(ttbr0EL2)) pc=0x\\(hx(pc)) lr=0x\\(hx(registers[30])) excElr=0x\\(hx(lastExceptionELR)) excVec=0x\\(hx(lastExceptionVector))\\(msrInfo) | \\(regs)"
        p25SpLog(s)
        p25SpFired = true
        halted = true
    }
    private func p25SpNoteTransition(kind: String, faultPC: UInt64, word: UInt32) {
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        if p25TransitionLogged >= 8 { return }
        p25TransitionLogged &+= 1
        p25SpLog("instr=\\(instructionsExecuted) ev=TRANSITION kind=\\(kind) faultPC=0x\\(hx(faultPC)) word=0x\\(hx(UInt64(word))) el=\\(currentEL) spEL0Prev=0x\\(hx(p25PrevSpEL0)) spEL0=0x\\(hx(spEL0)) ttbr0el1=0x\\(hx(ttbr0EL1))")
    }
    private func p25SpNoteRealign() {
        func hx(_ v: UInt64) -> String { String(v, radix: 16) }
        if p25TransitionLogged >= 8 { return }
        p25TransitionLogged &+= 1
        p25SpLog("instr=\\(instructionsExecuted) ev=REALIGN el=\\(currentEL) spEL0Prev=0x\\(hx(p25PrevSpEL0)) spEL0=0x\\(hx(spEL0))")
    }
    private func p25SpPeekWord(_ va: UInt64) -> UInt32 {
        if let pa = debugTranslate(va), let b = physReadBytes(pa, 4), b.count == 4 {
            return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
        return 0xFFFF_FFFF
    }
    // Step-start check: an edge here means the change happened during
    // exception entry (or inter-step code); a misaligned SP at EL0 means
    // userspace is about to execute with a bad SP.
    private func p25SpCheckStart(instructionPC: UInt64) {
        let prevAligned = (p25PrevSpEL0 & 15) == 0
        let curMisaligned = (spEL0 & 15) != 0
        if prevAligned && curMisaligned {
            if p25UserspaceStarted {
                p25SpFire(kind: "start", faultPC: lastExceptionELR, word: p25SpPeekWord(lastExceptionELR))
            } else {
                p25SpNoteTransition(kind: "start", faultPC: lastExceptionELR, word: p25SpPeekWord(lastExceptionELR))
            }
            p25PrevSpEL0 = spEL0
            return
        }
        if !prevAligned && !curMisaligned {
            p25SpNoteRealign()
        }
        if currentEL == 0 && curMisaligned {
            p25SpFire(kind: "el0-exec", faultPC: instructionPC, word: p25SpPeekWord(instructionPC))
            p25PrevSpEL0 = spEL0
            return
        }
        p25PrevSpEL0 = spEL0
    }
    // Step-end check: the faulting instruction is the one just executed.
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
src = src.replace(anchor6, block6, 1)

open(path, "w").write(src)
print("p25 sptrace patch applied")
