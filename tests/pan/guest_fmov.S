// Phase 20 differential guest: AdvSIMD modified-immediate cmode=15 (FMOV vector immediate).
// Bare-metal AArch64, loaded at 0x40000000, MMU off, EL1.
// Executes test words, stores vector results + fault records to RAM slots,
// formats an ASCII log, sets DONE, dumps the log to the PL011 (QEMU virt only),
// then semihosting-exits (QEMU) / spins. Same conventions as guest.S (phase 18).

#define MB        0x40008000
#define MB_DONE   0x40008000
#define MB_LOGLEN 0x40008008
#define MB_SLOT   0x40008040
#define MB_LOGPTR 0x40008048
#define MB_SPUR   0x40008050
#define MB_FLTIDX 0x40008058
#define MB_LOG    0x40008100
#define SLOT_RES  0x40009000
#define SLOT_FLT  0x40009100

    .text
    .globl _start
_start:
    ldr x0, =0x4000f000
    mov sp, x0
    ldr x0, =vectors
    msr vbar_el1, x0
    isb
    // Enable FP/SIMD: CPACR_EL1.FPEN=0b11. QEMU -cpu max resets CPACR_EL1 to 0,
    // so AdvSIMD/FP instructions trap with EC 0x07 until enabled. Our engine
    // has no CPACR trap, so the MSR is a harmless stored write there.
    ldr x0, =0x00300000
    msr cpacr_el1, x0
    isb
    // Clear mailbox 0x8000..0x9200.
    ldr x0, =0x40008000
    ldr x1, =0x40009200
