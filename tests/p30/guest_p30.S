// Phase 30 differential guest: logical-immediate (AND/ORR/EOR) with Rd=31.
// ARM ARM: for AND/ORR/EOR (immediate) the destination may be SP (<Xd|SP>);
// for ANDS the destination is a plain register (Rd=31 discards, flags set).
// QEMU gen_rri_log: tcg_rd = set_cc ? cpu_reg(rd) : cpu_reg_sp(rd).
// Bare-metal AArch64, loaded at 0x40000000, MMU off, EL1 (SPSel=1).
// Stores 8 result qwords at 0x40009000, sets DONE, dumps an ASCII log to
// the PL011 (QEMU virt only), then semihosting-exits (QEMU) / spins.

#define MB_DONE   0x40008000
#define MB_LOGLEN 0x40008008
#define MB_FAULTS 0x40008058
#define MB_LOG    0x40008100
#define SLOT      0x40009000
#define UART      0x09000000

    .text
    .globl _start
_start:
    ldr x0, =0x4000f000
    mov sp, x0
    ldr x0, =vectors
    msr vbar_el1, x0
    isb
    ldr x19, =SLOT

    // T1: AND (imm, 64-bit) to SP: 0x...AB8 & ~0xF -> 0x...AB0
    ldr x0, =0x4000EAB8
    mov sp, x0
    and sp, x0, #0xFFFFFFFFFFFFFFF0
    mov x1, sp
    str x1, [x19, #0]
    ldr x0, =0x4000f000
    mov sp, x0

    // T2: ORR (imm, 64-bit) to SP from XZR
    ldr x0, =0x4000EAB0
    mov sp, x0
    orr sp, xzr, #0x5555555555555555
    mov x1, sp
    str x1, [x19, #8]
    ldr x0, =0x4000f000
    mov sp, x0

    // T3: EOR (imm, 64-bit) to SP: 0x...AB0 ^ 0xFF -> 0x...A4F
    ldr x0, =0x4000EAB0
    mov sp, x0
    eor sp, x0, #0xFF
    mov x1, sp
    str x1, [x19, #16]
    ldr x0, =0x4000f000
    mov sp, x0

    // T4: ANDS with Rd=31 must NOT write SP (control; both engines agree)
    ldr x0, =0x4000EAB0
    mov sp, x0
    ldr x1, =0x12345678
    ands xzr, x1, #0xFF
    mov x1, sp
    str x1, [x19, #24]
    ldr x0, =0x4000f000
    mov sp, x0

    // T5: AND (imm, 32-bit / WSP) to SP: w0=0x4000EAB8 & 0xFFFFFFF0 -> SP=0x4000EAB0
    ldr x0, =0x4000E000
    mov sp, x0
    ldr x0, =0xDEAD4000EAB8
    and wsp, w0, #0xFFFFFFF0
    mov x1, sp
    str x1, [x19, #32]
    ldr x0, =0x4000f000
    mov sp, x0

    // T6: fsck `start` verbatim pattern: mov x0, sp ; and sp, x0, #~0xF
    ldr x0, =0x4000EAB8
    mov sp, x0
    mov x0, sp
    and sp, x0, #0xFFFFFFFFFFFFFFF0
    mov x1, sp
    str x1, [x19, #40]
    ldr x0, =0x4000f000
    mov sp, x0

    // T7: ADD (imm) to SP (control; known-good path)
    ldr x0, =0x4000EAB0
    mov sp, x0
    add sp, sp, #8
    mov x1, sp
    str x1, [x19, #48]
    ldr x0, =0x4000f000
    mov sp, x0

    // T8: Rn=31 in logical imm is XZR (assembler rejects `sp` as source;
    // control against over-fix: post-fix engine must still read Rn=31 as 0)
    ldr x0, =0x4000EAB0
    mov sp, x0
    and x2, xzr, #0xFF
    str x2, [x19, #56]
    ldr x0, =0x4000f000
    mov sp, x0

    // DONE magic
    ldr x0, =0x50333021
    ldr x1, =MB_DONE
    str w0, [x1]

    // ASCII log "Tn=<16 hex>\n" x8 -> MB_LOG + PL011
    ldr x20, =MB_LOG
    mov x22, #0
1:
    mov w0, #'T'
    bl emit
    add w0, w22, #'1'
    bl emit
    mov w0, #'='
    bl emit
    ldr x0, [x19, x22, lsl #3]
    bl emit_hex64
    mov w0, #'\n'
    bl emit
    add x22, x22, #1
    cmp x22, #8
    b.lt 1b
    ldr x0, =MB_LOG
    sub x0, x20, x0
    ldr x1, =MB_LOGLEN
    str x0, [x1]

    // semihosting exit (QEMU); our engine faults/spins after DONE is set
    mov x0, #0x18
    ldr x1, =0x20026
    hlt #0xf000
2:  b 2b

emit:   // w0 = char -> append [x20], write UART; clobbers x3
    strb w0, [x20], #1
    ldr x3, =UART
    strb w0, [x3]
    ret

emit_hex64:  // x0 = value -> 16 hex digits via emit; saves lr in x25
    mov x25, x30
    mov x4, x0
    mov x5, #60
3:
    mov x0, x4
    lsr x0, x0, x5
    and x0, x0, #0xF
    cmp x0, #10
    b.lt 4f
    add x0, x0, #('a' - 10)
    b 5f
4:  add x0, x0, #'0'
5:  bl emit
    sub x5, x5, #4
    cmp x5, #0
    b.ge 3b
    mov x30, x25
    ret

// Minimal vector table: every entry -> sync_handler (record + skip insn).
    .align 11
vectors:
    .rept 16
    b sync_handler
    .align 7
    .endr

sync_handler:
    ldr x0, =MB_FAULTS
    ldr x1, [x0]
    add x1, x1, #1
    str x1, [x0]
    mrs x0, elr_el1
    add x0, x0, #4
    msr elr_el1, x0
    eret
