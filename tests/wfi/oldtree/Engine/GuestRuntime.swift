import Foundation

/// 複数のゲスト OS で共有するランタイム（アセンブリ）。
///
/// `_start` と基本ルーチン（文字列出力・整数出力・改行・1 行入力・
/// コマンド比較・整数パース）を提供する。各ゲストはこのソースの後ろに
/// 自分の `main` とデータをつなげて 1 つのプログラムにする。
///
/// システムコール（ECALL、番号は a7）:
/// 1 = 1文字出力 / 2 = 整数出力 / 3 = 文字列出力 / 4 = 1文字入力 /
/// 5 = 画面消去 / 6 = 乱数 / 10 = 終了
enum GuestRuntime {
    static let source = """
# ---- guest runtime (shared) ----
    .text
    .globl _start
_start:
    li sp, 0x100000
    call main
    li a0, 0
    li a7, 10
    ecall

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

    .data
linebuf: .space 128
"""
}