1:  str xzr, [x0], #8
    cmp x0, x1
    b.lo 1b
    ldr x0, =MB_LOG
    ldr x1, =MB_LOGPTR
    str x0, [x1]

    // ---- T1: the fsck word: FMOV v0.2d, #-1.0 (raw word 0x6f07f600)
    ldr x0, =str_t1
    bl puts
    .inst 0x6f07f600
    umov x0, v0.d[0]
    umov x1, v0.d[1]
    ldr x2, =SLOT_RES
    str x0, [x2]
    str x1, [x2, #8]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #8]
    bl puthex
    ldr x0, =str_nl
    bl puts

    // ---- T2: FMOV v1.4s, #1.0 (cmode=15, op=0, q=1)
    ldr x0, =str_t2
    bl puts
    fmov v1.4s, #1.0
    umov w0, v1.s[0]
    umov w1, v1.s[1]
    umov w2, v1.s[2]
    umov w3, v1.s[3]
    ldr x4, =SLOT_RES
    str x0, [x4, #0x10]
    str x1, [x4, #0x18]
    str x2, [x4, #0x20]
    str x3, [x4, #0x28]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x18]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x20]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x28]
    bl puthex
    ldr x0, =str_nl
    bl puts

    // ---- T3: FMOV v2.2d, #0.5 (cmode=15, op=1, q=1)
    ldr x0, =str_t3
    bl puts
    fmov v2.2d, #0.5
    umov x0, v2.d[0]
    umov x1, v2.d[1]
    ldr x2, =SLOT_RES
    str x0, [x2, #0x30]
    str x1, [x2, #0x38]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x38]
    bl puthex
    ldr x0, =str_nl
    bl puts

    // ---- T4: MOVI v3.16b, #0xff (cmode=14, op=0 — existing behavior, regression)
    ldr x0, =str_t4
    bl puts
    movi v3.16b, #0xff
    umov x0, v3.d[0]
    umov x1, v3.d[1]
    ldr x2, =SLOT_RES
    str x0, [x2, #0x40]
    str x1, [x2, #0x48]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x48]
    bl puthex
    ldr x0, =str_nl
    bl puts

    // ---- T5: unallocated control: cmode=15, op=1, q=0 (raw 0x2f07f600) — must fault on BOTH
    ldr x0, =str_t5
    bl puts
    ldr x5, =MB_FLTIDX
    ldr x5, [x5]
    .inst 0x2f07f600
    ldr x6, =MB_FLTIDX
    ldr x6, [x6]
    cmp x5, x6
    b.eq 1f
    ldr x0, =str_faulted
    bl puts
    b 2f
1:  ldr x0, =str_nofault
    bl puts
2:
    // ---- T6: event-2 word: 0xe7ffdeff — must fault on BOTH (genuinely unallocated)
    ldr x0, =str_t6
    bl puts
    ldr x5, =MB_FLTIDX
    ldr x5, [x5]
    .inst 0xe7ffdeff
    ldr x6, =MB_FLTIDX
    ldr x6, [x6]
    cmp x5, x6
    b.eq 1f
    ldr x0, =str_faulted
    bl puts
    b 2f
1:  ldr x0, =str_nofault
    bl puts
2:

    // ---- T7: FMOV v4.4s, #-2.0 (cmode=15, op=0, q=1)
    ldr x0, =str_t7
    bl puts
    fmov v4.4s, #-2.0
    umov w0, v4.s[0]
    umov w1, v4.s[3]
    ldr x2, =SLOT_RES
    str x0, [x2, #0x50]
    str x1, [x2, #0x58]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =SLOT_RES
    ldr x0, [x0, #0x58]
    bl puthex
    ldr x0, =str_nl
    bl puts

    // ---- fault records
    ldr x0, =str_flt
    bl puts
    ldr x19, =MB_FLTIDX
    ldr x19, [x19]
    mov x0, x19
    bl putd
    ldr x0, =str_nl
    bl puts
    ldr x20, =SLOT_FLT
    ldr x21, =0
1:  cmp x21, x19
    b.hs 2f
    ldr x0, =str_fesr
    bl puts
    ldr x0, [x20]
    bl puthex
    ldr x0, =str_sp
    bl puts
    ldr x0, =str_felr
    bl puts
    ldr x0, [x20, #8]
    bl puthex
    ldr x0, =str_nl
    bl puts
    add x20, x20, #16
    add x21, x21, #1
    b 1b
2:
    ldr x0, =str_spur
    bl puts
    ldr x1, =MB_SPUR
    ldrb w0, [x1]
    cmp w0, #0
    cset x0, ne
    bl putd
    ldr x0, =str_nl
    bl puts
    // DONE magic
    ldr x0, =MB_DONE
    ldr x1, =0x50414e21
    str w1, [x0]
    bl uart_dump
    mov x0, #0x18
    ldr x1, =exit_block
    hlt #0xf000
    b .

// ---- helpers (clobber x0-x4 only, unless noted) ----
puts:  // x0 = NUL-terminated string -> append to log
    ldr x1, =MB_LOGPTR
    ldr x1, [x1]
    mov x2, x0
1:  ldrb w3, [x2], #1
    cbz w3, 2f
    strb w3, [x1], #1
    b 1b
2:  ldr x3, =MB_LOGPTR
    str x1, [x3]
    ldr x3, =MB_LOGLEN
    ldr x0, =MB_LOG
    sub x1, x1, x0
    str x1, [x3]
    ret
putd:  // x0 = 0/1 -> append '0'/'1'
    ldr x1, =MB_LOGPTR
    ldr x1, [x1]
    add w0, w0, #0x30
    strb w0, [x1], #1
    ldr x3, =MB_LOGPTR
    str x1, [x3]
    ldr x3, =MB_LOGLEN
    ldr x0, =MB_LOG
    sub x1, x1, x0
    str x1, [x3]
    ret
puthex:  // x0 = 64-bit value -> append 16 lowercase hex digits
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    ldr x1, =MB_LOGPTR
    ldr x1, [x1]
    mov x2, #60
1:  lsr x3, x19, x2
    and x3, x3, #0xf
    cmp x3, #10
    add x3, x3, #0x30
    b.lo 2f
    add x3, x3, #39
2:  strb w3, [x1], #1
    subs x2, x2, #4
    b.pl 1b
    ldr x3, =MB_LOGPTR
    str x1, [x3]
    ldr x3, =MB_LOGLEN
    ldr x0, =MB_LOG
    sub x1, x1, x0
    str x1, [x3]
    ldp x19, x30, [sp], #16
    ret
uart_dump:
    ldr x2, =MB_LOG
    ldr x3, =MB_LOGLEN
    ldr x3, [x3]
    add x4, x2, x3
    ldr x5, =0x09000000
1:  cmp x2, x4
    b.eq 2f
    ldrb w6, [x2], #1
    strb w6, [x5]
    b 1b
2:  ret

    .org 0x1000
    .balign 2048
vectors:
    .org vectors + 0x000
    b safety
    .org vectors + 0x080
    b safety
    .org vectors + 0x100
    b safety
    .org vectors + 0x180
    b safety
    .org vectors + 0x200
    b sync_el1h
    .org vectors + 0x280
    b safety
    .org vectors + 0x300
    b safety
    .org vectors + 0x380
    b safety
    .org vectors + 0x400
    b safety
    .org vectors + 0x480
    b safety
    .org vectors + 0x500
    b safety
    .org vectors + 0x580
    b safety
    .org vectors + 0x600
    b safety
    .org vectors + 0x680
    b safety
    .org vectors + 0x700
    b safety
    .org vectors + 0x780
    b safety

    .org 0x2000
// Current-EL (EL1h) sync handler: record ESR+ELR, skip the faulting insn.
sync_el1h:
    mrs x10, esr_el1
    mrs x11, elr_el1
    ldr x12, =MB_FLTIDX
    ldr x13, [x12]
    ldr x14, =SLOT_FLT
    add x14, x14, x13, lsl #4
    str x10, [x14]
    str x11, [x14, #8]
    add x13, x13, #1
    str x13, [x12]
    add x11, x11, #4
    msr elr_el1, x11
    eret
safety:
    ldr x10, =MB_SPUR
    mov x11, #0xee
    strb w11, [x10]
    eret

exit_block:
    .quad 0x20026
    .quad 0

    .section .rodata
str_t1:   .asciz "T1 "
str_t2:   .asciz "T2 "
str_t3:   .asciz "T3 "
str_t4:   .asciz "T4 "
str_t5:   .asciz "T5 "
str_t6:   .asciz "T6 "
str_t7:   .asciz "T7 "
str_sp:   .asciz " "
str_nl:   .asciz "\n"
str_nofault: .asciz "NOFAULT\n"
str_faulted: .asciz "FAULTED\n"
str_flt:  .asciz "FAULTS="
str_fesr: .asciz "ESR="
str_felr: .asciz " ELR="
str_spur: .asciz "SPUR="
