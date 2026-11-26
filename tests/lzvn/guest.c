// Phase 19 differential guest: LZVN-decode the real launchd chunk 0
// with the reference decoder (lzvn_decode_base.c) and compare against
// the embedded expected output. Results -> mailbox at 0x40200000:
//   +0x00 u32 DONE magic 0x4C5A564E ("LZVN")
//   +0x08 u64 FNV-1a hash of produced output
//   +0x10 u32 mismatch count
//   +0x14 u32 decoded size
//   +0x20 first 8 mismatches: {u32 off, u32 got, u32 want} x8
// Also formats a one-line summary to the PL011 (QEMU virt).
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "lzvn_decode_base.h"

#include "chunk_in.inc"
#include "expected_out.inc"

static unsigned char out_buf[65536 + 64];

#define MB ((volatile uint32_t *)0x40200000)

static void uart_putc(char c) {
    *(volatile uint8_t *)0x09000000 = (uint8_t)c;
}
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(uint64_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--) {
        int d = (v >> (4 * i)) & 0xf;
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

void guest_main(void) {
    lzvn_decoder_state st;
    memset(&st, 0, sizeof st);
    st.src = chunk_in;
    st.src_end = chunk_in + sizeof chunk_in;
    st.dst = out_buf;
    st.dst_begin = out_buf;
    st.dst_end = out_buf + sizeof out_buf;
    st.dst_current = out_buf;
    lzvn_decode(&st);
    size_t nout = (size_t)(st.dst - out_buf);

    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < nout && i < 65536; i++) {
        h ^= out_buf[i];
        h *= 1099511628211ULL;
    }
    uint32_t mism = 0;
    volatile uint32_t *rec = MB + 8;  // 0x40200020
    for (size_t i = 0; i < 65536; i++) {
        if (out_buf[i] != expected_out[i]) {
            if (mism < 8) {
                rec[mism * 3 + 0] = (uint32_t)i;
                rec[mism * 3 + 1] = out_buf[i];
                rec[mism * 3 + 2] = expected_out[i];
            }
            mism++;
        }
    }
    MB[2] = (uint32_t)(h & 0xffffffff);
    MB[3] = (uint32_t)(h >> 32);
    MB[4] = mism;
    MB[5] = (uint32_t)nout;
    MB[0] = 0x4C5A564E;

    uart_puts("LZVN-DIFF nout=");
    uart_hex(nout, 6);
    uart_puts(" mism=");
    uart_hex(mism, 4);
    uart_puts(" fnv=");
    uart_hex(h, 16);
    if (mism) {
        uart_puts(" first=");
        uart_hex(rec[0], 6);
        uart_puts(":");
        uart_hex(rec[1], 2);
        uart_puts("!=");
        uart_hex(rec[2], 2);
    }
    uart_puts("\n");
    // semihosting exit (QEMU); ignored elsewhere.
    // Parameter block: {ADP_Stopped_ApplicationExit, exit_code}.
    volatile uint64_t *sb = (volatile uint64_t *)0x40200100;
    sb[0] = 0x20026;
    sb[1] = mism ? 42 : 0;
    register uint64_t x0 asm("x0") = 0x18;
    register uint64_t x1 asm("x1") = 0x40200100;
    asm volatile("hlt #0xf000" : : "r"(x0), "r"(x1));
    for (;;) {}
}
