/* Phase 22: scan the p23 DRAM dump for adjacent qword pairs (start,end)
 * whose difference equals one of the dyld-cache mapping sizes, with start
 * in the plausible slid-cache VA range and 16K-aligned.
 * vm_map_entry has vme_start/vme_end adjacent at +0x10/+0x18, so the pair
 * appears regardless of struct offset; prev/next qwords are reported for
 * filtering (they should be kernel VAs 0xfffffe... for a real entry).
 *
 * Usage: p22_vmscan <dump.bin>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const uint64_t SIZES[8] = {
    0x67f5c000ULL, /* m0 __TEXT */
    0x1e90000ULL,  /* m1 */
    0x239c000ULL,  /* m2 */
    0x24000ULL,    /* m3 */
    0x1200000ULL,  /* m4 */
    0x7cc4000ULL,  /* m5 */
    0x5cdc000ULL,  /* m6 */
    0x268c0000ULL, /* m7 */
};
static const uint64_t ADDRS[8] = {
    0x180000000ULL, 0x1e7f5c000ULL, 0x1ebdec000ULL, 0x1ee188000ULL,
    0x1ee1ac000ULL, 0x1ef3ac000ULL, 0x1f9070000ULL, 0x1fed4c000ULL,
};

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dump>\n", argv[0]); return 1; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    fstat(fd, &st);
    size_t len = (size_t)st.st_size;
    uint64_t *q = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    if (q == MAP_FAILED) { perror("mmap"); return 1; }
    size_t n = len / 8;
    size_t hits = 0;
    for (size_t i = 2; i + 1 < n; i++) {
        uint64_t s = q[i], e = q[i + 1];
        if (e <= s) continue;
        uint64_t d = e - s;
        int si = -1;
        for (int k = 0; k < 8; k++) if (d == SIZES[k]) { si = k; break; }
        if (si < 0) continue;
        if (s < 0x180000000ULL || s >= 0x260000000ULL) continue;
        if (s & 0x3FFFULL) continue;
        uint64_t prev = q[i - 2], next = q[i - 1];
        uint64_t slide = s - ADDRS[si];
        printf("HIT fileoff=0x%zx (PA 0x%zx) size_idx=%d size=0x%llx start=0x%llx end=0x%llx slide=0x%llx prev=0x%llx next=0x%llx\n",
               i * 8, i * 8 + 0x70000000ULL, si,
               (unsigned long long)d,
               (unsigned long long)s, (unsigned long long)e,
               (unsigned long long)slide,
               (unsigned long long)prev, (unsigned long long)next);
        hits++;
    }
    fprintf(stderr, "done, %zu hits\n", hits);
    return 0;
}
