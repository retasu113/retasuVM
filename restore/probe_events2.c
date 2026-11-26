// Probe2: subscribe to events AND poll libusb_get_device_list from main.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libirecovery.h>
#include "virtio_usb.h"

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
extern ssize_t libusb_get_device_list(libusb_context*, libusb_device***);
extern void libusb_free_device_list(libusb_device**, int);

static void cb(const irecv_device_event_t* ev, void* u) {
    printf("EVENT type=%d mode=%d ecid=%016lx\n", ev->type, ev->mode,
           ev->device_info ? (unsigned long)ev->device_info->ecid : 0UL);
    fflush(stdout);
}
int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: probe_events2 <sock>\n"); return 1; }
    if (hv_vusb_client_connect(argv[1]) < 0) { fprintf(stderr, "connect failed\n"); return 1; }
    irecv_device_event_context_t ctx = NULL;
    irecv_error_t e = irecv_device_event_subscribe(&ctx, cb, NULL);
    printf("subscribe -> %d\n", e); fflush(stdout);
    for (int i = 0; i < 15; i++) {
        libusb_device** list = NULL;
        ssize_t n = libusb_get_device_list(NULL, &list);
        printf("poll %d: %zd devices\n", i, n); fflush(stdout);
        if (list) libusb_free_device_list(list, 1);
        sleep(2);
    }
    printf("done\n");
    return 0;
}
