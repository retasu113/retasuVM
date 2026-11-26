import Foundation

/// ARM 用のデモゲスト「ArmDemoOS」のアセンブリソース。
///
/// 自作の ARM アセンブラで機械語へ変換され、`ARMCPU` 上で動く。
/// コマンド: help / fact（12! を計算）/ echo / quit
enum ARMDemoOS {
    static let source = """
            .text
            .globl _start
    _start:
            ldr sp, =0x400000
            bl main
            mov r0, #0
            svc #10
    main:
            push {lr}
            ldr r0, =msg_banner
            bl print_str
    main_loop:
            ldr r0, =msg_prompt
            bl print_str
            ldr r0, =linebuf
            bl read_line
            ldr r4, =linebuf
            mov r5, #0
    tok_loop:
            ldrb r6, [r4, r5]
            cmp r6, #0
            beq tok_done
            cmp r6, #32
            beq tok_done
            add r5, r5, #1
            b tok_loop
    tok_done:
            mov r0, r4
            mov r1, r5
            ldr r2, =cmd_help
            bl cmd_eq
            cmp r0, #1
            beq do_help
            mov r0, r4
            mov r1, r5
            ldr r2, =cmd_fact
            bl cmd_eq
            cmp r0, #1
            beq do_fact
            mov r0, r4
            mov r1, r5
            ldr r2, =cmd_echo
            bl cmd_eq
            cmp r0, #1
            beq do_echo
            mov r0, r4
            mov r1, r5
            ldr r2, =cmd_quit
            bl cmd_eq
            cmp r0, #1
            beq do_quit
            cmp r5, #0
            beq main_loop
            ldr r0, =msg_unknown
            bl print_str
            b main_loop
    do_help:
            ldr r0, =msg_help
            bl print_str
            b main_loop
    do_fact:
            mov r7, #1
            mov r8, #2
    fact_loop:
            cmp r8, #12
            bgt fact_done
            mul r7, r7, r8
            add r8, r8, #1
            b fact_loop
    fact_done:
            ldr r0, =msg_fact_prefix
            bl print_str
            mov r0, r7
            svc #2
            bl print_nl
            b main_loop
    do_echo:
            ldr r4, =linebuf
            add r4, r4, r5
    echo_skip:
            ldrb r6, [r4]
            cmp r6, #32
            bne echo_go
            add r4, r4, #1
            b echo_skip
    echo_go:
            mov r0, r4
            bl print_str
            bl print_nl
            b main_loop
    do_quit:
            ldr r0, =msg_bye
            bl print_str
            mov r0, #0
            svc #10
    print_str:
            push {r4, lr}
            mov r4, r0
    ps_loop:
            ldrb r0, [r4], #1
            cmp r0, #0
            beq ps_done
            svc #1
            b ps_loop
    ps_done:
            pop {r4, lr}
            bx lr
    print_nl:
            mov r0, #10
            svc #1
            bx lr
    read_line:
            push {r4, r5, lr}
            mov r4, r0
            mov r5, #0
    rl_loop:
            svc #4
            cmp r0, #10
            beq rl_done
            cmp r0, #13
            beq rl_done
            cmp r0, #8
            beq rl_backspace
            cmp r0, #127
            beq rl_backspace
            strb r0, [r4, r5]
            add r5, r5, #1
            svc #1
            b rl_loop
    rl_backspace:
            cmp r5, #0
            beq rl_loop
            sub r5, r5, #1
            mov r0, #8
            svc #1
            mov r0, #32
            svc #1
            mov r0, #8
            svc #1
            b rl_loop
    rl_done:
            mov r0, #0
            strb r0, [r4, r5]
            mov r0, #10
            svc #1
            mov r0, r5
            pop {r4, r5, lr}
            bx lr
    cmd_eq:
            push {r4, r5}
            mov r3, #0
    ce_loop:
            cmp r3, r1
            bge ce_check_end
            ldrb r4, [r0, r3]
            ldrb r5, [r2, r3]
            cmp r4, r5
            bne ce_no
            add r3, r3, #1
            b ce_loop
    ce_check_end:
            ldrb r4, [r2, r3]
            cmp r4, #0
            bne ce_no
            mov r0, #1
            pop {r4, r5}
            bx lr
    ce_no:
            mov r0, #0
            pop {r4, r5}
            bx lr
            .data
    msg_banner: .asciiz "ArmDemoOS 1.0 (ARMv7-A) - type 'help'\\n"
    msg_prompt: .asciiz "arm> "
    msg_help: .asciiz "commands: help / fact / echo <text> / quit\\n"
    msg_fact_prefix: .asciiz "12! = "
    msg_unknown: .asciiz "unknown command\\n"
    msg_bye: .asciiz "bye\\n"
    cmd_help: .asciiz "help"
    cmd_fact: .asciiz "fact"
    cmd_echo: .asciiz "echo"
    cmd_quit: .asciiz "quit"
    linebuf: .space 128
    """
}
