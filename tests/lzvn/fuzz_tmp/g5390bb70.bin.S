
    .text
    .globl _start
_start:
    mov x0, #(3 << 20)
    msr cpacr_el1, x0
    mrs x0, sctlr_el1
    bic x0, x0, #2
    msr sctlr_el1, x0
    isb
    ldr x0, =0x40300000
    mov sp, x0
    // fill scratch (0x40210000, 512 bytes) with a pattern
    ldr x0, =0x40210000
    ldr x1, =0xA5A5A5A5A5A5A5A5
    mov x2, #64
1:  str x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b
    // load test state x0..x28 from the pattern table
    ldr x29, =state_table
    ldp x0, x1, [x29, #0]
    ldp x2, x3, [x29, #16]
    ldp x4, x5, [x29, #32]
    ldp x6, x7, [x29, #48]
    ldp x8, x9, [x29, #64]
    ldp x10, x11, [x29, #80]
    ldp x12, x13, [x29, #96]
    ldp x14, x15, [x29, #112]
    ldp x16, x17, [x29, #128]
    ldp x18, x19, [x29, #144]
    ldp x20, x21, [x29, #160]
    ldp x22, x23, [x29, #176]
    ldp x24, x25, [x29, #192]
    ldp x26, x27, [x29, #208]
    ldr x28, [x29, #224]
    // set NZCV = 0b0110 (N=0,Z=1,C=1,V=0) via a compare: cmp of equal
    cmp x0, x0
    // x29 = mailbox base
    ldr x29, =0x40200000
    .word 0x5390bb70
    // ---- record (record_pc) ----
    stp x0, x1, [x29, #0x100]
    stp x2, x3, [x29, #0x110]
    stp x4, x5, [x29, #0x120]
    stp x6, x7, [x29, #0x130]
    stp x8, x9, [x29, #0x140]
    stp x10, x11, [x29, #0x150]
    stp x12, x13, [x29, #0x160]
    stp x14, x15, [x29, #0x170]
    stp x16, x17, [x29, #0x180]
    stp x18, x19, [x29, #0x190]
    stp x20, x21, [x29, #0x1a0]
    stp x22, x23, [x29, #0x1b0]
    stp x24, x25, [x29, #0x1c0]
    stp x26, x27, [x29, #0x1d0]
    str x28, [x29, #0x1e0]
    // capture flags: 14 cset probes packed into x0
    cset w0, eq
    cset w1, ne
    orr w0, w0, w1, lsl #1
    cset w1, hs
    orr w0, w0, w1, lsl #2
    cset w1, lo
    orr w0, w0, w1, lsl #3
    cset w1, mi
    orr w0, w0, w1, lsl #4
    cset w1, pl
    orr w0, w0, w1, lsl #5
    cset w1, vs
    orr w0, w0, w1, lsl #6
    cset w1, vc
    orr w0, w0, w1, lsl #7
    cset w1, hi
    orr w0, w0, w1, lsl #8
    cset w1, ls
    orr w0, w0, w1, lsl #9
    cset w1, ge
    orr w0, w0, w1, lsl #10
    cset w1, lt
    orr w0, w0, w1, lsl #11
    cset w1, gt
    orr w0, w0, w1, lsl #12
    cset w1, le
    orr w0, w0, w1, lsl #13
    str x0, [x29, #0x1e8]
    // copy 128 bytes of scratch to mailbox+0x200
    ldr x0, =0x40210000
    add x3, x29, #0x200
    ldp x1, x2, [x0, #0]
    stp x1, x2, [x3, #0]
    ldp x1, x2, [x0, #16]
    stp x1, x2, [x3, #16]
    ldp x1, x2, [x0, #32]
    stp x1, x2, [x3, #32]
    ldp x1, x2, [x0, #48]
    stp x1, x2, [x3, #48]
    ldp x1, x2, [x0, #64]
    stp x1, x2, [x3, #64]
    ldp x1, x2, [x0, #80]
    stp x1, x2, [x3, #80]
    ldp x1, x2, [x0, #96]
    stp x1, x2, [x3, #96]
    ldp x1, x2, [x0, #112]
    stp x1, x2, [x3, #112]
    // DONE
    ldr w0, =0x4C5A564E
    str w0, [x29]
    b .
    .section .rodata
state_table:
    .quad 0x40210000, 0x40210008, 0x40210010, 0x40210018
    .quad 0x40210020, 0x40210028, 0x40210030, 0x40210038
    .quad 0x10, 0xFFFFFFFFFFFFFFFF, 0x8000000000000000, 0x7FFFFFFFFFFFFFFF
    .quad 0x123456789ABCDEF0, 0x0, 0x1, 0x40
    .quad 0x40210100, 0x40210040, 3, 5
    .quad 0xDEADBEEF, 0x100, 0x40210000, 0x20
    .quad 0x5555555555555555, 0xAAAAAAAAAAAAAAAA, 0x4020FFC0, 0x40210080
    .quad 0x40210000
