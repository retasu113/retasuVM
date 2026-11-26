// Mac プラットフォーム統合テストカーネル。
// XNU の入口規約（EL1 / MMU 無効 / X0 = ADT）で起動し、ADT の解析、
// AIC のソフトウェア割り込み、ジェネリックタイマ FIQ、NVMe の
// Identify / IO キュー作成 / 読み書き / Flush を検証する。
#include <stdint.h>
#include <stddef.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

void halt_with_code(u64 code);

static u64 uart_base = 0x09000000;
static u64 aic_base = 0x0B000000;
static u64 nvme_base = 0x0C000000;

static void uart_putc(char c) { *(volatile u32 *)(uart_base) = (u32)c; }
static void puts_(const char *s) { while (*s) uart_putc(*s++); }
static void fail(const char *stage) {
    puts_("MACBOOT NG: ");
    puts_(stage);
    puts_("\n");
    halt_with_code(1);
    for (;;) {}
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
static int str_contains(const char *hay, const char *needle) {
    for (const char *h = hay; *h; h++) {
        const char *p = h, *n = needle;
        while (*n && *p == *n) { p++; n++; }
        if (!*n) return 1;
    }
    return 0;
}

// MARK: - ADT パーサ

static u32 rd32(const u8 *p) { return p[0] | p[1] << 8 | p[2] << 16 | (u32)p[3] << 24; }
static u64 rd64(const u8 *p) { return (u64)rd32(p) | (u64)rd32(p + 4) << 32; }

static const u8 *adt_prop(const u8 *node, const char *name, u32 *size_out) {
    u32 nprops = rd32(node);
    const u8 *p = node + 8;
    for (u32 i = 0; i < nprops; i++) {
        u32 size = rd32(p + 32) & 0x7FFFFFFF;
        // 名前は 32 バイト固定長（NUL パディング）
        int match = 1;
        for (int j = 0; j < 32; j++) {
            char c = name[j];
            if (p[j] != (u8)c) { match = 0; break; }
            if (c == 0) break;
        }
        if (match) {
            if (size_out) *size_out = size;
            return p + 36;
        }
        p += 36 + ((size + 3) & ~3u);
    }
    return NULL;
}

static u64 adt_node_size(const u8 *node) {
    u32 nprops = rd32(node), nchildren = rd32(node + 4);
    const u8 *p = node + 8;
    for (u32 i = 0; i < nprops; i++) {
        u32 size = rd32(p + 32) & 0x7FFFFFFF;
        p += 36 + ((size + 3) & ~3u);
    }
    for (u32 i = 0; i < nchildren; i++) p += adt_node_size(p);
    return (u64)(p - node);
}

static const u8 *adt_child_at(const u8 *node, u32 index) {
    u32 nprops = rd32(node), nchildren = rd32(node + 4);
    if (index >= nchildren) return NULL;
    const u8 *p = node + 8;
    for (u32 i = 0; i < nprops; i++) {
        u32 size = rd32(p + 32) & 0x7FFFFFFF;
        p += 36 + ((size + 3) & ~3u);
    }
    for (u32 i = 0; i < index; i++) p += adt_node_size(p);
    return p;
}

static const u8 *adt_find_child(const u8 *node, const char *name) {
    u32 nchildren = rd32(node + 4);
    for (u32 i = 0; i < nchildren; i++) {
        const u8 *child = adt_child_at(node, i);
        u32 size = 0;
        const u8 *name_prop = adt_prop(child, "name", &size);
        if (name_prop && streq((const char *)name_prop, name)) return child;
    }
    return NULL;
}

// MARK: - FIQ ハンドラ

static volatile int timer_fired = 0;
static volatile int aic_event_num = -1;

void fiq_handler(void) {
    u64 ctl;
    __asm__ volatile("mrs %0, cntp_ctl_el0" : "=r"(ctl));
    if (ctl & 0x4) {  // ISTATUS: タイマ期限切れ
        __asm__ volatile("msr cntp_ctl_el0, %0" :: "r"((u64)0));
        timer_fired = 1;
        return;
    }
    u32 event = *(volatile u32 *)(aic_base + 0x2004);
    u32 type = (event >> 16) & 0xFF;
    if (type == 1) aic_event_num = (int)(event & 0xFFFF);
}

// MARK: - NVMe

static u8 admin_sq[16 * 64] __attribute__((aligned(4096)));
static u8 admin_cq[16 * 16] __attribute__((aligned(4096)));
static u8 io_sq[16 * 64] __attribute__((aligned(4096)));
static u8 io_cq[16 * 16] __attribute__((aligned(4096)));
static u8 id_buf[4096] __attribute__((aligned(4096)));
static u8 wr_buf[4096] __attribute__((aligned(4096)));
static u8 rd_buf[4096] __attribute__((aligned(4096)));

static volatile u32 *nvreg(u64 offset) { return (volatile u32 *)(nvme_base + offset); }
static volatile u64 *nvreg64(u64 offset) { return (volatile u64 *)(nvme_base + offset); }

static void cmd_set(u8 *entry, u32 dw_index, u32 value) {
    entry[dw_index * 4 + 0] = value & 0xFF;
    entry[dw_index * 4 + 1] = (value >> 8) & 0xFF;
    entry[dw_index * 4 + 2] = (value >> 16) & 0xFF;
    entry[dw_index * 4 + 3] = (value >> 24) & 0xFF;
}
static void cmd_zero(u8 *entry) { for (int i = 0; i < 64; i++) entry[i] = 0; }
static void cmd_prp1(u8 *entry, u64 address) {
    cmd_set(entry, 6, (u32)address);
    cmd_set(entry, 7, (u32)(address >> 32));
}

// 管理コマンドを slot 番目の位置へ投稿し、完了（フェーズ 1）を待つ。ステータスを返す。
static int admin_submit(int slot) {
    *nvreg(0x1000) = (u32)(slot + 1);  // SQ0 テールドアベル
    volatile u32 *cq_entry = (volatile u32 *)(admin_cq + slot * 16);
    for (u64 spin = 0; spin < 100000000; spin++) {
        u32 dw3 = cq_entry[3];
        if ((dw3 >> 16) & 1) return (int)((dw3 >> 17) & 0x7FFF);
    }
    return -1;
}

static int io_wait(int slot) {
    volatile u32 *cq_entry = (volatile u32 *)(io_cq + slot * 16);
    for (u64 spin = 0; spin < 100000000; spin++) {
        u32 dw3 = cq_entry[3];
        if ((dw3 >> 16) & 1) return (int)((dw3 >> 17) & 0x7FFF);
    }
    return -1;
}

// MARK: - メイン

void kernel_main(u64 adt_address) {
    const u8 *root = (const u8 *)adt_address;
    u32 size = 0;
    const u8 *value;

    // ADT: ルートの model / name
    value = adt_prop(root, "model", &size);
    if (!value || !streq((const char *)value, "Apple Virtual Machine 1")) fail("adt-model");
    value = adt_prop(root, "name", &size);
    if (!value || !streq((const char *)value, "device-tree")) fail("adt-name");

    // ADT: /chosen の boot-args
    const u8 *chosen = adt_find_child(root, "chosen");
    if (!chosen) fail("adt-chosen");
    value = adt_prop(chosen, "boot-args", &size);
    if (!value || !str_contains((const char *)value, "-v")) fail("adt-bootargs");

    // ADT: /memory の reg（128 MiB ハーネス）
    const u8 *memory_node = adt_find_child(root, "memory");
    if (!memory_node) fail("adt-memory-node");
    value = adt_prop(memory_node, "reg", &size);
    if (!value || size != 16 || rd64(value) != 0x40000000 || rd64(value + 8) != 128ull * 1024 * 1024) fail("adt-memory");

    // ADT: /arm-io 配下から各デバイスの reg を引く
    const u8 *arm_io = adt_find_child(root, "arm-io");
    if (!arm_io) fail("adt-armio");
    const u8 *aic_node = adt_find_child(arm_io, "aic");
    if (!aic_node) fail("adt-aic-node");
    value = adt_prop(aic_node, "reg", &size);
    if (!value || rd64(value) != aic_base) fail("adt-aic-reg");
    const u8 *uart_node = adt_find_child(arm_io, "uart0");
    if (!uart_node) fail("adt-uart-node");
    value = adt_prop(uart_node, "reg", &size);
    if (!value || rd64(value) != uart_base) fail("adt-uart-reg");
    const u8 *nvme_node = adt_find_child(arm_io, "nvme");
    if (!nvme_node) fail("adt-nvme-node");
    value = adt_prop(nvme_node, "reg", &size);
    if (!value || rd64(value) != nvme_base) fail("adt-nvme-reg");
    puts_("ADT OK\n");

    // AIC: INFO とソフトウェア割り込み
    u32 info = *(volatile u32 *)(aic_base + 0x0004);
    if ((info & 0xFFFF) != 256) fail("aic-info");
    *(volatile u32 *)(aic_base + 0x3000 + 5 * 4) = 1;       // IRQ5 の対象 = CPU0
    *(volatile u32 *)(aic_base + 0x4180) = 1 << 5;          // IRQ5 マスク解除（MASK_CLR バンク 0）
    *(volatile u32 *)(aic_base + 0x4000) = 1 << 5;          // IRQ5 ソフトウェア生成（SW_SET）
    for (u64 spin = 0; spin < 100000000 && aic_event_num != 5; spin++) {}
    if (aic_event_num != 5) fail("aic-event");
    puts_("AIC OK\n");

    // ジェネリックタイマ FIQ
    u64 frequency;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
    __asm__ volatile("msr cntp_tval_el0, %0" :: "r"(frequency / 10));
    __asm__ volatile("msr cntp_ctl_el0, %0" :: "r"((u64)1));
    for (u64 spin = 0; spin < 500000000 && !timer_fired; spin++) {}
    if (!timer_fired) fail("timer");
    puts_("TIMER OK\n");

    // NVMe: 初期化
    u64 cap = *nvreg64(0x00);
    if ((cap & 0xFFFF) != 0x3FF || ((cap >> 37) & 0x7F) != 1) fail("nvme-cap");
    *nvreg(0x24) = (15 << 16) | 15;                        // AQA: 16 エントリずつ
    *nvreg64(0x28) = (u64)(uintptr_t)admin_sq;             // ASQ
    *nvreg64(0x30) = (u64)(uintptr_t)admin_cq;             // ACQ
    *nvreg(0x14) = 1 | (6 << 16) | (6 << 20);              // CC: EN + IOSQES/IOCQES = 64B/16B
    int ready = 0;
    for (u64 spin = 0; spin < 100000000; spin++) {
        if (*nvreg(0x1C) & 1) { ready = 1; break; }
    }
    if (!ready) fail("nvme-ready");

    // Identify Controller
    u8 *cmd = admin_sq;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x06 | (1 << 16));
    cmd_prp1(cmd, (u64)(uintptr_t)id_buf);
    cmd_set(cmd, 10, 1);                                   // CNS = 1
    if (admin_submit(0) != 0) fail("nvme-identify-status");
    if (!str_contains((const char *)id_buf + 24, "retasuVM NVMe")) fail("nvme-identify-model");
    puts_("NVME IDENT OK\n");

    // Create I/O Completion Queue（QID 1、16 エントリ、割り込みなし）
    cmd = admin_sq + 64;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x05 | (2 << 16));
    cmd_prp1(cmd, (u64)(uintptr_t)io_cq);
    cmd_set(cmd, 10, (1 << 16) | 15);
    cmd_set(cmd, 11, 1);                                   // PC = 1
    if (admin_submit(1) != 0) fail("nvme-create-cq");

    // Create I/O Submission Queue（QID 1、16 エントリ、C QID 1）
    cmd = admin_sq + 128;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x01 | (3 << 16));
    cmd_prp1(cmd, (u64)(uintptr_t)io_sq);
    cmd_set(cmd, 10, (1 << 16) | 15);
    cmd_set(cmd, 11, (1 << 16) | 1);                       // CQID = 1, PC = 1
    if (admin_submit(2) != 0) fail("nvme-create-sq");

    // Write（LBA 16 へ 8 セクタ）
    for (int i = 0; i < 4096; i++) wr_buf[i] = (u8)(i * 7 + 3);
    cmd = io_sq;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x01 | (7 << 16));
    cmd_prp1(cmd, (u64)(uintptr_t)wr_buf);
    cmd_set(cmd, 10, 16);
    cmd_set(cmd, 12, 7);
    *nvreg(0x1008) = 1;                                    // SQ1 テールドアベル
    if (io_wait(0) != 0) fail("nvme-write");

    // Read（同じ範囲を読み戻して比較）
    for (int i = 0; i < 4096; i++) rd_buf[i] = 0;
    cmd = io_sq + 64;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x02 | (8 << 16));
    cmd_prp1(cmd, (u64)(uintptr_t)rd_buf);
    cmd_set(cmd, 10, 16);
    cmd_set(cmd, 12, 7);
    *nvreg(0x1008) = 2;
    if (io_wait(1) != 0) fail("nvme-read-status");
    for (int i = 0; i < 4096; i++) {
        if (rd_buf[i] != wr_buf[i]) fail("nvme-read-data");
    }

    // Flush
    cmd = io_sq + 128;
    cmd_zero(cmd);
    cmd_set(cmd, 0, 0x00 | (9 << 16));
    *nvreg(0x1008) = 3;
    if (io_wait(2) != 0) fail("nvme-flush");
    puts_("NVME OK\n");

    puts_("ALL MACBOOT OK\n");
    halt_with_code(0);
    for (;;) {}
}
