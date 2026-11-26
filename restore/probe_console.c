/* Interactive recovery-console probe: open the device in recovery mode,
   run getenv queries (command/response round trip), optionally send one raw
   command given as argv[3] (e.g. "go"). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libirecovery.h"
#include "usb_host.h"

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/retasuvm_vusb.sock";
    unsigned long long ecid = argc > 2 ? strtoull(argv[2], NULL, 0) : 0;
    const char *rawcmd = argc > 3 ? argv[3] : NULL;
    HvVirtioUsb *usb = NULL;
    for (int i = 0; i < 60 && !usb; i++) {
        usb = hv_vusb_client_connect(path);
        if (!usb) sleep(1);
    }
    if (!usb) {
        fprintf(stderr, "probe: cannot connect to %s\n", path);
        return 1;
    }
    hv_libusb_shim_attach(usb);
    irecv_client_t client = NULL;
    irecv_error_t err = irecv_open_with_ecid_and_attempts(&client, ecid, 30);
    if (err != IRECV_E_SUCCESS || !client) {
        fprintf(stderr, "probe: open failed: %d\n", err);
        return 2;
    }
    int mode = 0;
    irecv_get_mode(client, &mode);
    fprintf(stderr, "probe: mode=%d (1..4=recovery)\n", mode);

    const char *vars[] = {"auto-boot", "boot-args", "build-version", NULL};
    for (int i = 0; vars[i]; i++) {
        char *value = NULL;
        irecv_error_t e = irecv_getenv(client, vars[i], &value);
        fprintf(stderr, "probe: getenv %s -> err=%d value=[%s]\n", vars[i], e, value ? value : "(null)");
        free(value);
    }
    if (rawcmd) {
        int breq = argc > 4 ? atoi(argv[4]) : 1;
        fprintf(stderr, "probe: sending raw command [%s] breq=%d\n", rawcmd, breq);
        irecv_error_t e = irecv_send_command_breq(client, rawcmd, breq);
        fprintf(stderr, "probe: send_command -> err=%d\n", e);
        for (int i = 0; i < 10; i++) {
            sleep(3);
            unsigned char resp[256];
            memset(resp, 0, sizeof(resp));
            int n = irecv_usb_control_transfer(client, 0xC0, 0, 0, 0, resp, sizeof(resp) - 1, 5000);
            fprintf(stderr, "probe: reply read %d -> n=%d [%s]\n", i, n, resp);
        }
    }
    irecv_close(client);
    return 0;
}
