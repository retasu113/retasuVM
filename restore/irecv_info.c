/* Validate the libusb shim + libirecovery against the emulator's DFU device:
   open it (any ECID), print the device info the ROM reports. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "libirecovery.h"
#include "usb_host.h"

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/retasuvm_vusb.sock";
    HvVirtioUsb *usb = NULL;
    for (int i = 0; i < 60 && !usb; i++) {
        usb = hv_vusb_client_connect(path);
        if (!usb) sleep(1);
    }
    if (!usb) {
        fprintf(stderr, "irecv-info: cannot connect to %s\n", path);
        return 1;
    }
    hv_libusb_shim_attach(usb);
    irecv_client_t client = NULL;
    irecv_error_t err = irecv_open_with_ecid_and_attempts(&client, 0, 30);
    if (err != IRECV_E_SUCCESS || !client) {
        fprintf(stderr, "irecv-info: open failed: %d\n", err);
        return 2;
    }
    const struct irecv_device_info *info = irecv_get_device_info(client);
    if (info) {
        fprintf(stderr, "irecv-info: CPID=%04x CPRV=%02x CPFM=%02x SCEP=%02x BDID=%02x ECID=%016llx IBFL=%02x\n",
                info->cpid, info->cprv, info->cpfm, info->scep, info->bdid,
                (unsigned long long)info->ecid, info->ibfl);
        fprintf(stderr, "irecv-info: SRNM=[%s] SRTG=[%s]\n", info->srnm ? info->srnm : "", info->srtg ? info->srtg : "");
    }
    int mode = 0;
    irecv_get_mode(client, &mode);
    fprintf(stderr, "irecv-info: mode=%d (0=DFU)\n", mode);
    irecv_close(client);
    return info ? 0 : 3;
}
