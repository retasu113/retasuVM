
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    ldr x19, =vecA
    ldr x20, =vecB
    ldr x21, =vecACC
    ldr x28, =results

.macro CASE op:vararg
    ldr q5, [x19]
    ldr q7, [x20]
    ldr q2, [x21]
    \op
    str q2, [x28], #16
.endm

.macro CASE2 op:vararg
    ldr x22, =vecC
    ldr x23, =vecD
    ldr q5, [x22]
    ldr q7, [x23]
    ldr q2, [x21]
    \op
    str q2, [x28], #16
.endm

    // ---- long forms (Q=0 low half, Q=1 high half) ----
    CASE saddl v2.8h, v5.8b, v7.8b
    CASE saddl2 v2.8h, v5.16b, v7.16b
    CASE uaddl v2.4s, v5.4h, v7.4h
    CASE uaddl2 v2.4s, v5.8h, v7.8h
    CASE saddl v2.2d, v5.2s, v7.2s
    CASE saddl2 v2.2d, v5.4s, v7.4s
    CASE ssubl v2.8h, v5.8b, v7.8b
    CASE usubl2 v2.2d, v5.4s, v7.4s
    CASE sabdl v2.4s, v5.4h, v7.4h
    CASE uabdl2 v2.2d, v5.4s, v7.4s
    CASE sabal v2.2d, v5.2s, v7.2s
    CASE uabal2 v2.4s, v5.8h, v7.8h
    CASE smull v2.8h, v5.8b, v7.8b
    CASE umull2 v2.2d, v5.4s, v7.4s
    CASE smlal v2.4s, v5.4h, v7.4h
    CASE umlal2 v2.2d, v5.4s, v7.4s
    CASE smlsl v2.2d, v5.2s, v7.2s
    CASE umlsl2 v2.8h, v5.16b, v7.16b
    CASE sqdmull v2.2d, v5.2s, v7.2s
    CASE sqdmull2 v2.4s, v5.8h, v7.8h
    CASE sqdmlal v2.4s, v5.4h, v7.4h
    CASE sqdmlsl2 v2.2d, v5.4s, v7.4s
    // ---- wide forms (Rn wide) ----
    CASE saddw v2.4s, v2.4s, v7.4h
    CASE saddw2 v2.4s, v2.4s, v7.8h
    CASE uaddw v2.2d, v2.2d, v7.2s
    CASE ssubw v2.8h, v2.8h, v7.8b
    CASE usubw2 v2.2d, v2.2d, v7.4s
    CASE saddw v2.8h, v2.8h, v7.8b
    CASE ssubw2 v2.4s, v2.4s, v7.8h
    // ---- PMULL ----
    CASE pmull v2.8h, v5.8b, v7.8b
    CASE pmull2 v2.8h, v5.16b, v7.16b
    CASE pmull v2.1q, v5.1d, v7.1d
    // ---- saturation edges (vecC/vecD) ----
    CASE2 sqdmull v2.2d, v5.2s, v7.2s
    CASE2 sqdmull v2.4s, v5.4h, v7.4h
    CASE2 sqdmlal v2.2d, v5.2s, v7.2s
    CASE2 sqdmlsl v2.4s, v5.4h, v7.4h
    CASE2 smull v2.2d, v5.2s, v7.2s
    CASE2 saddl v2.2d, v5.2s, v7.2s

    // dump results (word total in x21; putc/print_hex32 clobber x22-x27)
    ldr x28, =results
    ldr x21, =results_end
    sub x21, x21, x28
    lsr x21, x21, #2
    mov x19, #0
1:  ldr w0, [x28], #4
    bl print_hex32
    mov w0, #0x20
    bl putc
    add x19, x19, #1
    and x25, x19, #3
    cbnz x25, 2f
    mov w0, #0x0A
    bl putc
2:  cmp x19, x21
    b.lt 1b

#ifdef ENGINE
    mov x0, #0
    svc #10
#else
    mov x8, #93
    mov x0, #0
    svc #0
#endif
    b .

putc:
#ifdef ENGINE
    str w0, [x12]
    ret
#else
    ldr x22, =linebuf
    ldr x23, =linelen
    ldr x24, [x23]
    strb w0, [x22, x24]
    add x24, x24, #1
    str x24, [x23]
    cmp w0, #0x0A
    b.ne 3f
    mov x8, #64
    mov x0, #1
    mov x1, x22
    mov x2, x24
    svc #0
    str xzr, [x23]
3:  ret
#endif

print_hex32:
    mov x25, x30
    mov w26, w0
    mov w27, #28
6:  lsr w0, w26, w27
    and w0, w0, #0xF
    cmp w0, #10
    b.lt 7f
    add w0, w0, #0x37
    b 8f
7:  add w0, w0, #0x30
8:  bl putc
    subs w27, w27, #4
    b.ge 6b
    mov x30, x25
    ret

    .data
vecA:   .byte 0x80,0x7F,0xFF,0x01,0x00,0xFF,0x40,0xC0,0x55,0xAA,0x33,0xCC,0x0F,0xF0,0x5A,0xA5
vecB:   .byte 0x81,0x02,0xFE,0x7F,0xFF,0x00,0x80,0x01,0x01,0xFF,0x02,0x80,0xC3,0x3C,0x99,0x66
vecACC: .byte 0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0,0xC0,0xD0,0xE0,0xF0,0x00
vecC:   .byte 0x00,0x00,0x00,0x80,0x00,0x00,0x00,0x80,0xFF,0xFF,0xFF,0x7F,0x01,0x00,0xFF,0xFF
vecD:   .byte 0x00,0x00,0x00,0x80,0xFF,0xFF,0xFF,0xFF,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x80
    .bss
    .align 4
results: .space 1024
results_end:
    .align 4
linebuf: .space 256
linelen: .space 8
