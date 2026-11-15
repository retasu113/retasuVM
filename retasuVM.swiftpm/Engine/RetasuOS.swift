import Foundation

/// ゲスト OS「retasuOS」のアセンブリソース（旧 GuestOS.swift から改名）。
///
/// 起動時に `RISCVAssembler` で機械語へ変換され、`RISCVCPU` 上で実際に実行される。
/// retasuOS は対話型モニタで、プロンプトに対してコマンドを実行する。
///
/// システムコール（ECALL、番号は a7）:
/// 1 = 1文字出力 / 2 = 整数出力 / 3 = 文字列出力 / 4 = 1文字入力 /
/// 5 = 画面消去 / 10 = 終了
enum RetasuOS {
    static let source = """
# retasuOS 0.1.0 - tiny monitor for the retasuVM RISC-V emulator
    .text
    .globl _start
_start:
    li sp, 0x100000
    call main
    li a0, 0
    li a7, 10
    ecall

# ---- main ----
main:
    addi sp, sp, -16
    sw ra, 12(sp)
    la a0, str_banner
    call print_str
main_loop:
    la a0, str_prompt
    call print_str
    la a0, linebuf
    li a1, 128
    call read_line
    la s0, linebuf
main_skip_lead:
    lb t0, 0(s0)
    li t1, 32
    bne t0, t1, main_token_start
    addi s0, s0, 1
    j main_skip_lead
main_token_start:
    lb t0, 0(s0)
    beqz t0, main_loop
    mv s1, s0
main_token_scan:
    lb t0, 0(s0)
    beqz t0, main_token_done
    li t1, 32
    beq t0, t1, main_token_done
    addi s0, s0, 1
    j main_token_scan
main_token_done:
    sub s2, s0, s1
main_skip_arg:
    lb t0, 0(s0)
    li t1, 32
    bne t0, t1, main_arg_done
    addi s0, s0, 1
    j main_skip_arg
main_arg_done:
    mv s3, s0
    # dispatch
    mv a0, s1
    mv a1, s2
    la a2, cmd_help
    call cmd_eq
    bnez a0, do_help
    mv a0, s1
    mv a1, s2
    la a2, cmd_echo
    call cmd_eq
    bnez a0, do_echo
    mv a0, s1
    mv a1, s2
    la a2, cmd_fib
    call cmd_eq
    bnez a0, do_fib
    mv a0, s1
    mv a1, s2
    la a2, cmd_about
    call cmd_eq
    bnez a0, do_about
    mv a0, s1
    mv a1, s2
    la a2, cmd_ver
    call cmd_eq
    bnez a0, do_ver
    mv a0, s1
    mv a1, s2
    la a2, cmd_clear
    call cmd_eq
    bnez a0, do_clear
    mv a0, s1
    mv a1, s2
    la a2, cmd_halt
    call cmd_eq
    bnez a0, do_halt
    mv a0, s1
    mv a1, s2
    la a2, cmd_exit
    call cmd_eq
    bnez a0, do_halt
    mv a0, s1
    mv a1, s2
    la a2, cmd_quit
    call cmd_eq
    bnez a0, do_halt
    la a0, str_unknown
    call print_str
    j main_loop

do_help:
    la a0, str_help
    call print_str
    j main_loop
do_about:
    la a0, str_about
    call print_str
    j main_loop
do_ver:
    la a0, str_ver
    call print_str
    j main_loop
do_clear:
    li a7, 5
    ecall
    j main_loop
do_echo:
    mv a0, s3
    call print_str
    call print_nl
    j main_loop
do_halt:
    la a0, str_bye
    call print_str
    li a0, 0
    li a7, 10
    ecall
do_fib:
    mv a0, s3
    call parse_int
    beqz a1, do_fib_usage
    mv s4, a0
    li t0, 0
    blt s4, t0, do_fib_usage
    li t0, 46
    bgt s4, t0, do_fib_usage
    li t0, 0
    li t1, 1
    li t2, 0
do_fib_loop:
    bge t2, s4, do_fib_print
    add t3, t0, t1
    mv t0, t1
    mv t1, t3
    addi t2, t2, 1
    j do_fib_loop
do_fib_print:
    la a0, str_fib_pre
    call print_str
    mv a0, s4
    call print_int
    la a0, str_fib_mid
    call print_str
    mv a0, t0
    call print_int
    call print_nl
    j main_loop
do_fib_usage:
    la a0, str_fib_usage
    call print_str
    j main_loop

# ---- helpers ----
# print_str: a0 = NUL-terminated string address
print_str:
    li a7, 3
    ecall
    ret
# print_int: a0 = signed value
print_int:
    li a7, 2
    ecall
    ret
# print_nl: print newline (preserves a0)
print_nl:
    addi sp, sp, -16
    sw a0, 8(sp)
    li a0, 10
    li a7, 1
    ecall
    lw a0, 8(sp)
    addi sp, sp, 16
    ret
# read_line: a0 = buffer, a1 = max length. returns a0 = length.
read_line:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    mv s0, a0
    mv s1, a1
    li s2, 0
read_line_loop:
    li a7, 4
    ecall
    li t0, 10
    beq a0, t0, read_line_done
    li t0, 13
    beq a0, t0, read_line_done
    li t0, 8
    beq a0, t0, read_line_backspace
    li t0, 127
    beq a0, t0, read_line_backspace
    addi t0, s1, -1
    bge s2, t0, read_line_loop
    add t0, s0, s2
    sb a0, 0(t0)
    addi s2, s2, 1
    li a7, 1
    ecall
    j read_line_loop
read_line_backspace:
    beqz s2, read_line_loop
    addi s2, s2, -1
    li a0, 8
    li a7, 1
    ecall
    li a0, 32
    li a7, 1
    ecall
    li a0, 8
    li a7, 1
    ecall
    j read_line_loop
read_line_done:
    add t0, s0, s2
    sb zero, 0(t0)
    li a0, 10
    li a7, 1
    ecall
    mv a0, s2
    lw ra, 28(sp)
    lw s0, 24(sp)
    lw s1, 20(sp)
    lw s2, 16(sp)
    addi sp, sp, 32
    ret
# cmd_eq: a0 = token ptr, a1 = token length, a2 = literal ptr. returns a0 = 1 if equal.
cmd_eq:
    mv t0, a0
    mv t1, a1
    mv t2, a2
cmd_eq_loop:
    beqz t1, cmd_eq_check_end
    lb t3, 0(t2)
    beqz t3, cmd_eq_false
    lb t4, 0(t0)
    bne t3, t4, cmd_eq_false
    addi t0, t0, 1
    addi t2, t2, 1
    addi t1, t1, -1
    j cmd_eq_loop
cmd_eq_check_end:
    lb t3, 0(t2)
    bnez t3, cmd_eq_false
    li a0, 1
    ret
cmd_eq_false:
    li a0, 0
    ret
# parse_int: a0 = string ptr. returns a0 = value, a1 = digits consumed.
parse_int:
    li t0, 0
    li t1, 0
    li t5, 0
    lb t2, 0(a0)
    li t3, 45
    bne t2, t3, parse_int_loop
    li t5, 1
    addi a0, a0, 1
parse_int_loop:
    lb t2, 0(a0)
    li t3, 48
    blt t2, t3, parse_int_done
    li t3, 57
    bgt t2, t3, parse_int_done
    addi t2, t2, -48
    slli t4, t0, 3
    slli t0, t0, 1
    add t0, t0, t4
    add t0, t0, t2
    addi t1, t1, 1
    addi a0, a0, 1
    j parse_int_loop
parse_int_done:
    beqz t5, parse_int_pos
    neg t0, t0
parse_int_pos:
    mv a0, t0
    mv a1, t1
    ret

# ---- data ----
    .data
str_banner: .asciiz "========================================\\n  retasuOS 0.1.0 for retasuVM\\n  RISC-V RV32I virtual machine\\n========================================\\nType 'help' for commands.\\n"
str_prompt: .asciiz "retasuOS> "
str_help: .asciiz "Available commands:\\n  help        show this help\\n  echo <text> print text\\n  fib <n>     compute the n-th Fibonacci number (0-46)\\n  about       about retasuOS\\n  ver         show version\\n  clear       clear the console\\n  halt        power off\\n"
str_about: .asciiz "retasuOS is a tiny guest OS running on the retasuVM RISC-V (RV32I) emulator. The CPU, the assembler and this OS all run inside the app.\\n"
str_ver: .asciiz "retasuOS version 0.1.0 (RISC-V RV32I)\\n"
str_unknown: .asciiz "Unknown command. Type 'help'.\\n"
str_bye: .asciiz "retasuOS halted. Bye.\\n"
str_fib_pre: .asciiz "fib("
str_fib_mid: .asciiz ") = "
str_fib_usage: .asciiz "Usage: fib <n>  (0 <= n <= 46)\\n"
cmd_help: .asciiz "help"
cmd_echo: .asciiz "echo"
cmd_fib: .asciiz "fib"
cmd_about: .asciiz "about"
cmd_ver: .asciiz "ver"
cmd_clear: .asciiz "clear"
cmd_halt: .asciiz "halt"
cmd_exit: .asciiz "exit"
cmd_quit: .asciiz "quit"
linebuf: .space 128
"""
}
