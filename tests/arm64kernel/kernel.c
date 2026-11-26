// ARM64CPU 統合テストカーネル。
// CPU 命令、MMU（変換 / 許可 / アクセスフラグ）、例外（SVC / BRK）、
// タイマ割り込み（GIC ライト経由）、アトミック、EL0 実行を検証する。
#include <stdint.h>
#include <stddef.h>

#define UART_DR   (*(volatile uint32_t *)0x09000000)
#define CONTROL   (*(volatile uint32_t *)0x0A000000)
#define GICD_CTLR (*(volatile uint32_t *)0x08000000)
#define GICD_ISEN (*(volatile uint32_t *)0x08000100)
#define GICC_CTLR (*(volatile uint32_t *)0x08010000)
#define GICC_PMR  (*(volatile uint32_t *)0x08010004)
#define GICC_EOIR (*(volatile uint32_t *)0x08010010)

extern uint64_t esr_saved, far_saved, elr_saved, spsr_saved;
extern uint32_t iar_saved;
extern char vectors[];
extern void drop_to_el0(uint64_t pc, uint64_t sp, uint64_t spsr);
extern char user_code[], user_recovery[], user_done[];
static uint64_t pair_buf[8];

static void putc(char c) { UART_DR = (uint32_t)c; }
static void puts(const char *s) { while (*s) putc(*s++); }
static void puthex(uint64_t v) {
    puts("0x");
    for (int i = 60; i >= 0; i -= 4) {
        int d = (int)((v >> i) & 0xF);
        putc(d < 10 ? (char)('0' + d) : (char)('a' + d - 10));
    }
}

static int failures = 0;
static void check(int cond, const char *name) {
    puts("A64T ");
    puts(name);
    puts(cond ? " OK\n" : " NG\n");
    if (!cond) failures++;
}

#define MRS(reg) ({ uint64_t v; __asm__ volatile("mrs %0, " #reg : "=r"(v)); v; })
#define MSR(reg, val) __asm__ volatile("msr " #reg ", %0" :: "r"((uint64_t)(val)))

// ---- 例外ハンドラ側の記録 ----
static volatile uint64_t svc_iss = 0xFFFFFFFF;
static volatile int svc_from_lower = 0;
static volatile uint64_t abort_ec = 0, abort_fsc = 0, abort_far = 0;
static volatile int perm_fixed = 0, af_fixed = 0, trans_skipped = 0;
static volatile int el0_svc1 = 0, el0_svc2 = 0;
static volatile int brk_seen = 0;
static volatile int timer_flag = 0;

// ページテーブル（4KB グラニュール、48 ビット VA、4 段）
static uint64_t l0_table[512] __attribute__((aligned(4096)));
static uint64_t l1_table[512] __attribute__((aligned(4096)));
static uint64_t l2_low[512] __attribute__((aligned(4096)));
static uint64_t l2_ram[512] __attribute__((aligned(4096)));
static uint64_t l3_test[512] __attribute__((aligned(4096)));
static uint8_t scratch_page[4096] __attribute__((aligned(4096)));

#define DESC_TABLE 0x3ULL
#define DESC_BLOCK 0x1ULL
#define DESC_PAGE  0x3ULL
#define DESC_AF    (1ULL << 10)
#define DESC_AP_RW_EL1 (0ULL << 6)
#define DESC_AP_RW_ALL (1ULL << 6)
#define DESC_AP_RO_ALL (3ULL << 6)
#define ATTR_NORMAL (0ULL << 2)
#define ATTR_DEVICE (1ULL << 2)

