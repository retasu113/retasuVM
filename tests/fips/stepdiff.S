
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    ldr x0, =katkey
    ldr q0, [x0]
    ldr x2, =consts
    movi v2.2d, #0
    ld1 {v3.4s, v4.4s, v5.4s}, [x2]
    // step 1: ext v1, v0, v4, #0xc
    ext v1.16b, v0.16b, v4.16b, #0xc
    ldr x21, =n_ext1
    bl print_str
    mov v0.16b, v1.16b
    bl print_v0_hex
    // reload state: v0=key, v1=ext result recomputed silently
    ldr x0, =katkey
    ldr q0, [x0]
    ext v1.16b, v0.16b, v4.16b, #0xc
    aese v1.16b, v2.16b
    ldr x21, =n_aese
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // step 3: tbl
    tbl v1.16b, {v1.16b}, v5.16b
    ldr x21, =n_tbl
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // step 4: eor v0, v0, v1
    eor v0.16b, v0.16b, v1.16b
    ldr x21, =n_eor1
    bl print_str
    bl print_v0_hex
    // step 5: mov b1, v3.b[0]
    mov b1, v3.b[0]
    ldr x21, =n_ins
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // step 6: ext v3, v3, v3, #1 ; print v3
    ext v3.16b, v3.16b, v3.16b, #1
    ldr x21, =n_ext3
    bl print_str
    mov v6.16b, v0.16b
    mov v0.16b, v3.16b
    bl print_v0_hex
    mov v0.16b, v6.16b
    // step 7: eor v0, v0, v1
    eor v0.16b, v0.16b, v1.16b
    ldr x21, =n_eor2
    bl print_str
    bl print_v0_hex
    // step 8: ext v1, v2, v0, #0xc ; eor
    ext v1.16b, v2.16b, v0.16b, #0xc
    eor v0.16b, v0.16b, v1.16b
    ldr x21, =n_extc
    bl print_str
    bl print_v0_hex
    // step 9: ext v1, v2, v0, #8 ; eor
    ext v1.16b, v2.16b, v0.16b, #8
    eor v0.16b, v0.16b, v1.16b
    ldr x21, =n_ext8
    bl print_str
    bl print_v0_hex
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
n_ext1: .asciz "S1 ext12: "
n_aese: .asciz "S2 aese: "
n_tbl: .asciz "S3 tbl: "
n_eor1: .asciz "S4 eor: "
n_ins: .asciz "S5 ins: "
n_ext3: .asciz "S6 ext3: "
n_eor2: .asciz "S7 eor: "
n_extc: .asciz "S8 extc+eor: "
n_ext8: .asciz "S9 ext8+eor: "
katkey: .byte 0xe6,0x80,0x74,0x7f,0x14,0xe8,0xa6,0xee,0x00,0xbb,0xa6,0xbd,0x65,0x57,0xae,0x51
consts: .byte 1,2,4,8,16,32,64,128,27,54,0,0,0,0,0,0,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,13,10,7,0,4,1,14,11,8,5,2,15,12,9,6,3

    .bss
linebuf: .skip 4096
linelen: .skip 8
