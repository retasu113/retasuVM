import Foundation

/// Mac プラットフォームのブートテストゲスト「MacBootTestOS」のアセンブリソース。
///
/// iBoot からカーネルへの受け渡しと同じ規約で起動する（EL1 / MMU 無効 / X0 = ADT）。
/// ADT を解析して model・boot-args・メモリ量を表示し、NVMe コントローラを
/// 有効化して RDY を確認し、ジェネリックタイマの FIQ を受けてから停止する。
/// 入出力は SVC ではなく実機同様に UART の MMIO で行う。
enum MacBootTestOS {
    static let source = """
            .text
            .globl _start
    _start:
            mov x19, x0
            ldr x0, =vectors
            msr vbar_el1, x0
            msr daifclr, #1
            ldr x0, =msg_boot
            bl puts
            mov x0, x19
            ldr x1, =prop_model
            bl find_prop
            cmp x0, #0
            b.eq fail
            bl puts
            ldr x0, =msg_nl
            bl puts
            mov x0, x19
            ldr x1, =name_chosen
            bl find_child
            cmp x0, #0
            b.eq fail
            ldr x1, =prop_bootargs
            bl find_prop
            cmp x0, #0
            b.eq fail
            mov x20, x0
            ldr x0, =msg_args
            bl puts
            mov x0, x20
            bl puts
            ldr x0, =msg_nl
            bl puts
            mov x0, x19
            ldr x1, =name_memory
            bl find_child
            cmp x0, #0
            b.eq fail
            ldr x1, =prop_reg
            bl find_prop
            cmp x0, #0
            b.eq fail
            ldr x0, [x0, #8]
            mov x20, x0
            ldr x0, =msg_mem
            bl puts
            mov x0, x20
            bl print_dec
            ldr x0, =msg_bytes
            bl puts
            mov x0, x19
            ldr x1, =name_armio
            bl find_child
            cmp x0, #0
            b.eq fail
            ldr x1, =name_nvme
            bl find_child
            cmp x0, #0
            b.eq fail
            ldr x1, =prop_reg
            bl find_prop
            cmp x0, #0
            b.eq fail
            ldr x20, [x0]
            ldr w0, [x20]
            mov w1, #65535
            and w0, w0, w1
            cmp w0, #1023
            b.ne fail
            ldr x1, =nvme_queues
            mov w0, #15
            orr w0, w0, w0, lsl #16
            str w0, [x20, #36]
            str x1, [x20, #40]
            add x1, x1, #1024
            str x1, [x20, #48]
            mov w0, #1
            str w0, [x20, #20]
            mov x21, #0
            ldr x22, =100000000
    nvme_wait:
            ldr w0, [x20, #28]
            tbz w0, #0, nvme_spin
            b nvme_ready
    nvme_spin:
            add x21, x21, #1
            cmp x21, x22
            b.hs fail
            b nvme_wait
    nvme_ready:
            ldr x0, =msg_nvme
            bl puts
            mrs x0, cntfrq_el0
            mov x1, #20
            udiv x0, x0, x1
            msr cntp_tval_el0, x0
            mov x0, #1
            msr cntp_ctl_el0, x0
    timer_wait:
            ldr x0, =timer_flag
            ldr w0, [x0]
            cmp w0, #0
            b.eq timer_wait
            ldr x0, =msg_timer
            bl puts
            ldr x0, =msg_ok
            bl puts
            mov w0, #0
            ldr x1, =0x0A000000
            str w0, [x1]
    halt_loop:
            wfi
            b halt_loop
    fail:
            ldr x0, =msg_ng
            bl puts
            mov w0, #1
            ldr x1, =0x0A000000
            str w0, [x1]
            b halt_loop
    puts:
            mov x1, x0
            ldr x2, =0x09000000
    puts_loop:
            ldrb w3, [x1]
            cmp w3, #0
            b.eq puts_done
            str w3, [x2]
            add x1, x1, #1
            b puts_loop
    puts_done:
            ret
    print_dec:
            stp x29, x30, [sp, #-16]!
            ldr x1, =numbuf_end
            mov x2, #10
    print_dec_loop:
            udiv x3, x0, x2
            mul x4, x3, x2
            sub x4, x0, x4
            add w4, w4, #48
            sub x1, x1, #1
            strb w4, [x1]
            mov x0, x3
            cmp x0, #0
            b.ne print_dec_loop
            mov x0, x1
            bl puts
            ldp x29, x30, [sp], #16
            ret
    streq:
            mov x2, #0
    streq_loop:
            ldrb w3, [x0, x2]
            ldrb w4, [x1, x2]
            cmp w3, w4
            b.ne streq_no
            cmp w3, #0
            b.eq streq_yes
            add x2, x2, #1
            b streq_loop
    streq_no:
            mov x0, #0
            ret
    streq_yes:
            mov x0, #1
            ret
    skip_props:
            ldr w1, [x0]
            add x2, x0, #8
            mov x3, #0
    skip_props_loop:
            cmp x3, x1
            b.hs skip_props_done
            ldr w4, [x2, #32]
            lsl w4, w4, #1
            lsr w4, w4, #1
            add x4, x4, #3
            lsr x4, x4, #2
            lsl x4, x4, #2
            add x2, x2, #36
            add x2, x2, x4
            add x3, x3, #1
            b skip_props_loop
    skip_props_done:
            mov x0, x2
            ret
    find_prop:
            stp x29, x30, [sp, #-16]!
            stp x19, x20, [sp, #-16]!
            stp x21, x22, [sp, #-16]!
            mov x19, x0
            mov x20, x1
            ldr w21, [x19]
            add x19, x19, #8
            mov x22, #0
    find_prop_loop:
            cmp x22, x21
            b.hs find_prop_notfound
            mov x0, x19
            mov x1, x20
            bl streq
            cmp x0, #1
            b.eq find_prop_found
            ldr w0, [x19, #32]
            lsl w0, w0, #1
            lsr w0, w0, #1
            add x0, x0, #3
            lsr x0, x0, #2
            lsl x0, x0, #2
            add x19, x19, #36
            add x19, x19, x0
            add x22, x22, #1
            b find_prop_loop
    find_prop_found:
            add x0, x19, #36
            b find_prop_out
    find_prop_notfound:
            mov x0, #0
    find_prop_out:
            ldp x21, x22, [sp], #16
            ldp x19, x20, [sp], #16
            ldp x29, x30, [sp], #16
            ret
    node_size:
            stp x29, x30, [sp, #-16]!
            stp x19, x20, [sp, #-16]!
            stp x21, x22, [sp, #-16]!
            mov x19, x0
            ldr w20, [x19, #4]
            bl skip_props
            mov x22, x0
            mov x21, #0
    node_size_loop:
            cmp x21, x20
            b.hs node_size_done
            mov x0, x22
            bl node_size
            add x22, x22, x0
            add x21, x21, #1
            b node_size_loop
    node_size_done:
            sub x0, x22, x19
            ldp x21, x22, [sp], #16
            ldp x19, x20, [sp], #16
            ldp x29, x30, [sp], #16
            ret
    find_child:
            stp x29, x30, [sp, #-16]!
            stp x19, x20, [sp, #-16]!
            stp x21, x22, [sp, #-16]!
            stp x23, x24, [sp, #-16]!
            mov x19, x0
            mov x20, x1
            ldr w21, [x19, #4]
            mov x0, x19
            bl skip_props
            mov x23, x0
            mov x22, #0
    find_child_loop:
            cmp x22, x21
            b.hs find_child_notfound
            mov x0, x23
            ldr x1, =prop_name
            bl find_prop
            cmp x0, #0
            b.eq find_child_next
            mov x1, x20
            bl streq
            cmp x0, #1
            b.eq find_child_found
    find_child_next:
            mov x0, x23
            bl node_size
            add x23, x23, x0
            add x22, x22, #1
            b find_child_loop
    find_child_found:
            mov x0, x23
            b find_child_out
    find_child_notfound:
            mov x0, #0
    find_child_out:
            ldp x23, x24, [sp], #16
            ldp x21, x22, [sp], #16
            ldp x19, x20, [sp], #16
            ldp x29, x30, [sp], #16
            ret
    fiq_wrap:
            stp x0, x1, [sp, #-16]!
            mrs x0, cntp_ctl_el0
            tbz x0, #2, fiq_wrap_done
            mov x0, #0
            msr cntp_ctl_el0, x0
            ldr x0, =timer_flag
            mov w1, #1
            str w1, [x0]
    fiq_wrap_done:
            ldp x0, x1, [sp], #16
            eret
    sync_trap:
            ldr x1, =0x09000000
            mov w0, #83
            str w0, [x1]
            mov w0, #2
            ldr x1, =0x0A000000
            str w0, [x1]
            b halt_loop
            .align 11
    vectors:
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b fiq_wrap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b fiq_wrap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b fiq_wrap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b sync_trap
            .space 124
            b fiq_wrap
            .space 124
            b sync_trap
            .space 124
    msg_boot: .asciz "Mac boot test\\nmodel: "
    msg_nl: .asciz "\\n"
    msg_args: .asciz "boot-args: "
    msg_mem: .asciz "memory: "
    msg_bytes: .asciz " bytes\\n"
    msg_nvme: .asciz "nvme: ready\\n"
    msg_timer: .asciz "timer: fiq ok\\n"
    msg_ok: .asciz "MAC BOOT OK\\n"
    msg_ng: .asciz "MAC BOOT NG\\n"
    prop_model: .asciz "model"
    prop_bootargs: .asciz "boot-args"
    prop_reg: .asciz "reg"
    prop_name: .asciz "name"
    name_chosen: .asciz "chosen"
    name_memory: .asciz "memory"
    name_armio: .asciz "arm-io"
    name_nvme: .asciz "nvme"
            .align 3
    timer_flag: .word 0
    numbuf: .space 24
    numbuf_end:
            .align 12
    nvme_queues: .space 8192
    """
}
