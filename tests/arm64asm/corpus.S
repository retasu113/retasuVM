// ARM64Assembler と clang のエンコーディングを突き合わせるためのコーパス。
// 両方で受理できる共通構文のみを使う。
    .text
    .globl _start
_start:
    nop
    wfi
    eret
    svc #0x42
    mov x0, x1
    mov w2, w3
    mov x4, sp
    mov sp, x5
    mov x6, #255
    mov x7, #-1
    movz x9, #0xBEEF
    movz x10, #0x1234, lsl #32
    movn w11, #0xFF
    movk x12, #0xABCD, lsl #16
    add x0, x1, #100
    add x0, x1, #0x1000
    sub x2, x3, #7
    adds x4, x5, #1
    subs w6, w7, #2
    add x8, x9, x10
    sub x11, x12, x13, lsl #3
    add x14, x15, x16, lsr #5
    adds w17, w18, w19
    subs x20, x21, x22, asr #1
    and x0, x1, x2
    orr x3, x4, x5, ror #7
    eor w6, w7, w8
    ands x9, x10, x11
    and x12, x13, #0xFF00FF00FF00FF00
    orr w14, w15, #0xF0F0F0F0
    cmp x0, #42
    cmp x1, x2
    cmn w3, #9
    tst x4, #0x8000000000000000
    tst x5, x6
    neg x7, x8
    mvn w9, w10
    sxtb x11, w12
    sxth x13, w14
    sxtw x15, w16
    uxtb w17, w18
    uxth w19, w20
    cset x21, eq
    cset w22, lt
    csel x23, x24, x25, ne
    mul x26, x27, x28
    madd x29, x30, x0, x1
    msub x2, x3, x4, x5
    udiv x6, x7, x8
    sdiv w9, w10, w11
    lsl x12, x13, x14
    lsr w15, w16, w17
    asr x18, x19, x20
    ror x21, x22, x23
    lsl x24, x25, #9
    lsr x26, x27, #63
    asr w28, w29, #31
    ror x30, x0, #17
    clz x1, x2
    clz w3, w4
    rbit x5, x6
    rev x7, x8
    rev w9, w10
    adr x11, target
    adrp x12, target
    b target
    bl target
    b.eq target
    b.lt target
    cbz x13, target
    cbnz w14, target
    tbz x15, #37, target
    tbnz w16, #3, target
    ret
    br x17
    blr x18
    ldr x0, [x1]
    ldr w2, [x3, #8]
    ldr x4, [x5, #16]!
    ldr x6, [x7], #24
    ldrb w8, [x9, #3]
    ldrh w10, [x11, #4]
    ldrsb x12, [x13, #1]
    ldrsh x14, [x15, #2]
    ldrsw x16, [x17, #4]
    str x18, [x19, #32]
    strb w20, [x21]
    strh w22, [x23, #6]
    ldr x24, [x25, x26]
    ldr w27, [x28, w29, sxtw #2]
    str x30, [x0, x1, lsl #3]
    ldur x2, [x3, #-8]
    stur w4, [x5, #7]
    ldr x6, =0x0123456789ABCDEF
    ldr x7, target
    ldp x8, x9, [x10]
    ldp x11, x12, [x13, #16]
    ldp x14, x15, [x16], #32
    stp x17, x18, [x19, #-16]!
    stp w20, w21, [x22, #8]
target:
    ret
    mrs x0, sctlr_el1
    msr ttbr0_el1, x1
    mrs x2, cntfrq_el0
    msr cntp_tval_el0, x3
    msr cntp_ctl_el0, x4
    mrs x5, vbar_el1
    msr vbar_el1, x5
    msr daifclr, #1
    msr daifset, #2
    msr spsel, #1
    mrs x6, currentel
    mrs x7, esr_el1
    msr elr_el1, x8
