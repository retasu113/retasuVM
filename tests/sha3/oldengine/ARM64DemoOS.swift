import Foundation

/// ARM64 用のデモゲスト「Arm64DemoOS」のアセンブリソース。
///
/// 自作の AArch64 アセンブラで機械語へ変換され、`ARM64CPU` 上で動く。
/// コマンド: help / fact（階乗）/ echo / quit
/// コンソール入出力は SVC サービス（1=putchar, 2=print int, 3=print
/// string, 4=getchar, 10=exit）を使う。
enum ARM64DemoOS {
    static let source = """
            .text
            .globl _start
    _start:
            bl main
            mov x0, #0
            svc #10
    main:
            stp x29, x30, [sp, #-16]!
            ldr x0, =msg_banner
            bl print_str
    main_loop:
            ldr x0, =msg_prompt
            bl print_str
            ldr x0, =linebuf
            bl read_line
            ldr x19, =linebuf
            mov x20, #0
    tok_loop:
            ldrb w21, [x19, x20]
            cmp w21, #0
            b.eq tok_done
            cmp w21, #32
            b.eq tok_done
            add x20, x20, #1
            b tok_loop
    tok_done:
            mov x0, x19
            mov x1, x20
            ldr x2, =cmd_help
            bl cmd_eq
            cmp x0, #1
            b.eq do_help
            mov x0, x19
            mov x1, x20
            ldr x2, =cmd_fact
            bl cmd_eq
            cmp x0, #1
            b.eq do_fact
            mov x0, x19
            mov x1, x20
            ldr x2, =cmd_echo
            bl cmd_eq
            cmp x0, #1
            b.eq do_echo
            mov x0, x19
            mov x1, x20
            ldr x2, =cmd_quit
            bl cmd_eq
            cmp x0, #1
            b.eq do_quit
            cmp x20, #0
            b.eq main_loop
            ldr x0, =msg_unknown
            bl print_str
            b main_loop
    do_help:
            ldr x0, =msg_help
            bl print_str
            b main_loop
    do_quit:
            ldr x0, =msg_bye
            bl print_str
            mov x0, #0
            svc #10
    do_echo:
            ldrb w21, [x19, x20]
            cmp w21, #32
            b.ne echo_nl
            add x19, x19, x20
            add x19, x19, #1
            mov x0, x19
            bl print_str
    echo_nl:
            ldr x0, =msg_nl
            bl print_str
            b main_loop
    do_fact:
            add x19, x19, x20
            ldrb w21, [x19]
            cmp w21, #32
            b.ne fact_default
            add x19, x19, #1
            mov x0, x19
            bl parse_num
            b fact_go
    fact_default:
            mov x0, #12
    fact_go:
            mov x1, #1
            mov x2, #1
    fact_loop:
            cmp x2, x0
            b.hi fact_print
            mul x1, x1, x2
            add x2, x2, #1
            b fact_loop
    fact_print:
            mov x21, x0
            mov x0, x1
            bl print_int
            ldr x0, =msg_fact_tail
            bl print_str
            b main_loop
    print_str:
            svc #3
            ret
    print_int:
            svc #2
            ret
    parse_num:
            mov x1, #0
    parse_loop:
            ldrb w2, [x0]
            cmp w2, #0
            b.eq parse_done
            cmp w2, #48
            b.lo parse_done
            cmp w2, #57
            b.hi parse_done
            sub w2, w2, #48
            mov x3, #10
            mul x1, x1, x3
            add x1, x1, x2
            add x0, x0, #1
            b parse_loop
    parse_done:
            mov x0, x1
            ret
    read_line:
            mov x1, #0
            mov x19, x0
    read_loop:
            svc #4
            cmp x0, #10
            b.eq read_done
            cmp x0, #13
            b.eq read_done
            svc #1
            cmp x1, #120
            b.hi read_loop
            strb w0, [x19, x1]
            add x1, x1, #1
            b read_loop
    read_done:
            mov x2, #10
            svc #1
            mov x2, #0
            strb w2, [x19, x1]
            ret
    cmd_eq:
            mov x3, #0
    cmd_eq_loop:
            cmp x3, x1
            b.hi cmd_eq_yes
            ldrb w4, [x2, x3]
            cmp w4, #0
            b.eq cmd_eq_len
            ldrb w5, [x0, x3]
            cmp w5, w4
            b.ne cmd_eq_no
            add x3, x3, #1
            b cmd_eq_loop
    cmd_eq_len:
            cmp x3, x1
            b.eq cmd_eq_yes
    cmd_eq_no:
            mov x0, #0
            ret
    cmd_eq_yes:
            mov x0, #1
            ret
    msg_banner: .asciz "Arm64DemoOS (AArch64) - type 'help'\\n"
    msg_prompt: .asciz "> "
    msg_help:   .asciz "commands: help / fact [n] / echo <text> / quit\\n"
    msg_unknown: .asciz "unknown command\\n"
    msg_bye:    .asciz "bye\\n"
    msg_nl:     .asciz "\\n"
    msg_fact_tail: .asciz "\\n"
    cmd_help:   .asciz "help"
    cmd_fact:   .asciz "fact"
    cmd_echo:   .asciz "echo"
    cmd_quit:   .asciz "quit"
            .align 3
    linebuf:    .space 128
    """
}
