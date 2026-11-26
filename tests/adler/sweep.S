
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

    // ---- S-size long forms ----
    CASE umull v2.2d, v5.2s, v7.s[0]
    CASE umull v2.2d, v5.2s, v7.s[1]
    CASE umull v2.2d, v5.2s, v7.s[2]
    CASE umull v2.2d, v5.2s, v7.s[3]
    CASE umull2 v2.2d, v5.4s, v7.s[1]
    CASE smull v2.2d, v5.2s, v7.s[2]
    CASE smlal v2.2d, v5.2s, v7.s[3]
    CASE umlal v2.2d, v5.2s, v7.s[0]
    CASE smlsl v2.2d, v5.2s, v7.s[1]
    CASE umlsl v2.2d, v5.2s, v7.s[2]
    CASE sqdmull v2.2d, v5.2s, v7.s[2]
    CASE sqdmlal v2.2d, v5.2s, v7.s[0]
    CASE sqdmlsl v2.2d, v5.2s, v7.s[1]
    // ---- S-size same-width forms ----
    CASE mul v2.4s, v5.4s, v7.s[2]
    CASE mul v2.2s, v5.2s, v7.s[3]
    CASE mla v2.4s, v5.4s, v7.s[1]
    CASE mls v2.4s, v5.4s, v7.s[0]
    CASE mls v2.2s, v5.2s, v7.s[0]
    CASE sqdmulh v2.4s, v5.4s, v7.s[2]
    CASE sqrdmulh v2.4s, v5.4s, v7.s[1]
    CASE sqrdmlah v2.4s, v5.4s, v7.s[3]
    CASE sqrdmlsh v2.4s, v5.4s, v7.s[0]
    // ---- H-size long forms ----
    CASE umull v2.4s, v5.4h, v7.h[0]
    CASE umull v2.4s, v5.4h, v7.h[7]
    CASE umull2 v2.4s, v5.8h, v7.h[5]
    CASE smull v2.4s, v5.4h, v7.h[3]
    CASE smlal v2.4s, v5.4h, v7.h[6]
    CASE umlal v2.4s, v5.4h, v7.h[2]
    CASE smlsl v2.4s, v5.4h, v7.h[1]
    CASE umlsl v2.4s, v5.4h, v7.h[4]
    CASE sqdmull v2.4s, v5.4h, v7.h[5]
    CASE sqdmlal v2.4s, v5.4h, v7.h[7]
    CASE sqdmlsl v2.4s, v5.4h, v7.h[2]
    // ---- H-size same-width forms ----
    CASE mul v2.8h, v5.8h, v7.h[7]
    CASE mul v2.4h, v5.4h, v7.h[4]
    CASE mla v2.8h, v5.8h, v7.h[1]
    CASE mls v2.8h, v5.8h, v7.h[6]
    CASE sqdmulh v2.8h, v5.8h, v7.h[5]
    CASE sqrdmulh v2.8h, v5.8h, v7.h[3]
    CASE sqrdmlah v2.8h, v5.8h, v7.h[2]
    CASE sqrdmlsh v2.8h, v5.8h, v7.h[5]
    // ---- scalar forms ----
    CASE sqdmulh s2, s5, v7.s[2]
    CASE sqdmulh h2, h5, v7.h[5]
    CASE sqdmull d2, s5, v7.s[1]
    CASE sqdmull s2, h5, v7.h[5]
    CASE sqdmlal d2, s5, v7.s[3]
    CASE sqdmlsl d2, s5, v7.s[0]
    CASE sqrdmulh s2, s5, v7.s[0]
    CASE sqrdmlah s2, s5, v7.s[1]
    CASE sqrdmlsh h2, h5, v7.h[2]
    CASE sqdmlal s2, h5, v7.h[6]
    CASE sqdmlsl s2, h5, v7.h[1]

    // dump results: 52 lines x 4 words (counter in x19: putc/print_hex32 clobber x22-x27)
    ldr x28, =results
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
2:  cmp x19, #208
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

    .section .rodata, "a"
    .balign 16
    .globl vecA
vecA:
    .word 0x8000FFFF, 0x80000000, 0x7FFFFFFF, 0x80078071
    .globl vecB
vecB:
    .word 0x0000FFE1, 0x80078071, 0x80000000, 0xFFFFFFFF
    .globl vecACC
vecACC:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444

    .bss
    .balign 16
    .globl results
results: .skip 52*16
    .globl linebuf
linebuf: .skip 256
    .globl linelen
linelen: .skip 8
