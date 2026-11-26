
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    ldr x7, =adler_consts
    ld1 {v0.4s, v1.4s}, [x7], #32
    ldr d7, [x7]

    // B1: umull v2.2d, v5.2s, v7.s[1] with v5={0xFFFF,0xFFFF}
    ldr x21, =name_B1
    bl print_str
    mov x0, #0x0000FFFF
    orr x0, x0, x0, lsl #32
    mov v5.d[0], x0
    umull v2.2d, v5.2s, v7.s[1]
    mov w0, v2.s[0]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[1]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[2]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[3]
    bl print_hex32
    mov w0, #0x0A
    bl putc

    // B2: + ushr #0x2f  (expect v2 lanes 1 0 1 0)
    ldr x21, =name_B2
    bl print_str
    mov x0, #0x0000FFFF
    orr x0, x0, x0, lsl #32
    mov v5.d[0], x0
    umull v2.2d, v5.2s, v7.s[1]
    ushr v2.2d, v2.2d, #0x2f
    mov w0, v2.s[0]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[1]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[2]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[3]
    bl print_hex32
    mov w0, #0x0A
    bl putc

    // B3: + mov v2.s[1], v2.s[2]  (expect 1 1 1 0)
    ldr x21, =name_B3
    bl print_str
    mov x0, #0x0000FFFF
    orr x0, x0, x0, lsl #32
    mov v5.d[0], x0
    umull v2.2d, v5.2s, v7.s[1]
    ushr v2.2d, v2.2d, #0x2f
    mov v2.s[1], v2.s[2]
    mov w0, v2.s[0]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[1]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[2]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[3]
    bl print_hex32
    mov w0, #0x0A
    bl putc

    // B4: + mls v5.2s, v2.2s, v7.s[0]  (expect v5 = 0000000E 0000000E)
    ldr x21, =name_B4
    bl print_str
    mov x0, #0x0000FFFF
    orr x0, x0, x0, lsl #32
    mov v5.d[0], x0
    umull v2.2d, v5.2s, v7.s[1]
    ushr v2.2d, v2.2d, #0x2f
    mov v2.s[1], v2.s[2]
    mls v5.2s, v2.2s, v7.s[0]
    mov w0, v5.s[0]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v5.s[1]
    bl print_hex32
    mov w0, #0x0A
    bl putc

    // U: umull with v5={3,5}: print v2 s lanes (products 3*magic, 5*magic as 64-bit)
    ldr x21, =name_U
    bl print_str
    ldr x0, =0x0000000500000003
    mov v5.d[0], x0
    umull v2.2d, v5.2s, v7.s[1]
    mov w0, v2.s[0]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[1]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[2]
    bl print_hex32
    mov w0, #0x20
    bl putc
    mov w0, v2.s[3]
    bl print_hex32
    mov w0, #0x0A
    bl putc

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

print_str:
    mov x25, x30
    mov x28, x21
4:  ldrb w0, [x28], #1
    cbz w0, 5f
    bl putc
    b 4b
5:  mov x30, x25
    ret

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

    .section .rodata, "a"
    .globl adler_consts
adler_consts:
    .incbin "consts.bin"
name_B1: .asciz "B1 "
name_B2: .asciz "B2 "
name_B3: .asciz "B3 "
name_B4: .asciz "B4 "
name_U: .asciz "U "

    .bss
    .balign 16
    .globl linebuf
linebuf: .skip 256
    .globl linelen
linelen: .skip 8
