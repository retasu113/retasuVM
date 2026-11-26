struct sha256_ce_state {
    unsigned int state[8];
    unsigned long count;
    unsigned char buf[64];
    unsigned int finalize;
};
void sha2_ce_transform(struct sha256_ce_state *sst, const unsigned char *src, int blocks);

unsigned int results[5][8];
static unsigned char data[16 * 64];
static unsigned int rng_state;
static unsigned int rnd(void) {
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state >> 24;
}
static const unsigned int IV[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
};
void run_tests(void) {
    static const int blkcounts[5] = {1, 2, 4, 16, 2};
    rng_state = 0x12345678u;
    for (int i = 0; i < (int)sizeof(data); i++) data[i] = (unsigned char)rnd();
    for (int t = 0; t < 5; t++) {
        struct sha256_ce_state st;
        for (int i = 0; i < 8; i++) st.state[i] = IV[i];
        st.count = 0; st.finalize = 0;
        const unsigned char *src = data;
        if (t == 4) { /* pattern case: two blocks of 'a'..'p' repeated */
            for (int i = 0; i < 128; i++) data[i] = (unsigned char)('a' + (i & 15));
        }
        sha2_ce_transform(&st, src, blkcounts[t]);
        for (int i = 0; i < 8; i++) results[t][i] = st.state[i];
    }
}