void handle_sync(void) {
    uint64_t esr = esr_saved;
    uint64_t ec = (esr >> 26) & 0x3F;
    uint64_t iss = esr & 0x1FFFFFF;
    int from_lower = (spsr_saved & 0xF) == 0;  // SPSR.M == EL0t
    if (ec == 0x15) {  // SVC
        svc_iss = iss;
        svc_from_lower = from_lower;
        if (iss == 0x77 && from_lower) {
            el0_svc1 = 1;
            elr_saved = (uint64_t)user_recovery;
        } else if (iss == 0x78 && from_lower) {
            el0_svc2 = 1;
            elr_saved = (uint64_t)user_done;
        } else if (iss == 0x79 && from_lower) {
            // EL0 テストの完了処理（EL1 のハンドラ側で結果を出して終了する）
            check(el0_svc1 == 1 && el0_svc2 == 1, "el0");
            puts(failures == 0 ? "ALL ARM64 OK\n" : "ARM64 NG\n");
            CONTROL = failures == 0 ? 0 : 3;
            while (1) { }
        }
        return;
    }
    if (ec == 0x3C) {  // BRK
        brk_seen = 1;
        elr_saved += 4;
        return;
    }
    if (ec == 0x24 || ec == 0x25) {  // データアボート
        uint64_t fsc = esr & 0x3F;
        abort_ec = ec;
        abort_fsc = fsc;
        abort_far = far_saved;
        if ((fsc & 0x3C) == 0x0C) {
            // 許可フォールト: RO ページを RW にして再実行させる
            l3_test[1] = ((uint64_t)scratch_page & ~0xFFFULL) | DESC_PAGE | DESC_AF | DESC_AP_RW_ALL | ATTR_NORMAL;
            perm_fixed = 1;
        } else if ((fsc & 0x3C) == 0x08) {
            // アクセスフラグフォールト: AF を立てて再実行させる
            l3_test[2] |= DESC_AF;
            af_fixed = 1;
        } else if ((fsc & 0x3C) == 0x04) {
            // 変換フォールト: 命令をスキップする
            trans_skipped = 1;
            elr_saved += 4;
        }
        return;
    }
    // 想定外の例外は失敗として停止
    puts("A64T unexpected exception ec=");
    puthex(ec);
    puts(" esr=");
    puthex(esr);
    puts(" elr=");
    puthex(elr_saved);
    puts(" far=");
    puthex(far_saved);
    puts("\n");
    CONTROL = 97;
    while (1) { }
}

void handle_irq(void) {
    uint32_t iar = iar_saved;
    if (iar == 30) {
        timer_flag = 1;
        MSR(cntp_ctl_el0, 0);
    }
    GICC_EOIR = iar;
}

static void setup_vectors(void) {
    MSR(vbar_el1, (uint64_t)vectors);
}

// ---- メインテスト ----
void kernel_main(void) {
    puts("A64 BOOT\n");
    setup_vectors();

    // 1. 算術とフラグ
    {
        uint64_t r;
        __asm__ volatile("mov x0, #0xFFFFFFFFFFFFFFFF\n\t"
                         "add x0, x0, #2\n\t"
                         "mov %0, x0" : "=r"(r));
        check(r == 1, "arith-wrap");
        __asm__ volatile("mov x0, #17\n\t"
                         "mov x1, #5\n\t"
                         "udiv x2, x0, x1\n\t"
                         "mov %0, x2" : "=r"(r));
        check(r == 3, "udiv");
        __asm__ volatile("mov x0, #-100\n\t"
                         "mov x1, #7\n\t"
                         "sdiv x2, x0, x1\n\t"
                         "mov %0, x2" : "=r"(r));
        check((int64_t)r == -14, "sdiv");
        __asm__ volatile("mov x0, #0\n\t"
                         "mov x1, #0\n\t"
                         "udiv x2, x0, x1\n\t"
                         "mov %0, x2" : "=r"(r));
        check(r == 0, "div-zero");
        __asm__ volatile("mov x0, #0x8000000000000000\n\t"
                         "clz x1, x0\n\t"
                         "mov %0, x1" : "=r"(r));
        check(r == 0, "clz");
        __asm__ volatile("ldr x0, =0x0123456789ABCDEF\n\t"
                         "rev x1, x0\n\t"
                         "mov %0, x1" : "=r"(r));
        check(r == 0xEFCDAB8967452301ULL, "rev");
        __asm__ volatile("ldr x0, =0xF00000000000000F\n\t"
                         "ubfx x1, x0, #4, #8\n\t"
                         "mov %0, x1" : "=r"(r));
        check(r == 0, "ubfx");
        __asm__ volatile("mov x0, #5\n\t"
                         "mov x1, #9\n\t"
                         "cmp x0, x1\n\t"
                         "csel x2, x0, x1, lt\n\t"
                         "mov %0, x2" : "=r"(r));
        check(r == 5, "csel");
        uint64_t hi;
        __asm__ volatile("mov x0, #0xFFFFFFFFFFFFFFFF\n\t"
                         "mov x1, #2\n\t"
                         "umulh x2, x0, x1\n\t"
                         "mov %0, x2" : "=r"(hi));
        check(hi == 1, "umulh");
        __asm__ volatile("mov x0, #0x1234\n\t"
                         "movk x0, #0xABCD, lsl #16\n\t"
                         "mov %0, x0" : "=r"(r));
        check(r == 0xABCD1234ULL, "movk");
        __asm__ volatile("ldr x0, =0x0F0F0F0F0F0F0F0F\n\t"
                         "and x1, x0, #0xFF00FF00FF00FF00\n\t"
                         "mov %0, x1" : "=r"(r));
        check(r == 0x0F000F000F000F00ULL, "bitmask-imm");
    }

    // 2. ロード / ストアの形式
    {
        static uint64_t buf[8];
        uint64_t a;
        buf[0] = 0x1122334455667788ULL;
        __asm__ volatile("ldrsb %0, [%1, #1]" : "=r"(a) : "r"(buf));
        check((int64_t)a == 0x77, "ldrsb");
        uint64_t *p = buf;
        uint64_t v;
        __asm__ volatile("ldr %0, [%1], #8" : "=r"(v), "+r"(p) : : "memory");
        check(v == 0x1122334455667788ULL && p == buf + 1, "post-index");
        uint64_t newbase, pa, pb;
        __asm__ volatile("ldr x9, =pair_buf\n\t"
                         "add x9, x9, #32\n\t"
                         "mov x10, #0x1111\n\t"
                         "mov x11, #0x2222\n\t"
                         "stp x10, x11, [x9, #-16]!\n\t"
                         "mov %0, x9\n\t"
                         "ldp x12, x13, [x9], #16\n\t"
                         "mov %1, x12\n\t"
                         "mov %2, x13" : "=r"(newbase), "=r"(pa), "=r"(pb) :: "memory", "x9", "x10", "x11", "x12", "x13");
        check(newbase == (uint64_t)(pair_buf + 2) && pa == 0x1111 && pb == 0x2222
              && pair_buf[2] == 0x1111 && pair_buf[3] == 0x2222, "stp-ldp");
    }

    // 3. アトミック
    {
        static volatile uint64_t counter = 100;
        uint64_t old;
        __asm__ volatile("ldadd %1, %0, [%2]" : "=r"(old) : "r"(7ULL), "r"(&counter) : "memory");
        check(old == 100 && counter == 107, "ldadd");
        __asm__ volatile("swp %1, %0, [%2]" : "=r"(old) : "r"(55ULL), "r"(&counter) : "memory");
        check(old == 107 && counter == 55, "swp");
        counter = 55;
        uint64_t expected = 55, desired = 77;
        __asm__ volatile("cas %0, %1, [%2]" : "+r"(expected) : "r"(desired), "r"(&counter) : "memory");
        check(expected == 55 && counter == 77, "cas-ok");
        expected = 55;
        __asm__ volatile("cas %0, %1, [%2]" : "+r"(expected) : "r"(desired), "r"(&counter) : "memory");
        check(expected == 77 && counter == 77, "cas-fail");
        uint64_t status;
        counter = 1;
        __asm__ volatile("1: ldxr %0, [%2]\n\t"
                         "add %0, %0, #1\n\t"
                         "stxr %w1, %0, [%2]\n\t"
                         "cbnz %w1, 1b" : "=&r"(old), "=&r"(status) : "r"(&counter) : "memory");
        check(counter == 2, "ldxr-stxr");
    }

    // 4. SVC / BRK 例外（MMU オフ）
    {
        __asm__ volatile("svc #0x42");
        check(svc_iss == 0x42 && !svc_from_lower, "svc");
        __asm__ volatile("brk #7");
        check(brk_seen == 1, "brk");
    }

    // 5. タイマ割り込み
    {
        GICD_CTLR = 1;
        GICD_ISEN = (1u << 30);
        GICC_CTLR = 1;
        GICC_PMR = 0xFF;
        MSR(cntp_ctl_el0, 0);
        __asm__ volatile("msr daifclr, #2");
        uint64_t freq = MRS(cntfrq_el0);
        MSR(cntp_tval_el0, (uint32_t)(freq / 20));   // 50ms
        MSR(cntp_ctl_el0, 1);
        uint64_t spins = 0;
        while (!timer_flag && spins < 50000000) { spins++; }
        check(timer_flag == 1, "timer-irq");
        __asm__ volatile("msr daifset, #2");
    }

    // 6. MMU
    {
        // テーブル構築
        l0_table[0] = (uint64_t)l1_table | DESC_TABLE;
        l1_table[0] = (uint64_t)l2_low | DESC_TABLE;
        l1_table[1] = (uint64_t)l2_ram | DESC_TABLE;
        // 低位: GIC (0x08000000) / UART (0x09000000) / 制御 (0x0A000000) を 2MB ブロックで
        l2_low[0x40] = 0x08000000ULL | DESC_BLOCK | DESC_AF | DESC_AP_RW_EL1 | ATTR_DEVICE;
        l2_low[0x48] = 0x09000000ULL | DESC_BLOCK | DESC_AF | DESC_AP_RW_EL1 | ATTR_DEVICE;
        l2_low[0x50] = 0x0A000000ULL | DESC_BLOCK | DESC_AF | DESC_AP_RW_EL1 | ATTR_DEVICE;
        // テストページ用に VA 0 を L3 へ
        l2_low[0] = (uint64_t)l3_test | DESC_TABLE;
        l3_test[1] = ((uint64_t)scratch_page & ~0xFFFULL) | DESC_PAGE | DESC_AF | DESC_AP_RO_ALL | ATTR_NORMAL;
        l3_test[2] = ((uint64_t)scratch_page & ~0xFFFULL) | DESC_PAGE | DESC_AP_RW_ALL | ATTR_NORMAL;  // AF=0
        // RAM: 2MB ブロック × 32（0x40000000〜0x44000000）
        for (int i = 0; i < 32; i++) {
            l2_ram[i] = (0x40000000ULL + (uint64_t)i * 0x200000ULL) | DESC_BLOCK | DESC_AF | DESC_AP_RW_ALL | ATTR_NORMAL;
        }
        MSR(mair_el1, 0x00FF);
        uint64_t tcr = (16ULL) | (1ULL << 8) | (1ULL << 10) | (3ULL << 12) | (16ULL << 16) | (2ULL << 32);
        MSR(tcr_el1, tcr);
        MSR(ttbr0_el1, (uint64_t)l0_table);
        __asm__ volatile("dsb sy\n\tisb");
        uint64_t sctlr = MRS(sctlr_el1);
        MSR(sctlr_el1, sctlr | 1);
        __asm__ volatile("isb");
        check((MRS(sctlr_el1) & 1) == 1, "mmu-on");
        // 恒等マップでの読み書き
        volatile uint64_t *probe = (volatile uint64_t *)0x43000000;
        *probe = 0xCAFEBABE12345678ULL;
        check(*probe == 0xCAFEBABE12345678ULL, "mmu-identity");
        // 許可フォールト → ハンドラが RW 化して再実行
        volatile uint32_t *ro = (volatile uint32_t *)0x1000;
        *ro = 0xDEADBEEF;
        check(perm_fixed == 1 && *ro == 0xDEADBEEF, "mmu-perm-fault");
        check(abort_ec == 0x25 && (abort_fsc & 0x3C) == 0x0C && abort_far == 0x1000, "mmu-perm-esr");
        // アクセスフラグフォールト
        volatile uint32_t *af = (volatile uint32_t *)0x2000;
        *af = 0x1234;
        check(af_fixed == 1 && *af == 0x1234, "mmu-af-fault");
        // 変換フォールト → ハンドラがスキップ
        volatile uint32_t *unmapped = (volatile uint32_t *)0x3000;
        uint32_t dummy = *unmapped;
        (void)dummy;
        check(trans_skipped == 1, "mmu-trans-fault");
    }

    // 7. EL0 実行
    {
        drop_to_el0((uint64_t)user_code, 0x43F00000ULL, 0);
        // drop_to_el0 は戻らない（EL0 の SVC #0x78 で CONTROL へ書いて終了）
        check(0, "el0-returned");
    }

    puts(failures == 0 ? "ALL ARM64 OK\n" : "ARM64 NG\n");
    CONTROL = failures == 0 ? 0 : 3;
    while (1) { }
}
