
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

    // A H lanes = 0x8000 (-32768) x8; B H lanes = 0x8000 x8
    // term = sat32(2 * (-32768 * -32768)) = 0x7FFFFFFF
    // ACC S lanes = 7FFFFFFF, 80000000, 00000000, FFFFFFFF
    CASE sqdmlal v2.4s, v5.4h, v7.4h     // expect FFFFFFFF(sat) 80000000 7FFFFFFF 7FFFFFFE->sat? see oracle
    CASE sqdmlsl v2.4s, v5.4h, v7.4h     // acc - term, saturating
    CASE sqdmlal2 v2.4s, v5.8h, v7.8h
    CASE sqdmlsl2 v2.4s, v5.8h, v7.8h
    CASE sqdmlal v2.4s, v5.4h, v7.h[0]   // by-element
    CASE sqdmlsl v2.4s, v5.4h, v7.h[3]   // by-element
    CASE sqdmull v2.4s, v5.4h, v7.4h     // non-accumulating control
    // S->D forms: A S lanes = 80000000 x4, B S lanes = 80000000 x4, ACC D lanes = INT64 extremes
    CASE sqdmlal v2.2d, v5.2s, v7.2s
    CASE sqdmlsl v2.2d, v5.2s, v7.2s

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
vecA:   .byte 0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80
vecB:   .byte 0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80
vecACC: .byte 0xFF,0xFF,0xFF,0x7F,0x00,0x00,0x00,0x80,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF
    .bss
    .align 4
results: .space 144
results_end:
    .align 4
linebuf: .space 256
linelen: .space 8
