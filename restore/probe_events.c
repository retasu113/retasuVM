// Probe: subscribe to libirecovery device events and print them.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libirecovery.h>
#include "virtio_usb.h"
extern void hv_libusb_shim_attach(HvVirtioUsb*);

static void cb(const irecv_device_event_t* ev, void* u) {
    printf("EVENT type=%d mode=%d ecid=%016lx\n", ev->type, ev->mode,
           ev->device_info ? (unsigned long)ev->device_info->ecid : 0UL);
    fflush(stdout);
}
int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: probe_events <sock>\n"); return 1; }
    HvVirtioUsb* u = hv_vusb_client_connect(argv[1]); if (!u) { fprintf(stderr, "connect failed\n"); return 1; } hv_libusb_shim_attach(u);
    irecv_device_event_context_t ctx = NULL;
    irecv_error_t e = irecv_device_event_subscribe(&ctx, cb, NULL);
    printf("subscribe -> %d\n", e); fflush(stdout);
    for (int i = 0; i < 30; i++) { sleep(2); printf("."); fflush(stdout); }
    printf("\ndone\n");
    return 0;
}
