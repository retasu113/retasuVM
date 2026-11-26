// Bare-metal entry with MMU on: identity-map VA 0x40000000..0x42000000
// with 16 KiB pages (L1 -> L2 -> L3), like the kernel's physmap.
// Tables live in BSS (built by hand below via static initializers is
// complex; build them at runtime into fixed RAM at 0x40400000).
    .text
    .globl _start
_start:
    // enable FP/SIMD
    mov x0, #(3 << 20)
    msr cpacr_el1, x0
    // clear SCTLR_EL1.A
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
2:
    // ---- build page tables at 0x40400000 ----
    // L1 at 0x40400000, L2 at 0x40404000, L3 at 0x40408000 (16 KiB each)
    mov x10, #0x40400000
    // zero 3 tables (0xC000 bytes)
    mov x0, x10
    mov x1, #0xC000
3:  str xzr, [x0], #8
    subs x1, x1, #8
    b.ne 3b
    // L1[1] -> L2 table (VA 0x40000000 is in L1 slot 1 for 39-bit VA,
    // 16K granule: L1 index = VA[38:36]... compute: with T0SZ=25,
    // VA space 2^39; L0 skipped (start level 1). L1 idx = VA[38:36]=1
    // for 0x40000000? 0x40000000 = bit30 -> idx bits[38:36] = 0.
    // 16K granule levels: L1 covers 2^(14+11+11)=2^36 per entry.
    // 0x40000000 / 2^36 = 0 -> L1[0]. L2 covers 2^25 per entry:
    // 0x40000000 / 2^25 = 32 -> L2[32]. L3 covers 2^14 per entry.
    // L1[0] = table desc -> L2
    ldr x0, =0x40404000
    orr x0, x0, #3              // valid + table
    str x0, [x10]               // L1[0]
    // L2[32] = table desc -> L3
    ldr x0, =0x40408000
    orr x0, x0, #3
    ldr x1, =0x40404000
    str x0, [x1, #(32*8)]
    // L3[i] for i in 0..1023: page 0x40000000 + i*0x4000
    // descriptor: valid(1) + page(1<<1) + AF(1<<10) + SH(3<<8)
    //             + AP RW EL1 (0<<6) + AttrIndx 0 (0<<2) = 0x703
    mov x2, #0x40000000
    mov x3, #0x703
    orr x2, x2, x3              // first page desc
    ldr x1, =0x40408000
    mov x4, #1024
4:  str x2, [x1], #8
    add x2, x2, #0x4000
    subs x4, x4, #1
    b.ne 4b
    // MAIR_EL1: idx0 = 0xFF (Normal, WB RA/WA)
    mov x0, #0xFF
    msr mair_el1, x0
    // TCR_EL1: T0SZ=25, IRGN0=1, ORGN0=1, SH0=3, TG0=2 (16K),
    // IPS=5 (48-bit PA): 0x50000B519
    ldr x0, =0x50000B519
    msr tcr_el1, x0
    // TTBR0_EL1 = L1 table
    mov x0, x10
    msr ttbr0_el1, x0
    tlbi vmalle1
    dsb ish
    isb
    // SCTLR_EL1: M=1, C=1<<2, I=1<<12 (A already cleared above)
    mrs x0, sctlr_el1
    orr x0, x0, #1
    orr x0, x0, #(1 << 2)
    orr x0, x0, #(1 << 12)
    msr sctlr_el1, x0
    isb
    bl guest_main
    b .
