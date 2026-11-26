/* Phase 23: scan a DRAM dump for thread structs by signature.
   Candidate: u64(base+0x498) is a small thread id (1..0xFFFF)
   AND u64(base+0x3D8) is a kernel VA (0xFFFFFE0000000000..0xFFFFFEFFFFFFFFFF).
   Prints candidate file offsets (== PA - 0x70000000) and the two values.
   Compile: gcc -O2 -o p23_thscan p23_thscan.c
   Usage: ./p23_thscan <dump> > candidates.txt
*/
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dump>\n", argv[0]); return 1; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    fstat(fd, &st);
    size_t sz = (size_t)st.st_size;
    uint8_t *m = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    const uint64_t KLO = 0xFFFFFE0000000000ULL;
    const uint64_t KHI = 0xFFFFFEFFFFFFFFFFULL;
    size_t n = 0;
    for (size_t o = 0; o + 0x498 + 8 <= sz; o += 8) {
        uint64_t id = *(uint64_t *)(m + o + 0x498);
        if (id == 0 || id > 0xFFFF) continue;
        uint64_t tro = *(uint64_t *)(m + o + 0x3D8);
        if (tro < KLO || tro > KHI) continue;
        uint64_t stk = *(uint64_t *)(m + o + 0xE8);
        printf("%zu id=%llu tro=%#llx stk=%#llx\n",
               o, (unsigned long long)id,
               (unsigned long long)tro, (unsigned long long)stk);
        n++;
    }
    fprintf(stderr, "candidates: %zu\n", n);
    return 0;
}
