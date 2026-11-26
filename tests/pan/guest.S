// Phase 18 differential guest: exception-entry PAN/UAO semantics.
// Bare-metal AArch64, loaded at 0x40000000, MMU off.
// Records MRS PAN / MRS UAO / SPSR_EL1.PAN / SPSR_EL1.UAO observed
// INSIDE the exception handler into RAM slots, formats an ASCII log
// into a RAM buffer, sets DONE, dumps the log to the PL011
// (0x09000000, QEMU virt only), then semihosting-exits (QEMU) /
// spins. Two builds: EL1 kernel (default) and VHE (-DVHE).

#define MB        0x40008000
#define MB_DONE   0x40008000
#define MB_LOGLEN 0x40008008
#define MB_SLOT   0x40008040
#define MB_LOGPTR 0x40008048
#define MB_SPUR   0x40008050
#define MB_CONT   0x40008058
#define MB_LOG    0x40008100
#define SLOT_T1   0x40009000
#define SLOT_T5   0x40009010
#define SLOT_T3   0x40009020
#define SLOT_T2   0x40009030
#define SLOT_T4   0x40009040
#define SLOT_T7   0x40009050
#define SCTLR_BASE 0x30100000
#define SCTLR_SPAN (1 << 23)

#ifdef VHE
#define FINISH_SPSR 0x3c9
#else
#define FINISH_SPSR 0x3c5
#endif


// clang-15 IAS has no PAN/UAO MSR-immediate names; raw encodings
// (MSR imm: op1=0, CRn=4, op2=4 PAN / op2=3 UAO, imm4 at [11:8]).
.macro MSR_PAN imm
    .inst 0xD500409F + (\imm << 8)
.endm
.macro MSR_UAO imm
    .inst 0xD500407F + (\imm << 8)
.endm

    .text
    .globl _start
_start:
    ldr x0, =0x4000f000
    mov sp, x0
    ldr x0, =0x4000e000
    msr sp_el0, x0
#ifdef VHE
    // Pre-HCR writes: land in EL1 storage (ours) / EL1 regs (QEMU).
    ldr x0, =vectors
    msr vbar_el1, x0
    bl span0
    // HCR_EL2 = RW(31) | E2H(34) | TGE(27)
    ldr x0, =0x488000000
    msr hcr_el2, x0
    isb
    // Post-HCR writes: redirected to EL2 storage on both engines.
    ldr x0, =vectors
    msr vbar_el1, x0
    bl span0
#else
    ldr x0, =vectors
    msr vbar_el1, x0
    isb
#endif
    // Clear mailbox 0x8000..0x9100.
    ldr x0, =0x40008000
    ldr x1, =0x40009100
1:  str xzr, [x0], #8
    cmp x0, x1
    b.lo 1b
    // logptr = MB_LOG
    ldr x0, =MB_LOG
    ldr x1, =MB_LOGPTR
    str x0, [x1]

#ifdef VHE
    // ---- T7: EL0 trip under VHE, SPAN=0 -> expect PAN=1, UAO=0
    ldr x0, =SLOT_T7
    bl setslot
    ldr x0, =after_t7
    ldr x1, =MB_CONT
    str x0, [x1]
    ldr x0, =el0_code
    msr elr_el1, x0
    mov x0, #0
    msr spsr_el1, x0
    eret
after_t7:
    ldr x0, =str_t7
    bl puts
    ldr x0, =SLOT_T7
    bl putslot
#else
    // ---- T1: EL1, SPAN=0, PAN=0 UAO=1 -> expect PAN=1 UAO=0
    bl span0
    ldr x0, =SLOT_T1
    bl setslot
    MSR_PAN 0
    MSR_UAO 1
    svc #0x80
    // ---- T5: EL1, SPAN=0, PAN=1 UAO=1 -> expect PAN=1 UAO=0
    ldr x0, =SLOT_T5
    bl setslot
    MSR_PAN 1
    MSR_UAO 1
    svc #0x80
    // ---- T3: EL1, SPAN=1, PAN=0 UAO=1 -> expect PAN=0, UAO=0
    bl span1
    ldr x0, =SLOT_T3
    bl setslot
    MSR_PAN 0
    MSR_UAO 1
    svc #0x80
    // ---- T2: EL0 trip, SPAN=0, SPSR.PAN=0 -> expect PAN=1 UAO=0
    bl span0
    ldr x0, =SLOT_T2
    bl setslot
    ldr x0, =after_t2
    ldr x1, =MB_CONT
    str x0, [x1]
    ldr x0, =el0_code
    msr elr_el1, x0
    mov x0, #0
    msr spsr_el1, x0
    eret
