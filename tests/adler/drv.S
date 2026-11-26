
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif
    // fill seqbuf with i & 0xFF (6000 bytes)
    ldr x19, =seqbuf
    mov x20, #0
1:  strb w20, [x19, x20]
    add x20, x20, #1
    mov x21, #6000
    cmp x20, x21
    b.lt 1b
    // fill ffbuf with 0xFF (64 bytes)
    ldr x19, =ffbuf
    mov x20, #0
    mov w21, #0xFF
2:  strb w21, [x19, x20]
    add x20, x20, #1
    cmp x20, #64
    b.lt 2b


    ldr x21, =name_bank
    bl print_str
    mov w0, #24
    mov x1, #288
    ldr x2, =bankdata
    mov w3, #524256
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq32
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #32
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq16
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #16
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq17
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #17
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq100
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #100
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq5552
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #5552
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_seq5553
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =seqbuf
    mov w3, #5553
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_zeros5552
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =zerobuf
    mov w3, #5552
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
    bl print_hex32
    mov w0, #0x0A
    bl putc


    ldr x21, =name_ff32
    bl print_str
    mov w0, #1
    mov x1, #0
    ldr x2, =ffbuf
    mov w3, #32
    bl adler_core
    mov w20, w0
    mov w0, #0x3D
    bl putc
    mov w0, w20
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

// putc: char in w0, clobbers x22, x23 (qemu: also x0-x2,x8 at flush; called only from driver flow)
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

// print_str: NUL-terminated string at x21; clobbers x22, lr via putc chain (use x25 as saved lr)
print_str:
    mov x25, x30
    mov x28, x21
4:  ldrb w0, [x28], #1
    cbz w0, 5f
    bl putc
    b 4b
5:  mov x30, x25
    ret

// print_hex32: value in w0; prints 8 hex digits
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

    .section .core, "ax"
    .balign 4096
    .org 0xCC0
    .globl adler_core
adler_core:
    .incbin "core.bin"
    .org 0xE30
    .incbin "consts.bin"

    .section .rodata, "a"
    .globl bankdata
bankdata:
    .incbin "bankdata.bin"

name_bank: .asciz "bank"
name_seq32: .asciz "seq32"
name_seq16: .asciz "seq16"
name_seq17: .asciz "seq17"
name_seq100: .asciz "seq100"
name_seq5552: .asciz "seq5552"
name_seq5553: .asciz "seq5553"
name_zeros5552: .asciz "zeros5552"
name_ff32: .asciz "ff32"

    .bss
    .balign 16
    .globl seqbuf
seqbuf: .skip 6000
    .globl ffbuf
ffbuf: .skip 64
    .globl zerobuf
zerobuf: .skip 8192
    .globl linebuf
linebuf: .skip 256
    .globl linelen
linelen: .skip 8
