import Foundation

/// ゲスト OS「CalcOS」: スタック式（逆ポーランド記法）計算機のゲスト。
///
/// 乗算・除算・剰余には M 拡張の mul / div / rem 命令を使う。
/// 状態: s0 = スタック要素数、calc_stack に Int32 を最大 64 個保持する。
enum CalcOS {
    static let source = GuestRuntime.source + """

# ---- CalcOS main ----
    .text
main:
    addi sp, sp, -16
    sw ra, 12(sp)
    li s0, 0
    la a0, calc_banner
    call print_str
calc_loop:
    la a0, calc_prompt
    call print_str
    la a0, linebuf
    li a1, 128
    call read_line
    la s1, linebuf
calc_skip_spaces:
    lb t0, 0(s1)
    li t1, 32
    bne t0, t1, calc_token_check
    addi s1, s1, 1
    j calc_skip_spaces
calc_token_check:
    lb t0, 0(s1)
    beqz t0, calc_loop
    mv s2, s1
calc_token_scan:
    lb t0, 0(s1)
    beqz t0, calc_token_ready
    li t1, 32
    beq t0, t1, calc_token_ready
    addi s1, s1, 1
    j calc_token_scan
calc_token_ready:
    sub s3, s1, s2
    mv a0, s2
    mv a1, s3
    call calc_process
    j calc_skip_spaces

# calc_process: a0 = token ptr, a1 = token length. s7/s8 に退避して処理する。
calc_process:
    addi sp, sp, -16
    sw ra, 12(sp)
    mv s7, a0
    mv s8, a1
    lb t0, 0(s7)
    li t1, 45
    beq t0, t1, calc_num_sign
    li t1, 48
    blt t0, t1, calc_words
    li t1, 57
    bgt t0, t1, calc_words
    mv t6, s8
    j calc_num_parse
calc_num_sign:
    li t0, 1
    beq s8, t0, calc_words
    lb t0, 1(s7)
    li t1, 48
    blt t0, t1, calc_words
    li t1, 57
    bgt t0, t1, calc_words
    addi t6, s8, -1
calc_num_parse:
    mv a0, s7
    call parse_int
    bne a1, t6, calc_words
    li t0, 64
    bge s0, t0, calc_overflow
    la t0, calc_stack
    slli t1, s0, 2
    add t0, t0, t1
    sw a0, 0(t0)
    addi s0, s0, 1
    j calc_return
calc_words:
    li t0, 1
    bne s8, t0, calc_word_cmds
    lb t0, 0(s7)
    li t1, 43
    beq t0, t1, calc_op_add
    li t1, 45
    beq t0, t1, calc_op_sub
    li t1, 42
    beq t0, t1, calc_op_mul
    li t1, 47
    beq t0, t1, calc_op_div
    li t1, 37
    beq t0, t1, calc_op_rem
    li t1, 112
    beq t0, t1, calc_print
    j calc_word_cmds
calc_word_cmds:
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_dup
    call cmd_eq
    bnez a0, calc_dup
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_drop
    call cmd_eq
    bnez a0, calc_drop
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_swap
    call cmd_eq
    bnez a0, calc_swap
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_clear
    call cmd_eq
    bnez a0, calc_clear
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_help
    call cmd_eq
    bnez a0, calc_help
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_quit
    call cmd_eq
    bnez a0, calc_quit
    mv a0, s7
    mv a1, s8
    la a2, calc_cmd_exit
    call cmd_eq
    bnez a0, calc_quit
    la a0, calc_unknown_text
    call print_str
    j calc_return
calc_op_add:
    li t5, 0
    j calc_binop
calc_op_sub:
    li t5, 1
    j calc_binop
calc_op_mul:
    li t5, 2
    j calc_binop
calc_op_div:
    li t5, 3
    j calc_binop
calc_op_rem:
    li t5, 4
    j calc_binop
calc_binop:
    li t0, 2
    blt s0, t0, calc_underflow
    la t0, calc_stack
    slli t1, s0, 2
    add t0, t0, t1
    lw t2, -4(t0)
    lw t3, -8(t0)
    li t1, 3
    beq t5, t1, calc_check_zero
    li t1, 4
    beq t5, t1, calc_check_zero
    j calc_compute
calc_check_zero:
    beqz t2, calc_divzero
calc_compute:
    li t1, 0
    beq t5, t1, calc_do_add
    li t1, 1
    beq t5, t1, calc_do_sub
    li t1, 2
    beq t5, t1, calc_do_mul
    li t1, 3
    beq t5, t1, calc_do_div
    rem t4, t3, t2
    j calc_store
calc_do_add:
    add t4, t3, t2
    j calc_store
calc_do_sub:
    sub t4, t3, t2
    j calc_store
calc_do_mul:
    mul t4, t3, t2
    j calc_store
calc_do_div:
    div t4, t3, t2
    j calc_store
calc_store:
    la t0, calc_stack
    slli t1, s0, 2
    add t0, t0, t1
    sw t4, -8(t0)
    addi s0, s0, -1
    j calc_return
calc_print:
    beqz s0, calc_print_empty
    la a0, calc_stack_pre
    call print_str
    li s9, 0
    mv s10, s0
calc_print_loop:
    bge s9, s10, calc_print_done
    la t0, calc_stack
    slli t1, s9, 2
    add t0, t0, t1
    lw a0, 0(t0)
    call print_int
    li a0, 32
    li a7, 1
    ecall
    addi s9, s9, 1
    j calc_print_loop
calc_print_done:
    call print_nl
    j calc_return
calc_print_empty:
    la a0, calc_empty_text
    call print_str
    j calc_return
calc_dup:
    beqz s0, calc_underflow
    li t0, 64
    bge s0, t0, calc_overflow
    la t0, calc_stack
    slli t1, s0, 2
    add t0, t0, t1
    lw t2, -4(t0)
    sw t2, 0(t0)
    addi s0, s0, 1
    j calc_return
calc_drop:
    beqz s0, calc_underflow
    addi s0, s0, -1
    j calc_return
calc_swap:
    li t0, 2
    blt s0, t0, calc_underflow
    la t0, calc_stack
    slli t1, s0, 2
    add t0, t0, t1
    lw t2, -4(t0)
    lw t3, -8(t0)
    sw t2, -8(t0)
    sw t3, -4(t0)
    j calc_return
calc_clear:
    li s0, 0
    j calc_return
calc_help:
    la a0, calc_help_text
    call print_str
    j calc_return
calc_quit:
    la a0, calc_bye
    call print_str
    li a0, 0
    li a7, 10
    ecall
calc_underflow:
    la a0, calc_underflow_text
    call print_str
    j calc_return
calc_divzero:
    la a0, calc_divzero_text
    call print_str
    j calc_return
calc_overflow:
    la a0, calc_overflow_text
    call print_str
    j calc_return
calc_return:
    lw ra, 12(sp)
    addi sp, sp, 16
    ret

    .data
calc_banner: .asciiz "========================================\\n  CalcOS 1.0 for retasuVM\\n  stack calculator (RISC-V RV32IM)\\n========================================\\nType 'help' for usage.\\n"
calc_prompt: .asciiz "calc> "
calc_help_text: .asciiz "CalcOS is a stack (RPN) calculator.\\nType numbers and operators on one line, then 'p' to print the stack.\\n  operators: + - * / %\\n  commands: p (print) dup drop swap clear help quit\\nExample: 3 4 + p  ->  stack: 7\\n"
calc_stack_pre: .asciiz "stack: "
calc_empty_text: .asciiz "stack: (empty)\\n"
calc_underflow_text: .asciiz "error: stack underflow\\n"
calc_divzero_text: .asciiz "error: division by zero\\n"
calc_overflow_text: .asciiz "error: stack overflow\\n"
calc_unknown_text: .asciiz "error: unknown token\\n"
calc_bye: .asciiz "CalcOS halted. Bye.\\n"
calc_cmd_dup: .asciiz "dup"
calc_cmd_drop: .asciiz "drop"
calc_cmd_swap: .asciiz "swap"
calc_cmd_clear: .asciiz "clear"
calc_cmd_help: .asciiz "help"
calc_cmd_quit: .asciiz "quit"
calc_cmd_exit: .asciiz "exit"
calc_stack: .space 256
"""
}
