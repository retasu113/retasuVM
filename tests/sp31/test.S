.globl _start
_start:
    // SP = 0x7004EE10
    movz x9, #0xEE10
    movk x9, #0x7004, lsl #16
    mov sp, x9
    movz x20, #0x4000
    // A: NEG (SUB shifted, Rn=31) -> x11 must be 0xFFFFFFFFFFFFC000 (XZR source)
    sub x11, xzr, x20
    movz x12, #0xC000
    movk x12, #0xFFFF, lsl #16
    movk x12, #0xFFFF, lsl #32
    movk x12, #0xFFFF, lsl #48
    cmp x11, x12
    b.ne fail
    // B: CMP sp, x0 (extended form) with x0 == SP -> Z=1
    mov x0, x9
    cmp sp, x0
    b.ne fail
    // C: SUB immediate sp, sp, #0x40 -> SP = 0x7004EDD0
    sub sp, sp, #0x40
    mov x11, sp
    movz x12, #0xEDD0
    movk x12, #0x7004, lsl #16
    cmp x11, x12
    b.ne fail
    // D: SUB shifted with Rd=31 (discarded, SP unchanged): sub xzr-form via "sub x31, sp?? "
    // shifted form cannot encode SP source; use rn=x9: sub w31/x31 dest discard
    sub x31, x9, x20
    mov x11, sp
    cmp x11, x12
    b.ne fail
    movz x0, #42
    b exit
fail:
    movz x0, #1
exit:
    movz x8, #93
    svc #0
