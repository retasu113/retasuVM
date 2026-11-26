// MMU-on entry: identity map 0x40000000..0x42000000 (16 KiB pages),
// then RE-MAP two pages to scattered PAs to test cross-page accesses:
//   VA 0x40600000 -> PA 0x40800000
//   VA 0x40604000 -> PA 0x40410000
// (PA-contiguous after 0x40800000 is 0x40804000, a marker page.)
    .text
    .globl _start
_start:
    mov x0, #(3 << 20)
    msr cpacr_el1, x0
    mrs x0, sctlr_el1
    bic x0, x0, #2
    msr sctlr_el1, x0
    isb
    ldr x0, =0x40300000
    mov sp, x0
    ldr x0, =__bss_start
    ldr x1, =__bss_end
1:  cmp x0, x1
    b.hs 2f
    str xzr, [x0], #8
    b 1b
2:
    mov x10, #0x40400000
    mov x0, x10
    mov x1, #0xC000
3:  str xzr, [x0], #8
    subs x1, x1, #8
    b.ne 3b
    ldr x0, =0x40404000
    orr x0, x0, #3
    str x0, [x10]
    ldr x0, =0x40408000
    orr x0, x0, #3
    ldr x1, =0x40404000
    str x0, [x1, #(32*8)]
    mov x2, #0x40000000
    mov x3, #0x703
    orr x2, x2, x3
    ldr x1, =0x40408000
    mov x4, #1024
4:  str x2, [x1], #8
    add x2, x2, #0x4000
    subs x4, x4, #1
    b.ne 4b
    // override L3[384] (VA 0x40600000) -> PA 0x40800000
    ldr x1, =0x40408000
    ldr x0, =0x40800703
    str x0, [x1, #(384*8)]
    // override L3[385] (VA 0x40604000) -> PA 0x40410000
    ldr x0, =0x40410703
    str x0, [x1, #(385*8)]
    mov x0, #0xFF
    msr mair_el1, x0
    ldr x0, =0x50000B519
    msr tcr_el1, x0
    mov x0, x10
    msr ttbr0_el1, x0
    tlbi vmalle1
    dsb ish
    isb
    mrs x0, sctlr_el1
    orr x0, x0, #1
    orr x0, x0, #(1 << 2)
    orr x0, x0, #(1 << 12)
    msr sctlr_el1, x0
    isb
    bl guest_main
    b .
