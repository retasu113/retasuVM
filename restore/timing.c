/* Measure vusb control-transfer round-trip latency against a harness. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "virtio_usb.h"
#include "usb_host.h"

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: timing <sock>\n"); return 1; }
    HvVirtioUsb *d = hv_vusb_client_connect(argv[1]);
    if (!d) { fprintf(stderr, "connect failed\n"); return 1; }
    int64_t s = hv_usb_wait_online(d, 120000);
    printf("online session=%lld\n", (long long)s);
    if (s < 0) return 1;
    double t0 = now_ms();
    int r = hv_usb_reset(d, 60000);
    printf("reset r=%d %.1f ms\n", r, now_ms() - t0);
    uint8_t buf[512];
    double total = 0;
    for (int i = 0; i < 30; i++) {
        double a = now_ms();
        int n = hv_usb_control(d, 0x80, 6, 0x0100, 0, buf, 18, 60000);
        double dt = now_ms() - a;
        total += dt;
        printf("desc[%d] n=%d %.1f ms\n", i, n, dt);
        fflush(stdout);
    }
    printf("avg %.1f ms\n", total / 30);
    return 0;
}
