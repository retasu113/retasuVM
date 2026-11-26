// Phase 20 fix differential: cross-page load/store with
// VA-contiguous / PA-scattered pages.
// VA 0x40600000 -> PA 0x40800000 (page A)
// VA 0x40604000 -> PA 0x40410000 (page B)
// PA 0x40804000 (marker page, VA identity 0x40804000) filled 0xEE.
// Correct cross-boundary 8-byte load at A+0x3ffc:
//   [A ffc..fff][B 0..3] = 11 22 33 44 55 66 77 88
// Buggy (PA-contiguous) load: [A ffc..fff][marker 0xEE x4].
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define MB ((volatile uint32_t *)0x40200000)
static volatile uint8_t *A = (volatile uint8_t *)0x40600000;
static volatile uint8_t *MARK = (volatile uint8_t *)0x40804000;

void guest_main(void) {
    for (int i = 0; i < 16; i++) MARK[i] = 0xEE;
    A[0x3ffc] = 0x11; A[0x3ffd] = 0x22; A[0x3ffe] = 0x33; A[0x3fff] = 0x44;
    A[0x4000] = 0x55; A[0x4001] = 0x66; A[0x4002] = 0x77; A[0x4003] = 0x88;
    uint64_t v;
    memcpy(&v, (const void *)(A + 0x3ffc), 8);  // may be optimized to ldr
    volatile uint64_t *wp = (volatile uint64_t *)(A + 0x3ffc);
    uint64_t v2 = *wp;  // guaranteed 8-byte load
    uint32_t mism = 0;
    if (v2 != 0x8877665544332211ULL) mism++;
    // cross-boundary store
    *wp = 0x0123456789abcdefULL;
    if (A[0x3ffc] != 0xef || A[0x3ffd] != 0xcd || A[0x3ffe] != 0xab || A[0x3fff] != 0x89) mism++;
    if (A[0x4000] != 0x67 || A[0x4001] != 0x45 || A[0x4002] != 0x23 || A[0x4003] != 0x01) mism++;
    if (MARK[0] != 0xEE || MARK[1] != 0xEE || MARK[2] != 0xEE || MARK[3] != 0xEE) mism++;
    MB[2] = (uint32_t)(v2 & 0xffffffff);
    MB[3] = (uint32_t)(v2 >> 32);
    MB[4] = mism;
    MB[5] = 0;
    MB[0] = 0x4C5A564E;
    register uint64_t x0 asm("x0") = 0x18;
    register uint64_t x1 asm("x1") = 0x40200100;
    asm volatile("hlt #0xf000" : : "r"(x0), "r"(x1));
    for (;;) {}
}
