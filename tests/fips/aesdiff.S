
    .text
    .globl _start
_start:
#ifdef ENGINE
    ldr x12, =0x09000000
#endif

    // sweep pair 0
    ldr x13, =pair0a
    ldr x14, =pair0b
    ldr x21, =name_aese0
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd0
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc0
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc0
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2560
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5120
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull0
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex

    // sweep pair 1
    ldr x13, =pair1a
    ldr x14, =pair1b
    ldr x21, =name_aese1
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd1
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc1
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc1
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2561
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5121
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull1
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex

    // sweep pair 2
    ldr x13, =pair2a
    ldr x14, =pair2b
    ldr x21, =name_aese2
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd2
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc2
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc2
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2562
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5122
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull2
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex

    // sweep pair 3
    ldr x13, =pair3a
    ldr x14, =pair3b
    ldr x21, =name_aese3
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd3
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc3
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc3
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2563
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5123
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull3
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex

    // sweep pair 4
    ldr x13, =pair4a
    ldr x14, =pair4b
    ldr x21, =name_aese4
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd4
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc4
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc4
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2564
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5124
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull4
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex

    // sweep pair 5
    ldr x13, =pair5a
    ldr x14, =pair5b
    ldr x21, =name_aese5
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aese v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesd5
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    bl print_v0_hex
    ldr x21, =name_aesmc5
    bl print_str
    ld1 {v0.16b}, [x13]
    aesmc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_aesimc5
    bl print_str
    ld1 {v0.16b}, [x13]
    aesimc v0.16b, v0.16b
    bl print_v0_hex
    ldr x21, =name_sha2565
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha256su0 v2.4s, v0.4s
    sha256h q0, q1, v2.4s
    sha256h2 q1, q0, v2.4s
    sha256su1 v0.4s, v1.4s, v2.4s
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_sha5125
    bl print_str
    ld1 {v0.16b}, [x13]
    ld1 {v1.16b}, [x14]
    ld1 {v2.16b}, [x13]
    sha512su0 v2.2d, v0.2d
    sha512h q0, q1, v2.2d
    sha512h2 q1, q0, v2.2d
    sha512su1 v0.2d, v1.2d, v2.2d
    bl print_v0_hex
    mov v0.16b, v1.16b
    bl print_v0_hex
    mov v0.16b, v2.16b
    bl print_v0_hex
    ldr x21, =name_pmull5
    bl print_str
    ld1 {v1.16b}, [x13]
    ld1 {v2.16b}, [x14]
    pmull v0.1q, v1.1d, v2.1d
    bl print_v0_hex
    pmull2 v0.1q, v1.2d, v2.2d
    bl print_v0_hex


    ldr x21, =name_enc_fips197_128
    bl print_str
    ldr x13, =fips197_128_pt
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_128_rk
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    ld1 {v1.16b}, [x13], #16
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_dec_fips197_128
    bl print_str
    ldr x13, =fips197_128_ct
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_128_rk
    add x13, x13, #160
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    ldr x13, =zero16
    ld1 {v1.16b}, [x13]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_128_rk
    add x13, x13, #160
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_128_rk
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_enc_fips197_256
    bl print_str
    ldr x13, =fips197_256_pt
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_256_rk
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    ld1 {v1.16b}, [x13], #16
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_dec_fips197_256
    bl print_str
    ldr x13, =fips197_256_ct
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_256_rk
    add x13, x13, #224
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    ldr x13, =zero16
    ld1 {v1.16b}, [x13]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_256_rk
    add x13, x13, #224
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_256_rk
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_enc_fips197_192
    bl print_str
    ldr x13, =fips197_192_pt
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_192_rk
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    ld1 {v1.16b}, [x13], #16
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_dec_fips197_192
    bl print_str
    ldr x13, =fips197_192_ct
    ld1 {v0.16b}, [x13]
    ldr x13, =fips197_192_rk
    add x13, x13, #192
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    ldr x13, =zero16
    ld1 {v1.16b}, [x13]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_192_rk
    add x13, x13, #192
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    ldr x13, =fips197_192_rk
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_enc_post_kat_128
    bl print_str
    ldr x13, =post_kat_128_pt
    ld1 {v0.16b}, [x13]
    ldr x13, =post_kat_128_rk
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    aesmc v0.16b, v0.16b
    ld1 {v1.16b}, [x13], #16
    aese v0.16b, v1.16b
    ld1 {v1.16b}, [x13], #16
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex

    ldr x21, =name_dec_post_kat_128
    bl print_str
    ldr x13, =post_kat_128_ct
    ld1 {v0.16b}, [x13]
    ldr x13, =post_kat_128_rk
    add x13, x13, #160
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    ldr x13, =zero16
    ld1 {v1.16b}, [x13]
    aesd v0.16b, v1.16b
    ldr x13, =post_kat_128_rk
    add x13, x13, #160
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    sub x13, x13, #16
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    aesimc v0.16b, v0.16b
    ldr x14, =zero16
    ld1 {v1.16b}, [x14]
    aesd v0.16b, v1.16b
    ldr x13, =post_kat_128_rk
    ld1 {v1.16b}, [x13]
    eor v0.16b, v0.16b, v1.16b
    bl print_v0_hex
#ifdef ENGINE
    mov x0, #0
    svc #10
#else
    mov x8, #93
    mov x0, #0
    svc #0
#endif
    b .

// print_str: NUL-terminated string at x21; clobbers x22
print_str:
    stp x29, x30, [sp, #-16]!
    mov x22, x21
1:  ldrb w0, [x22], #1
    cbz w0, 2f
    bl putc
    b 1b
2:  ldp x29, x30, [sp], #16
    ret

// print_v0_hex: print v0 as 16 hex bytes (memory order) + newline; clobbers x22-x26, v0 preserved via stack
print_v0_hex:
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #16
    str q0, [sp]
    mov x22, sp
    mov x25, #0
3:  ldrb w0, [x22, x25]
    lsr w26, w0, #4
    and w0, w0, #0xF
    mov w0, w0
    // hi nibble
    mov w23, w26
    cmp w23, #10
    b.lt 4f
    add w23, w23, #87
    b 5f
4:  add w23, w23, #48
5:  mov w0, w23
    bl putc
    // lo nibble (recompute)
    ldrb w0, [x22, x25]
    and w0, w0, #0xF
    cmp w0, #10
    b.lt 6f
    add w0, w0, #87
    b 7f
6:  add w0, w0, #48
7:  bl putc
    add x25, x25, #1
    cmp x25, #16
    b.lt 3b
    mov w0, #0x0A
    bl putc
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    ret

putc:
#ifdef ENGINE
    str w0, [x12]
    ret
#else
    stp x29, x30, [sp, #-48]!
    str x22, [sp, #16]
    str x23, [sp, #24]
    ldr x22, =linebuf
    ldr x23, =linelen
    ldr x24, [x23]
    strb w0, [x22, x24]
    add x24, x24, #1
    str x24, [x23]
    cmp w0, #0x0A
    b.ne 3f
    mov x8, #64
    mov x0, #1
    mov x1, x22
    mov x2, x24
    svc #0
    str xzr, [x23]
3:  ldr x22, [sp, #16]
    ldr x23, [sp, #24]
    ldp x29, x30, [sp], #48
    ret
#endif

    .section .rodata
name_aese0: .asciz "AESE 0: "
name_aesd0: .asciz "AESD 0: "
name_aesmc0: .asciz "AESMC 0: "
name_aesimc0: .asciz "AESIMC 0: "
name_sha2560: .asciz "SHA256 0: "
name_sha5120: .asciz "SHA512 0: "
name_pmull0: .asciz "PMULL 0: "
name_aese1: .asciz "AESE 1: "
name_aesd1: .asciz "AESD 1: "
name_aesmc1: .asciz "AESMC 1: "
name_aesimc1: .asciz "AESIMC 1: "
name_sha2561: .asciz "SHA256 1: "
name_sha5121: .asciz "SHA512 1: "
name_pmull1: .asciz "PMULL 1: "
name_aese2: .asciz "AESE 2: "
name_aesd2: .asciz "AESD 2: "
name_aesmc2: .asciz "AESMC 2: "
name_aesimc2: .asciz "AESIMC 2: "
name_sha2562: .asciz "SHA256 2: "
name_sha5122: .asciz "SHA512 2: "
name_pmull2: .asciz "PMULL 2: "
name_aese3: .asciz "AESE 3: "
name_aesd3: .asciz "AESD 3: "
name_aesmc3: .asciz "AESMC 3: "
name_aesimc3: .asciz "AESIMC 3: "
name_sha2563: .asciz "SHA256 3: "
name_sha5123: .asciz "SHA512 3: "
name_pmull3: .asciz "PMULL 3: "
name_aese4: .asciz "AESE 4: "
name_aesd4: .asciz "AESD 4: "
name_aesmc4: .asciz "AESMC 4: "
name_aesimc4: .asciz "AESIMC 4: "
name_sha2564: .asciz "SHA256 4: "
name_sha5124: .asciz "SHA512 4: "
name_pmull4: .asciz "PMULL 4: "
name_aese5: .asciz "AESE 5: "
name_aesd5: .asciz "AESD 5: "
name_aesmc5: .asciz "AESMC 5: "
name_aesimc5: .asciz "AESIMC 5: "
name_sha2565: .asciz "SHA256 5: "
name_sha5125: .asciz "SHA512 5: "
name_pmull5: .asciz "PMULL 5: "
name_enc_fips197_128: .asciz "ENC fips197_128: "
name_dec_fips197_128: .asciz "DEC fips197_128: "
name_enc_fips197_256: .asciz "ENC fips197_256: "
name_dec_fips197_256: .asciz "DEC fips197_256: "
name_enc_fips197_192: .asciz "ENC fips197_192: "
name_dec_fips197_192: .asciz "DEC fips197_192: "
name_enc_post_kat_128: .asciz "ENC post_kat_128: "
name_dec_post_kat_128: .asciz "DEC post_kat_128: "
pair0a: .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pair0b: .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pair1a: .byte 255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
pair1b: .byte 255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
pair2a: .byte 230,128,116,127,20,232,166,238,0,187,166,189,101,87,174,81
pair2b: .byte 127,234,150,249,15,186,225,42,133,127,92,151,224,203,165,121
pair3a: .byte 0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255
pair3b: .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
pair4a: .byte 1,35,69,103,137,171,205,239,254,220,186,152,118,84,50,16
pair4b: .byte 15,30,45,60,75,90,105,120,135,150,165,180,195,210,225,240
pair5a: .byte 165,165,165,165,165,165,165,165,90,90,90,90,90,90,90,90
pair5b: .byte 61,48,230,54,69,133,70,22,113,170,103,16,38,178,236,217
fips197_128_pt: .byte 0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255
fips197_128_ct: .byte 105,196,224,216,106,123,4,48,216,205,183,128,112,180,197,90
fips197_128_rk:
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte 214,170,116,253,210,175,114,250,218,166,120,241,214,171,118,254
    .byte 182,146,207,11,100,61,189,241,190,155,197,0,104,48,179,254
    .byte 182,255,116,78,210,194,201,191,108,89,12,191,4,105,191,65
    .byte 71,247,247,188,149,53,62,3,249,108,50,188,253,5,141,253
    .byte 60,170,163,232,169,159,157,235,80,243,175,87,173,246,34,170
    .byte 94,57,15,125,247,166,146,150,167,85,61,193,10,163,31,107
    .byte 20,249,112,26,227,95,226,140,68,10,223,77,78,169,192,38
    .byte 71,67,135,53,164,28,101,185,224,22,186,244,174,191,122,210
    .byte 84,153,50,209,240,133,87,104,16,147,237,156,190,44,151,78
    .byte 19,17,29,127,227,148,74,23,243,7,167,139,77,43,48,197
fips197_256_pt: .byte 0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255
fips197_256_ct: .byte 142,162,183,202,81,103,69,191,234,252,73,144,75,73,96,137
fips197_256_rk:
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    .byte 165,115,194,159,161,118,196,152,169,127,206,147,165,114,192,156
    .byte 22,81,168,205,2,68,190,218,26,93,164,193,6,64,186,222
    .byte 174,135,223,240,15,241,27,104,166,142,213,251,3,252,21,103
    .byte 109,225,241,72,111,165,79,146,117,248,235,83,115,184,81,141
    .byte 198,86,130,127,201,167,153,23,111,41,76,236,108,213,89,139
    .byte 61,226,58,117,82,71,117,231,39,191,158,180,84,7,207,57
    .byte 11,220,144,95,194,123,9,72,173,82,69,164,193,135,28,47
    .byte 69,245,166,96,23,178,211,135,48,13,77,51,100,10,130,10
    .byte 124,207,247,28,190,180,254,84,19,230,187,240,210,97,167,223
    .byte 240,26,250,254,231,168,41,121,215,165,100,74,179,175,230,64
    .byte 37,65,254,113,155,245,0,37,136,19,187,213,90,114,28,10
    .byte 78,90,102,153,169,242,79,224,126,87,43,170,205,248,205,234
    .byte 36,252,121,204,191,9,121,233,55,26,194,60,109,104,222,54
fips197_192_pt: .byte 0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255
fips197_192_ct: .byte 221,169,124,164,134,76,223,224,110,175,112,160,236,13,113,145
fips197_192_rk:
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte 16,17,18,19,20,21,22,23,88,70,242,249,92,67,244,254
    .byte 84,74,254,245,88,71,240,250,72,86,226,233,92,67,244,254
    .byte 64,249,73,179,28,186,189,77,72,240,67,184,16,183,179,66
    .byte 88,225,81,171,4,162,165,85,126,255,181,65,98,69,8,12
    .byte 42,181,75,180,58,2,248,246,98,227,169,93,102,65,12,8
    .byte 245,1,133,114,151,68,141,126,189,241,198,202,135,243,62,60
    .byte 229,16,151,97,131,81,155,105,52,21,124,158,163,81,241,224
    .byte 30,160,55,42,153,83,9,22,124,67,158,119,255,18,5,30
    .byte 221,126,14,136,126,47,255,104,96,143,200,66,249,220,193,84
    .byte 133,159,95,35,122,141,90,61,192,192,41,82,190,239,214,58
    .byte 222,96,30,120,39,188,223,44,162,35,128,15,216,174,218,50
    .byte 164,151,10,51,26,120,220,9,196,24,194,113,227,164,29,93
post_kat_128_pt: .byte 127,234,150,249,15,186,225,42,133,127,92,151,224,203,165,121
post_kat_128_ct: .byte 61,48,230,54,69,133,70,22,113,170,103,16,38,178,236,217
post_kat_128_rk:
    .byte 230,128,116,127,20,232,166,238,0,187,166,189,101,87,174,81
    .byte 188,100,165,50,168,140,3,220,168,55,165,97,205,96,11,48
    .byte 110,79,161,143,198,195,162,83,110,244,7,50,163,148,12,2
    .byte 72,177,214,133,142,114,116,214,224,134,115,228,67,18,127,230
    .byte 137,99,88,159,7,17,44,73,231,151,95,173,164,133,32,75
    .byte 14,212,235,214,9,197,199,159,238,82,152,50,74,215,184,121
    .byte 32,184,93,0,41,125,154,159,199,47,2,173,141,248,186,212
    .byte 33,76,21,93,8,49,143,194,207,30,141,111,66,230,55,187
    .byte 47,214,255,113,39,231,112,179,232,249,253,220,170,31,202,103
    .byte 244,162,122,221,211,69,10,110,59,188,247,178,145,163,61,213
    .byte 200,133,121,92,27,192,115,50,32,124,132,128,177,223,185,85

zero16: .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .bss
linebuf: .skip 4096
linelen: .skip 8
