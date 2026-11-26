/* Extended probe: config descriptor + strings, mirroring the shim's enumerate(). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "usb_host.h"

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/retasuvm_vusb.sock";
    HvVirtioUsb *d = hv_vusb_client_connect(path);
    if (!d) { fprintf(stderr, "probe2: cannot connect\n"); return 1; }
    int64_t s = hv_usb_wait_online(d, 120000);
    fprintf(stderr, "probe2: online (session %lld)\n", (long long)s);
    if (s < 0) return 1;
    usleep(200000);
    fprintf(stderr, "probe2: reset -> %d\n", hv_usb_reset(d, 5000));
    uint8_t dd[18] = {0};
    int n = hv_usb_control(d, 0x80, 6, 0x100, 0, dd, 18, 5000);
    fprintf(stderr, "probe2: device descriptor -> %d\n", n);
    if (n != 18) return 2;
    uint8_t head[9] = {0};
    n = hv_usb_control(d, 0x80, 6, 0x200, 0, head, 9, 5000);
    fprintf(stderr, "probe2: config head -> %d:", n);
    for (int i = 0; i < (n > 0 ? n : 0); i++) fprintf(stderr, " %02x", head[i]);
    fprintf(stderr, "\n");
    if (n < 4) return 3;
    uint16_t total = (uint16_t)(head[2] | head[3] << 8);
    fprintf(stderr, "probe2: config total = %u\n", total);
    uint8_t *cfg = malloc(total);
    n = hv_usb_control(d, 0x80, 6, 0x200, 0, cfg, total, 5000);
    fprintf(stderr, "probe2: config full -> %d:", n);
    for (int i = 0; i < (n > 0 ? n : 0) && i < 64; i++) fprintf(stderr, " %02x", cfg[i]);
    fprintf(stderr, "\n");
    for (int idx = 1; idx <= 4; idx++) {
        uint8_t buf[255] = {0};
        int m = hv_usb_control(d, 0x80, 6, (uint16_t)(0x300 | idx), 0x409, buf, 255, 5000);
        fprintf(stderr, "probe2: string %d -> %d:", idx, m);
        for (int i = 0; i < (m > 0 ? m : 0) && i < 60; i++) fprintf(stderr, " %02x", buf[i]);
        fprintf(stderr, "\n");
    }
    return 0;
}
