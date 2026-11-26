
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    // v3 = rcon pattern, v1 = 5be4d14d...
    ldr x0, =pat3
    ldr q3, [x0]
    ldr x0, =pat1
    ldr q1, [x0]
    mov v1.b[0], v3.b[0]
    ldr x21, =n1
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // reload v1, try b[3] <- v3.b[9]
    ldr x0, =pat1
    ldr q1, [x0]
    mov v1.b[3], v3.b[9]
    ldr x21, =n2
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // s[2] <- s[1]
    ldr x0, =pat1
    ldr q1, [x0]
    mov v1.s[2], v3.s[1]
    ldr x21, =n3
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // h[3] <- h[5]
    ldr x0, =pat1
    ldr q1, [x0]
    mov v1.h[3], v3.h[5]
    ldr x21, =n4
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // d[1] <- d[0]
    ldr x0, =pat1
    ldr q1, [x0]
    mov v1.d[1], v3.d[0]
    ldr x21, =n5
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
#ifdef ENGINE
    mov x0, #0
    svc #10
#else
    mov x8, #93
    mov x0, #0
    svc #0
#endif
    b .

// ---- helpers (same as aesdiff) ----
print_str:
    stp x29, x30, [sp, #-16]!
    mov x22, x21
1:  ldrb w0, [x22], #1
    cbz w0, 2f
    bl putc
    b 1b
2:  ldp x29, x30, [sp], #16
    ret

print_v0_hex:
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #16
    str q0, [sp]
    mov x22, sp
    mov x25, #0
3:  ldrb w0, [x22, x25]
    lsr w26, w0, #4
    and w0, w0, #0xF
    mov w23, w26
    cmp w23, #10
    b.lt 4f
    add w23, w23, #87
    b 5f
4:  add w23, w23, #48
5:  mov w0, w23
    bl putc
    ldrb w0, [x22, x25]
    and w0, w0, #0xF
    cmp w0, #10
    b.lt 6f
    add w0, w0, #87
    b 7f
6:  add w0, w0, #48
7:  bl putc
    add x25, x25, #1
    cmp x25, #16
    b.lt 3b
    mov w0, #0x0A
    bl putc
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    ret

putc:
#ifdef ENGINE
    str w0, [x12]
    ret
#else
    stp x29, x30, [sp, #-48]!
    str x22, [sp, #16]
    str x23, [sp, #24]
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
3:  ldr x22, [sp, #16]
    ldr x23, [sp, #24]
    ldp x29, x30, [sp], #48
    ret
#endif


    .section .rodata
n1: .asciz "INS b0<-b0: "
n2: .asciz "INS b3<-b9: "
n3: .asciz "INS s2<-s1: "
n4: .asciz "INS h3<-h5: "
n5: .asciz "INS d1<-d0: "
pat3: .byte 0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x00,0x00,0x00,0x00,0x00,0x00
pat1: .byte 0x5b,0xe4,0xd1,0x4d,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .bss
linebuf: .skip 4096
linelen: .skip 8