after_t2:
    // ---- T4: EL0 trip, SPAN=1, SPSR.PAN=0 -> expect PAN=0 UAO=0
    bl span1
    ldr x0, =SLOT_T4
    bl setslot
    ldr x0, =after_t4
    ldr x1, =MB_CONT
    str x0, [x1]
    ldr x0, =el0_code
    msr elr_el1, x0
    mov x0, #0
    msr spsr_el1, x0
    eret
after_t4:
    bl span0
    // ---- format log
    ldr x0, =str_t1
    bl puts
    ldr x0, =SLOT_T1
    bl putslot
    ldr x0, =str_t5
    bl puts
    ldr x0, =SLOT_T5
    bl putslot
    ldr x0, =str_t3
    bl puts
    ldr x0, =SLOT_T3
    bl putslot
    ldr x0, =str_t2
    bl puts
    ldr x0, =SLOT_T2
    bl putslot
    ldr x0, =str_t4
    bl puts
    ldr x0, =SLOT_T4
    bl putslot
#endif
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
    // UART dump (QEMU virt PL011; on retasuVM this store is
    // out-of-RAM and the harness stops at DONE / on the fault).
    bl uart_dump
    // Semihosting exit (QEMU); ignored/spun elsewhere.
    mov x0, #0x18
    ldr x1, =exit_block
    hlt #0xf000
    b .

// ---- helpers (clobber x0-x4 only) ----
setslot:
    ldr x1, =MB_SLOT
    str x0, [x1]
    ret
span0:
    ldr x0, =SCTLR_BASE
    msr sctlr_el1, x0
    isb
    ret
span1:
    ldr x0, =(SCTLR_BASE + SCTLR_SPAN)
    msr sctlr_el1, x0
    isb
    ret
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
putslot:  // x0 = slot addr -> "PAN=d UAO=d SPSRPAN=d SPSRUAO=d\n"
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    ldr x0, =str_pan
    bl puts
    ldrb w0, [x19]
    bl putd
    ldr x0, =str_uao
    bl puts
    ldrb w0, [x19, #1]
    bl putd
    ldr x0, =str_span
    bl puts
    ldrb w0, [x19, #2]
    bl putd
    ldr x0, =str_suao
    bl puts
    ldrb w0, [x19, #3]
    bl putd
    ldr x0, =str_nl
    bl puts
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
    b sync_lower
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
// Same-EL (EL1h) sync handler: record PAN/UAO/SPSR bits, return.
sync_el1h:
    mrs x10, S3_0_C4_C2_3
    mrs x11, S3_0_C4_C2_4
    mrs x12, spsr_el1
    ldr x13, =MB_SLOT
    ldr x13, [x13]
    cmp x10, #0
    cset x10, ne
    strb w10, [x13]
    cmp x11, #0
    cset x11, ne
    strb w11, [x13, #1]
    lsr x14, x12, #22
    and x14, x14, #1
    strb w14, [x13, #2]
    lsr x14, x12, #23
    and x14, x14, #1
    strb w14, [x13, #3]
    eret
// Lower-EL (EL0) sync handler: svc 0x80 = record + return to EL0;
// svc 0x81 = finish: rewrite ELR/SPSR to the EL1/EL2 continuation.
sync_lower:
    mrs x15, esr_el1
    and x16, x15, #0xffff
    cmp x16, #0x81
    b.eq lower_finish
    lsr x16, x15, #26
    cmp x16, #0x15
    b.ne safety
    mrs x10, S3_0_C4_C2_3
    mrs x11, S3_0_C4_C2_4
    mrs x12, spsr_el1
    ldr x13, =MB_SLOT
    ldr x13, [x13]
    cmp x10, #0
    cset x10, ne
    strb w10, [x13]
    cmp x11, #0
    cset x11, ne
    strb w11, [x13, #1]
    lsr x14, x12, #22
    and x14, x14, #1
    strb w14, [x13, #2]
    lsr x14, x12, #23
    and x14, x14, #1
    strb w14, [x13, #3]
    eret
lower_finish:
    ldr x13, =MB_CONT
    ldr x13, [x13]
    msr elr_el1, x13
    ldr x13, =FINISH_SPSR
    msr spsr_el1, x13
    eret
safety:
    ldr x10, =MB_SPUR
    mov x11, #0xee
    strb w11, [x10]
    eret
el0_code:
    svc #0x80
    svc #0x81
    b .

exit_block:
    .quad 0x20026
    .quad 0

    .section .rodata
str_t1:   .asciz "T1 "
str_t5:   .asciz "T5 "
str_t3:   .asciz "T3 "
str_t2:   .asciz "T2 "
str_t4:   .asciz "T4 "
str_t7:   .asciz "T7 "
str_pan:  .asciz "PAN="
str_uao:  .asciz " UAO="
str_span: .asciz " SPSRPAN="
str_suao: .asciz " SPSRUAO="
str_spur: .asciz "SPUR="
str_nl:   .asciz "\n"
