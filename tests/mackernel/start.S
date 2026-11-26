    .section .text
    .globl _start
_start:
    // x0 = ADT アドレス（ブート引数）を保存する
    adrp x1, adt_ptr
    add x1, x1, :lo12:adt_ptr
    str x0, [x1]
    // スタック設定
    adrp x1, stack_top
    add x1, x1, :lo12:stack_top
    mov sp, x1
    // 例外ベクタ設定
    adrp x1, vectors
    add x1, x1, :lo12:vectors
    msr vbar_el1, x1
    // FIQ をマスク解除する（DAIF の F ビットをクリア）
    msr daifclr, #1
    // kernel_main(adt_ptr) を呼ぶ
    adrp x0, adt_ptr
    add x0, x0, :lo12:adt_ptr
    ldr x0, [x0]
    bl kernel_main
    mov x0, #1
    b halt_with_code

    .globl halt_with_code
halt_with_code:
    // 制御レジスタ（0x0A000000）へ終了コードを書くと停止する
    mov x1, #0x0A000000
    str w0, [x1]
1:  wfi
    b 1b

    .macro vent target
    b \target
    .space 124
    .endm

    .align 11
    .globl vectors
vectors:
    vent sync_trap      // 0x000 sync (EL1, SP0)
    vent irq_trap       // 0x080 IRQ  (EL1, SP0)
    vent fiq_entry      // 0x100 FIQ  (EL1, SP0)
    vent sync_trap      // 0x180 SError
    vent sync_trap      // 0x200 sync (EL1, SPx)
    vent irq_trap       // 0x280 IRQ  (EL1, SPx)
    vent fiq_entry      // 0x300 FIQ  (EL1, SPx)
    vent sync_trap      // 0x380 SError
    vent sync_trap      // 0x400 sync (下位 EL, AArch64)
    vent irq_trap       // 0x480 IRQ  (下位 EL)
    vent fiq_entry      // 0x500 FIQ  (下位 EL)
    vent sync_trap      // 0x580 SError
    vent sync_trap      // 0x600 sync (下位 EL, AArch32)
    vent irq_trap       // 0x680 IRQ  (下位 EL, AArch32)
    vent fiq_entry      // 0x700 FIQ  (下位 EL, AArch32)
    vent sync_trap      // 0x780 SError

fiq_entry:
    sub sp, sp, #160
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    str x30, [sp, #144]
    bl fiq_handler
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldr x30, [sp, #144]
    add sp, sp, #160
    eret

sync_trap:
    mov x1, #0x09000000
    mov w2, #83         // 'S'
    str w2, [x1]
    mov x0, #2
    b halt_with_code

irq_trap:
    mov x1, #0x09000000
    mov w2, #73         // 'I'
    str w2, [x1]
    mov x0, #3
    b halt_with_code

    .data
    .align 3
    .globl adt_ptr
adt_ptr:
    .xword 0

    .bss
    .align 4
stack:
    .space 65536
stack_top:
