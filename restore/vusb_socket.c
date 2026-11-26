/* Socket-backed virtio-usb host client: the hv_vusb_* backend that Henge's
   libusb shim and usb_host.c expect, with the guest living in the emulator
   harness process across a Unix socket.
   Wire frames (little-endian):
     client -> server, kind 1 (request):  u8 kind, u8 type, u8 ep,
                                          u32 len, u32 payload_len, payload
       (payload_len == len for OUT data; payload_len == 0 with len > 0 is an
        IN request whose capacity is len; len == 0 is e.g. a bus reset)
     server -> client, kind 2 (response): u8 kind, u8 type, u8 ep,
                                          u32 len, payload[len]
     server -> client, kind 3 (state):    u8 kind, u8 online, u32 session   */

#include "virtio_usb.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int write_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1;
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static void drop_all_locked(HvVirtioUsb *d) {
    while (d->in_head != d->in_tail) {
        free(d->in[d->in_head % HV_VUSB_RING].data);
        d->in_head++;
    }
}

static void *reader_main(void *arg) {
    HvVirtioUsb *d = arg;
    for (;;) {
        uint8_t kind;
        if (read_all(d->fd, &kind, 1) != 0) break;
        if (kind == 2) {
            uint8_t hdr[6];
            if (read_all(d->fd, hdr, 6) != 0) break;
            HvVusbMsg m;
            m.type = hdr[0];
            m.ep = hdr[1];
            m.len = hdr[2] | (hdr[3] << 8) | ((uint32_t)hdr[4] << 16) | ((uint32_t)hdr[5] << 24);
            m.data = NULL;
            if (m.len) {
                m.data = malloc(m.len);
                if (!m.data || read_all(d->fd, m.data, m.len) != 0) {
                    free(m.data);
                    break;
                }
            }
            if (d->log) fprintf(stderr, "vusb: response type %u ep %#x len %u\n", m.type, m.ep, m.len);
            pthread_mutex_lock(&d->mu);
            if (d->in_tail - d->in_head < HV_VUSB_RING) d->in[d->in_tail++ % HV_VUSB_RING] = m;
            else free(m.data);
            pthread_cond_broadcast(&d->cv);
            pthread_mutex_unlock(&d->mu);
        } else if (kind == 3) {
            uint8_t st[5];
            if (read_all(d->fd, st, 5) != 0) break;
            pthread_mutex_lock(&d->mu);
            d->online = st[0] != 0;
            d->session = st[1] | (st[2] << 8) | ((uint32_t)st[3] << 16) | ((uint32_t)st[4] << 24);
            pthread_cond_broadcast(&d->cv);
            pthread_mutex_unlock(&d->mu);
            if (d->log) fprintf(stderr, "vusb: state online=%d session=%u\n", d->online, d->session);
        } else {
            fprintf(stderr, "vusb: bad frame kind %u\n", kind);
            break;
        }
    }
    pthread_mutex_lock(&d->mu);
    d->online = 0;
    d->session++;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    fprintf(stderr, "vusb: bridge connection closed\n");
    return NULL;
}

HvVirtioUsb *hv_vusb_client_connect(const char *socket_path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    struct sockaddr_un un;
    memset(&un, 0, sizeof un);
    un.sun_family = AF_UNIX;
    snprintf(un.sun_path, sizeof un.sun_path, "%s", socket_path);
    if (connect(fd, (struct sockaddr *)&un, sizeof un) != 0) {
        close(fd);
        return NULL;
    }
    HvVirtioUsb *d = calloc(1, sizeof *d);
    if (!d) {
        close(fd);
        return NULL;
    }
    d->fd = fd;
    d->log = getenv("HV_VUSB_LOG") != NULL;
    pthread_mutex_init(&d->mu, NULL);
    pthread_cond_init(&d->cv, NULL);
    pthread_mutex_init(&d->write_mu, NULL);
    pthread_t t;
    if (pthread_create(&t, NULL, reader_main, d) != 0) {
        free(d);
        close(fd);
        return NULL;
    }
    pthread_detach(t);
    return d;
}

int hv_vusb_online(HvVirtioUsb *d, uint32_t *session) {
    pthread_mutex_lock(&d->mu);
    int on = d->online;
    if (session) *session = d->session;
    pthread_mutex_unlock(&d->mu);
    return on;
}

static int send_frame(HvVirtioUsb *d, uint8_t type, uint8_t ep, const void *data, uint32_t len, uint32_t payload_len) {
    pthread_mutex_lock(&d->mu);
    int on = d->online;
    pthread_mutex_unlock(&d->mu);
    if (!on) return -1;
    uint8_t hdr[11];
    hdr[0] = 1;
    hdr[1] = type;
    hdr[2] = ep;
    hdr[3] = len & 0xff;
    hdr[4] = (len >> 8) & 0xff;
    hdr[5] = (len >> 16) & 0xff;
    hdr[6] = (len >> 24) & 0xff;
    hdr[7] = payload_len & 0xff;
    hdr[8] = (payload_len >> 8) & 0xff;
    hdr[9] = (payload_len >> 16) & 0xff;
    hdr[10] = (payload_len >> 24) & 0xff;
    pthread_mutex_lock(&d->write_mu);
    int rc = write_all(d->fd, hdr, 11);
    if (rc == 0 && payload_len) rc = write_all(d->fd, data, payload_len);
    pthread_mutex_unlock(&d->write_mu);
    if (d->log) fprintf(stderr, "vusb: request type %u ep %#x len %u payload %u -> %d\n", type, ep, len, payload_len, rc);
    return rc;
}

int hv_vusb_send(HvVirtioUsb *d, uint8_t type, uint8_t ep, const void *data, uint32_t len) {
    return send_frame(d, type, ep, data, len, data ? len : 0);
}

int hv_vusb_send_in(HvVirtioUsb *d, uint8_t ep, uint32_t len) {
    return send_frame(d, HV_VUSB_REQ_DATA, ep, NULL, len, 0);
}

int hv_vusb_recv(HvVirtioUsb *d, uint8_t ep, HvVusbMsg *out, int timeout_ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec until = {now.tv_sec + timeout_ms / 1000, now.tv_usec * 1000 + (long)(timeout_ms % 1000) * 1000000};
    if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    pthread_mutex_lock(&d->mu);
    uint32_t session = d->session;
    for (;;) {
        if (!d->online || d->session != session) {
            pthread_mutex_unlock(&d->mu);
            return -1;
        }
        for (uint32_t i = d->in_head; i != d->in_tail; i++) {
            HvVusbMsg *m = &d->in[i % HV_VUSB_RING];
            if (ep == 0xff || m->ep == ep) {
                *out = *m;
                for (uint32_t j = i; j != d->in_head; j--) d->in[j % HV_VUSB_RING] = d->in[(j - 1) % HV_VUSB_RING];
                d->in_head++;
                pthread_mutex_unlock(&d->mu);
                return 1;
            }
        }
        if (pthread_cond_timedwait(&d->cv, &d->mu, &until) == ETIMEDOUT) {
            pthread_mutex_unlock(&d->mu);
            return 0;
        }
    }
}

void hv_vusb_flush(HvVirtioUsb *d) {
    pthread_mutex_lock(&d->mu);
    drop_all_locked(d);
    pthread_mutex_unlock(&d->mu);
}
