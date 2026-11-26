/* Restore driver: connect to the emulator's USB bridge and run Henge's
   install flow (in-process usbmuxd + idevicerestore) against it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "install.h"
#include "usb_host.h"

static void progress(int step, double p, void *user) {
    (void)user;
    fprintf(stderr, "restore progress: step %d %.1f%%\n", step, p * 100.0);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <vusb-socket> <ipsw> <workdir> <ecid-hex>\n", argv[0]);
        return 2;
    }
    const char *sock = argv[1];
    const char *ipsw = argv[2];
    const char *workdir = argv[3];
    uint64_t ecid = strtoull(argv[4], NULL, 0);

    HvVirtioUsb *usb = NULL;
    for (int i = 0; i < 120 && !usb; i++) {
        usb = hv_vusb_client_connect(sock);
        if (!usb) sleep(1);
    }
    if (!usb) {
        fprintf(stderr, "restore: cannot connect to %s\n", sock);
        return 1;
    }
    if (hv_install_start(usb, ipsw, workdir, ecid, progress, NULL) != 0) {
        fprintf(stderr, "restore: install_start failed\n");
        return 1;
    }
    for (;;) {
        int r = hv_install_result();
        if (r != 1) {
            fprintf(stderr, "restore: finished with %d\n", r);
            return r == 0 ? 0 : 1;
        }
        sleep(2);
    }
}
