/* Bridge smoke test: Henge's usb probe flow (online -> reset -> descriptor)
   against the emulator harness over the vusb socket. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "usb_host.h"

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/retasuvm_vusb.sock";
    HvVirtioUsb *d = hv_vusb_client_connect(path);
    if (!d) {
        fprintf(stderr, "probe: cannot connect to %s\n", path);
        return 1;
    }
    int64_t s = hv_usb_wait_online(d, 120000);
    fprintf(stderr, "probe: online (session %lld)\n", (long long)s);
    if (s < 0) return 1;
    usleep(200000);
    fprintf(stderr, "probe: reset -> %d\n", hv_usb_reset(d, 5000));
    uint8_t dd[18] = {0};
    int n = hv_usb_control(d, 0x80, 6, 0x100, 0, dd, 18, 5000);
    fprintf(stderr, "probe: device descriptor -> %d:", n);
    for (int i = 0; i < (n > 0 ? n : 0); i++) fprintf(stderr, " %02x", dd[i]);
    fprintf(stderr, "\n");
    if (n == 18) {
        fprintf(stderr, "probe: VID=%02x%02x PID=%02x%02x\n", dd[9], dd[8], dd[11], dd[10]);
        return 0;
    }
    return 2;
}
