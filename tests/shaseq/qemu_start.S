	.text
	.globl _start
_start:
	bl run_tests
	/* print results: 5 lines of 8 hex words */
	adrp x9, results
	add x9, x9, :lo12:results
	mov x10, #5
line_loop:
	mov x11, #8
	mov x12, x9
word_loop:
	ldr w13, [x12], #4
	mov x14, #28
digit_loop:
	lsr x15, x13, x14
	and x15, x15, #15
	add x15, x15, #'0'
	cmp x15, #'9'
	bls 1f
	add x15, x15, #39
1:	adrp x16, outbuf
	add x16, x16, :lo12:outbuf
	strb w15, [x16]
	mov x8, #64
	mov x0, #1
	mov x1, x16
	mov x2, #1
	svc #0
	subs x14, x14, #4
	bge digit_loop
	adrp x16, outbuf
	add x16, x16, :lo12:outbuf
	mov w17, #' '
	strb w17, [x16]
	mov x8, #64
	mov x0, #1
	mov x1, x16
	mov x2, #1
	svc #0
	subs x11, x11, #1
	bne word_loop
	adrp x16, outbuf
	add x16, x16, :lo12:outbuf
	mov w17, #'\n'
	strb w17, [x16]
	mov x8, #64
	mov x0, #1
	mov x1, x16
	mov x2, #1
	svc #0
	add x9, x9, #32
	subs x10, x10, #1
	bne line_loop
	mov x8, #93
	mov x0, #0
	svc #0
	.section ".bss"
	.globl outbuf
outbuf: .skip 8
