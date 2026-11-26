    .text
    .globl _start
_start:
    ldr x0, =0x44000000
    mov sp, x0
    bl kernel_main
    // kernel_main は戻らない想定。戻ったら制御レジスタで停止する
    ldr x1, =0x0A000000
    str w0, [x1]
1:  wfi
    b 1b

    // ---- 例外ベクタテーブル（2KB アライン） ----
    .align 11
    .globl vectors
vectors:
    // +0x000 同期（EL1, SP_EL0 使用時）
    b vec_unexpected
    .align 7
    // +0x080 IRQ（SP_EL0）
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    // +0x200 同期（現在の EL、SP_ELx）
    b sync_current
    .align 7
    // +0x280 IRQ（現在の EL）
    b irq_current
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    // +0x400 同期（下位 EL、AArch64）
    b sync_lower
    .align 7
    // +0x480 IRQ（下位 EL）
    b irq_current
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7
    b vec_unexpected
    .align 7

vec_unexpected:
    ldr x0, =0x0A000000
    mov w1, #99
    str w1, [x0]
1:  wfi
    b 1b

    // 同期例外の共通処理: レジスタを退避し、C の handle_sync を呼ぶ。
    // 現在 EL / 下位 EL の判別は SPSR_EL1 の M フィールドで行う（C 側）。
sync_current:
    b sync_common
sync_lower:
    b sync_common
sync_common:
    sub sp, sp, #272
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x0, esr_el1
    ldr x1, =esr_saved
    str x0, [x1]
    mrs x0, far_el1
    ldr x1, =far_saved
    str x0, [x1]
    mrs x0, elr_el1
    ldr x1, =elr_saved
    str x0, [x1]
    mrs x0, spsr_el1
    ldr x1, =spsr_saved
    str x0, [x1]
    bl handle_sync
    ldr x1, =elr_saved
    ldr x0, [x1]
    msr elr_el1, x0
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #272
    eret

irq_current:
    sub sp, sp, #272
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    // IAR を読んで記録し、C の handle_irq へ。EOI は C 側で行う
    ldr x0, =0x0801000C
    ldr w1, [x0]
    ldr x2, =iar_saved
    str w1, [x2]
    bl handle_irq
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #272
    eret

    // EL0 へ降りるトランポリン: x0 = 実行アドレス、x1 = SP_EL0、x2 = SPSR
    .globl drop_to_el0
drop_to_el0:
    msr sp_el0, x1
    msr elr_el1, x0
    msr spsr_el1, x2
    eret

    // EL0 で動くスタブ
    .globl user_code
user_code:
    svc #0x77
    // ハンドラが ELR を user_recovery へ書き換える
    b user_code
    .globl user_recovery
user_recovery:
    svc #0x78
    b user_recovery
    .globl user_done
user_done:
    svc #0x79
    b user_done

    .data
    .align 3
    .globl esr_saved
esr_saved: .xword 0
    .globl far_saved
far_saved: .xword 0
    .globl elr_saved
elr_saved: .xword 0
    .globl spsr_saved
spsr_saved: .xword 0
    .globl iar_saved
iar_saved: .word 0
