// Bare-metal entry for the LZVN differential guest.
    .text
    .globl _start
_start:
    // enable FP/SIMD (CPACR_EL1.FPEN = 0b11)
    mov x0, #(3 << 20)
    msr cpacr_el1, x0
    // clear SCTLR_EL1.A (alignment check) — Normal-memory unaligned
    // accesses are legal with A=0, as under the kernel
    mrs x0, sctlr_el1
    bic x0, x0, #2
    msr sctlr_el1, x0
    isb
    ldr x0, =0x40300000
    mov sp, x0
    // zero BSS
    ldr x0, =__bss_start
    ldr x1, =__bss_end
1:  cmp x0, x1
    b.hs 2f
    str xzr, [x0], #8
    b 1b
2:  bl guest_main
    b .
