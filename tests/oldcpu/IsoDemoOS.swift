import Foundation

/// ISO ブート確認用のゲスト OS「IsoDemoOS」。
///
/// サンプル ISO の `BOOT.BIN` として収録され、ISO から直接起動する。
/// ディスク読み取りシステムコール（a7=20/21/22）で自分が起動した
/// ディスクの情報（容量・ボリュームラベル・CD001 シグネチャ）を表示する。
enum IsoDemoOS {
    static let source = GuestRuntime.source + """

# ---- IsoDemoOS main ----
    .text
main:
    addi sp, sp, -16
    sw ra, 12(sp)
    la a0, iso_banner
    call print_str
iso_loop:
    la a0, iso_prompt
    call print_str
    la a0, linebuf
    li a1, 128
    call read_line
    la s0, linebuf
iso_skip_lead:
    lb t0, 0(s0)
    li t1, 32
    bne t0, t1, iso_token_start
    addi s0, s0, 1
    j iso_skip_lead
iso_token_start:
    lb t0, 0(s0)
    beqz t0, iso_loop
    mv s1, s0
iso_token_scan:
    lb t0, 0(s0)
    beqz t0, iso_token_done
    li t1, 32
    beq t0, t1, iso_token_done
    addi s0, s0, 1
    j iso_token_scan
iso_token_done:
    sub s2, s0, s1
    mv a0, s1
    mv a1, s2
    la a2, iso_cmd_info
    call cmd_eq
    bnez a0, iso_info
    mv a0, s1
    mv a1, s2
    la a2, iso_cmd_help
    call cmd_eq
    bnez a0, iso_help
    mv a0, s1
    mv a1, s2
    la a2, iso_cmd_quit
    call cmd_eq
    bnez a0, iso_quit
    mv a0, s1
    mv a1, s2
    la a2, iso_cmd_exit
    call cmd_eq
    bnez a0, iso_quit
    la a0, iso_unknown
    call print_str
    j iso_loop
iso_help:
    la a0, iso_help_text
    call print_str
    j iso_loop
iso_quit:
    la a0, iso_bye
    call print_str
    li a0, 0
    li a7, 10
    ecall
iso_info:
    li a7, 22
    ecall
    mv s5, a0
    beqz s5, iso_info_nodisc
    la a0, iso_disc_text
    call print_str
    mv a0, s5
    call print_int
    la a0, iso_bytes_text
    call print_str
    li a7, 20
    ecall
    call print_int
    la a0, iso_sectors_text
    call print_str
    li a0, 16
    la a1, sectorbuf
    li a7, 21
    ecall
    bnez a0, iso_read_error
    la t0, sectorbuf
    lb t1, 1(t0)
    li t2, 67
    bne t1, t2, iso_not_iso
    lb t1, 2(t0)
    li t2, 68
    bne t1, t2, iso_not_iso
    lb t1, 3(t0)
    li t2, 48
    bne t1, t2, iso_not_iso
    la a0, iso_confirmed_text
    call print_str
    la a0, iso_volume_text
    call print_str
    la t0, sectorbuf
    addi t0, t0, 40
    li t3, 0
iso_label_loop:
    li t4, 32
    bge t3, t4, iso_label_done
    lb a0, 0(t0)
    li a7, 1
    ecall
    addi t0, t0, 1
    addi t3, t3, 1
    j iso_label_loop
iso_label_done:
    call print_nl
    j iso_loop
iso_not_iso:
    la a0, iso_notiso_text
    call print_str
    j iso_loop
iso_read_error:
    la a0, iso_readerr_text
    call print_str
    j iso_loop
iso_info_nodisc:
    la a0, iso_nodisc_text
    call print_str
    j iso_loop

    .data
iso_banner: .asciiz "========================================\\n  IsoDemoOS 1.0 - booted from ISO 9660\\n  RISC-V RV32IM virtual machine\\n========================================\\nType 'info' to inspect this disc.\\n"
iso_prompt: .asciiz "iso> "
iso_help_text: .asciiz "Available commands:\\n  info    show disc size, format and volume label\\n  help    show this help\\n  quit    power off\\n"
iso_unknown: .asciiz "Unknown command. Type 'help'.\\n"
iso_bye: .asciiz "IsoDemoOS halted. Bye.\\n"
iso_disc_text: .asciiz "disc: "
iso_bytes_text: .asciiz " bytes, "
iso_sectors_text: .asciiz " sectors\\n"
iso_confirmed_text: .asciiz "format: ISO 9660 (CD001)\\n"
iso_volume_text: .asciiz "volume: "
iso_notiso_text: .asciiz "format: not ISO 9660\\n"
iso_readerr_text: .asciiz "error: disc read failed\\n"
iso_nodisc_text: .asciiz "no disc attached\\n"
iso_cmd_info: .asciiz "info"
iso_cmd_help: .asciiz "help"
iso_cmd_quit: .asciiz "quit"
iso_cmd_exit: .asciiz "exit"
sectorbuf: .space 2048
"""
}
