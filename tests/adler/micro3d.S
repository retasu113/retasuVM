
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    ldr x19, =vecA
    ldr x20, =vecB
    ldr x28, =results
    ldr q5, [x19]
    ldr q7, [x20]
    str q5, [x28], #16
    str q7, [x28], #16
    saddl v2.8h, v5.8b, v7.8b
    str q2, [x28], #16
    saddl2 v2.8h, v5.16b, v7.16b
    str q2, [x28], #16
    smull v2.2d, v5.2s, v7.2s
    str q2, [x28], #16

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
    .bss
    .align 4
results: .space 80
results_end:
    .align 4
linebuf: .space 256
linelen: .space 8
