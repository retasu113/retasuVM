#ifndef RETASUVM_VIRTIO_USB_H
#define RETASUVM_VIRTIO_USB_H

#include <pthread.h>
#include <stdint.h>

/* virtio-usb / bdif-USB message protocol (same constants and wire formats as
   Henge's devices/virtio_usb.h). The guest is the USB device; this side is
   the USB host. Requests carry a 6-byte header {u32 len, u8 ep, u8 type}
   into the guest; responses are {u8 type, u8 ep} + data. */

#define HV_VUSB_REQ_DATA 1
#define HV_VUSB_REQ_RESET 2
#define HV_VUSB_REQ_PAUSE 3

#define HV_VUSB_RSP_DATA 1
#define HV_VUSB_RSP_STALL 2
#define HV_VUSB_RSP_ABORT 3
#define HV_VUSB_RSP_RESET 4
#define HV_VUSB_RSP_PAUSED 5

#define HV_VUSB_RING 256

typedef struct HvVusbMsg {
    uint8_t type, ep;
    uint32_t len;
    uint8_t *data; /* malloc'd, len bytes; NULL for an IN request (len = capacity) */
} HvVusbMsg;

/* Socket-backed client state: connects to the emulator harness, which owns
   the actual guest. in[] holds responses waiting for the host. */
typedef struct HvVirtioUsb {
    int fd;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    pthread_mutex_t write_mu;
    HvVusbMsg in[HV_VUSB_RING];
    uint32_t in_head, in_tail;
    uint32_t session; /* bumps on every connect and disconnect */
    int online;
    int log;
} HvVirtioUsb;

/* Connect to the emulator's USB bridge socket. NULL on failure. */
HvVirtioUsb *hv_vusb_client_connect(const char *socket_path);

int hv_vusb_online(HvVirtioUsb *d, uint32_t *session);
/* Queue a request; data may be NULL. Returns 0, or -1 if offline/full. */
int hv_vusb_send(HvVirtioUsb *d, uint8_t type, uint8_t ep, const void *data, uint32_t len);
/* An IN transfer request: header only, len = the most the host takes. */
int hv_vusb_send_in(HvVirtioUsb *d, uint8_t ep, uint32_t len);
/* Wait up to timeout_ms for the next response on `ep` (or any endpoint if
   ep == 0xff; reset responses always match). 1: got one (free m->data),
   0: timed out, -1: the guest disconnected. */
int hv_vusb_recv(HvVirtioUsb *d, uint8_t ep, HvVusbMsg *out, int timeout_ms);
/* Drop queued responses (after a reset or reconnect). */
void hv_vusb_flush(HvVirtioUsb *d);

#endif
