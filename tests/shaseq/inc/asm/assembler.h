#define CPU_LE(...) __VA_ARGS__
#define CPU_BE(...)
	.macro adr_l, dst, sym
	adrp	\dst, \sym
	add	\dst, \dst, :lo12:\sym
	.endm
	.macro ldr_l, dst, sym, tmp
	adrp	\tmp, \sym
	ldr	\dst, [\tmp, :lo12:\sym]
	.endm
	.macro cond_yield, label, tmp1:req, tmp2:req
	.endm
