// Phase 19 differential guest #2: run the KERNEL's own
// _lzvn_decode_buffer machine code (extracted from kernelcache
// 0xfffffe0009878b00, self-contained incl. its jump table) on the
// real launchd chunk 0 and compare against the expected output.
// Mailbox at 0x40200000, same layout as guest.c.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "chunk_in.inc"
#include "expected_out.inc"
#include "blob.inc"

static unsigned char out_buf[65536 + 64];
static unsigned char blob_buf[2048];

#define MB ((volatile uint32_t *)0x40200000)

typedef size_t (*decfn)(uint8_t *, size_t, const uint8_t *, size_t);

static void uart_putc(char c) { *(volatile uint8_t *)0x09000000 = (uint8_t)c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(uint64_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--) {
        int d = (v >> (4 * i)) & 0xf;
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

void guest_main(void) {
    memcpy(blob_buf, kc_lzvn, sizeof kc_lzvn);
    decfn decode = (decfn)(void *)blob_buf;
    size_t nout = decode(out_buf, sizeof out_buf, chunk_in, sizeof chunk_in);

    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < nout && i < 65536; i++) {
        h ^= out_buf[i];
        h *= 1099511628211ULL;
    }
    uint32_t mism = 0;
    volatile uint32_t *rec = MB + 8;
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

    uart_puts("KC-LZVN nout=");
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
    volatile uint64_t *sb = (volatile uint64_t *)0x40200100;
    sb[0] = 0x20026;
    sb[1] = mism ? 42 : 0;
    register uint64_t x0 asm("x0") = 0x18;
    register uint64_t x1 asm("x1") = 0x40200100;
    asm volatile("hlt #0xf000" : : "r"(x0), "r"(x1));
    for (;;) {}
}
