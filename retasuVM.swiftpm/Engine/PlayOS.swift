import Foundation

/// ゲスト OS「PlayOS」: 数当てゲームとサイコロで遊べる小さなゲスト。
///
/// 乱数は CPU の乱数システムコール（a7=6）から取得し、剰余計算には
/// M 拡張の remu 命令を使う。
enum PlayOS {
    static let source = GuestRuntime.source + """

# ---- PlayOS main ----
    .text
main:
    addi sp, sp, -16
    sw ra, 12(sp)
    la a0, game_banner
    call print_str
game_loop:
    la a0, game_prompt
    call print_str
    la a0, linebuf
    li a1, 128
    call read_line
    la s0, linebuf
game_skip_lead:
    lb t0, 0(s0)
    li t1, 32
    bne t0, t1, game_token_start
    addi s0, s0, 1
    j game_skip_lead
game_token_start:
    lb t0, 0(s0)
    beqz t0, game_loop
    mv s1, s0
game_token_scan:
    lb t0, 0(s0)
    beqz t0, game_token_done
    li t1, 32
    beq t0, t1, game_token_done
    addi s0, s0, 1
    j game_token_scan
game_token_done:
    sub s2, s0, s1
    mv a0, s1
    mv a1, s2
    la a2, game_cmd_guess
    call cmd_eq
    bnez a0, game_guess_start
    mv a0, s1
    mv a1, s2
    la a2, game_cmd_dice
    call cmd_eq
    bnez a0, game_dice
    mv a0, s1
    mv a1, s2
    la a2, game_cmd_help
    call cmd_eq
    bnez a0, game_help
    mv a0, s1
    mv a1, s2
    la a2, game_cmd_quit
    call cmd_eq
    bnez a0, game_quit
    mv a0, s1
    mv a1, s2
    la a2, game_cmd_exit
    call cmd_eq
    bnez a0, game_quit
    la a0, game_unknown
    call print_str
    j game_loop
game_help:
    la a0, game_help_text
    call print_str
    j game_loop
game_quit:
    la a0, game_bye
    call print_str
    li a0, 0
    li a7, 10
    ecall
game_dice:
    li a7, 6
    ecall
    li t0, 6
    remu a0, a0, t0
    addi s5, a0, 1
    la a0, game_dice_text
    call print_str
    mv a0, s5
    call print_int
    call print_nl
    j game_loop
game_guess_start:
    li a7, 6
    ecall
    li t0, 100
    remu a0, a0, t0
    addi s5, a0, 1
    li s6, 0
    la a0, game_guess_intro
    call print_str
game_guess_loop:
    la a0, game_guess_prompt
    call print_str
    la a0, linebuf
    li a1, 128
    call read_line
    la a0, linebuf
    call parse_int
    beqz a1, game_guess_invalid
    addi s6, s6, 1
    beq a0, s5, game_guess_win
    blt a0, s5, game_guess_higher
    la a0, game_lower_text
    call print_str
    j game_guess_loop
game_guess_higher:
    la a0, game_higher_text
    call print_str
    j game_guess_loop
game_guess_invalid:
    la a0, game_invalid_text
    call print_str
    j game_guess_loop
game_guess_win:
    la a0, game_win_pre
    call print_str
    mv a0, s6
    call print_int
    la a0, game_win_post
    call print_str
    j game_loop

    .data
game_banner: .asciiz "========================================\\n  PlayOS 1.0 for retasuVM\\n  tiny game OS (RISC-V RV32IM)\\n========================================\\nType 'help' for commands.\\n"
game_prompt: .asciiz "play> "
game_help_text: .asciiz "Available commands:\\n  guess   number guessing game (1-100)\\n  dice    roll a die\\n  help    show this help\\n  quit    power off\\n"
game_unknown: .asciiz "Unknown command. Type 'help'.\\n"
game_bye: .asciiz "PlayOS halted. Bye.\\n"
game_dice_text: .asciiz "dice: "
game_guess_intro: .asciiz "I am thinking of a number between 1 and 100.\\n"
game_guess_prompt: .asciiz "your guess: "
game_higher_text: .asciiz "Higher!\\n"
game_lower_text: .asciiz "Lower!\\n"
game_invalid_text: .asciiz "Please enter a number.\\n"
game_win_pre: .asciiz "Correct! tries: "
game_win_post: .asciiz "\\n"
game_cmd_guess: .asciiz "guess"
game_cmd_dice: .asciiz "dice"
game_cmd_help: .asciiz "help"
game_cmd_quit: .asciiz "quit"
game_cmd_exit: .asciiz "exit"
"""
}
