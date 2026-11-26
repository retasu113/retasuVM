#define SYM_FUNC_START(name) \
	.globl name; .type name, %function; .align 4; name:
#define SYM_FUNC_END(name) \
	.size name, .-name
