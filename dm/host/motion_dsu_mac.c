// DSU v1001: https://v1993.github.io/cemuhook-protocol/
// DSU -> Switch axes follow Ryujinx.Input/Motion/CemuHook/Client.cs:
// accel=(x,-z,y), gyro=(pitch,roll,-yaw). MotionSource's portrait setting
// consequently maps to Apple's physical device axes (x right, y top, z out).
#include "motion_dsu_mac.h"
#include "motion_filter_mac.h"
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DSU_TIMEOUT_NS 500000000ull

struct dm_dsu_client {
    pthread_mutex_t lock;
    pthread_cond_t wake;
    pthread_t thread;
    int stop, enabled, active;
    unsigned generation, port;
    char host[256];
    uint64_t received_ns, sampling;
    motion_filter filter;
    dm_dsu_status status;
};

static uint64_t motion_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static uint16_t le16(const unsigned char *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint32_t le32(const unsigned char *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }
static uint64_t le64(const unsigned char *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }
static void put16(unsigned char *p, uint16_t x) { p[0] = x; p[1] = x >> 8; }
static void put32(unsigned char *p, uint32_t x) { put16(p, x); put16(p + 2, x >> 16); }
static float le_float(const unsigned char *p) { uint32_t x = le32(p); float f; memcpy(&f, &x, 4); return f; }
static uint32_t packet_crc(const unsigned char *p, size_t n) {
    uint32_t crc = ~0u;
    for (size_t i = 0; i < n; i++) {
        crc ^= i >= 8 && i < 12 ? 0 : p[i];
        for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
    }
    return ~crc;
}
static size_t subscription(unsigned char *p, uint32_t client_id) {
    memset(p, 0, 28); memcpy(p, "DSUC", 4);
    put16(p + 4, 1001); put16(p + 6, 12); put32(p + 12, client_id);
    put32(p + 16, 0x100002); p[20] = 1; // Subscribe to slot zero by ID.
    put32(p + 8, packet_crc(p, 28)); return 28;
}
static int decode_packet(const unsigned char *p, size_t n, motion_packet *out) {
    if (n != 100 || memcmp(p, "DSUS", 4) || le16(p + 4) != 1001 ||
        le16(p + 6) != n - 16 || le32(p + 16) != 0x100002 ||
        le32(p + 8) != packet_crc(p, n) || p[20] != 0 || p[21] != 2 || !p[31]) return 0;
    double a[3], g[3];
    for (int i = 0; i < 3; i++) {
        a[i] = le_float(p + 76 + 4 * i); g[i] = le_float(p + 88 + 4 * i);
        if (!isfinite(a[i]) || !isfinite(g[i])) return 0;
    }
    *out = (motion_packet){.timestamp = le64(p + 68), .sequence = le32(p + 32), .server = le32(p + 12),
        .accel = {a[0], -a[2], a[1]}, .gyro = {g[0], g[2], -g[1]}};
    return out->timestamp != 0;
}

static void status_set(dm_dsu_client *c, dm_dsu_phase phase, const char *message) {
    if (c->status.phase != phase || strcmp(c->status.message, message))
        fprintf(stderr,"[dm] Motion: %s\n",message);
    c->status.phase=phase; snprintf(c->status.message,sizeof c->status.message,"%s",message);
}
static int open_socket(const char *host, unsigned port, char *error, size_t cap) {
    char service[8]; snprintf(service,sizeof service,"%u",port);
    struct addrinfo hints={.ai_family=AF_UNSPEC,.ai_socktype=SOCK_DGRAM}, *addresses=NULL;
    int rc=getaddrinfo(host,service,&hints,&addresses), fd=-1;
    if (rc) { snprintf(error,cap,"Cannot resolve phone: %s",gai_strerror(rc)); return -1; }
    for (struct addrinfo *a=addresses;a;a=a->ai_next) {
        fd=socket(a->ai_family,a->ai_socktype,a->ai_protocol);
        if (fd>=0) {
            // Darwin can raise SIGPIPE for failed UDP sends. Keep the failure
            // local to this socket so a phone/network error cannot kill the game.
            int no_sigpipe=1;
            if (!setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof no_sigpipe) &&
                !connect(fd,a->ai_addr,a->ai_addrlen)) break;
        }
        if (fd>=0) close(fd); fd=-1;
    }
    if (fd<0) snprintf(error,cap,"Cannot connect: %s",strerror(errno));
    freeaddrinfo(addresses); return fd;
}
static void *network_main(void *arg) {
    dm_dsu_client *c=arg;
    int fd=-1; unsigned generation=0;
    uint64_t next_request=0, next_open=0;
    unsigned char request[28], buffer[2048]; subscription(request, (uint32_t)motion_now());
    for (;;) {
        pthread_mutex_lock(&c->lock);
        while (!c->enabled && !c->stop) {
            if (fd>=0) { close(fd); fd=-1; }
            pthread_cond_wait(&c->wake,&c->lock);
        }
        if (c->stop) { pthread_mutex_unlock(&c->lock); break; }
        if (generation!=c->generation) {
            generation=c->generation; next_request=next_open=0;
            if (fd>=0) { close(fd); fd=-1; }
        }
        char host[256]; snprintf(host,sizeof host,"%s",c->host); unsigned port=c->port;
        pthread_mutex_unlock(&c->lock);
        uint64_t now=motion_now();
        if (fd<0 && now>=next_open) {
            char error[192]; fd=open_socket(host,port,error,sizeof error); next_open=now+2000000000ull;
            pthread_mutex_lock(&c->lock);
            if (generation==c->generation)
                status_set(c,fd<0?DM_DSU_ERROR:DM_DSU_WAITING,fd<0?error:"Waiting for MotionSource; keep the phone app open");
            pthread_mutex_unlock(&c->lock);
        }
        if (fd>=0 && now>=next_request) {
            // MotionSource drops its client after three seconds: renew every second.
            if (send(fd,request,sizeof request,0)<0) {
                char error[192]; snprintf(error,sizeof error,"Cannot send to phone: %s; retrying",strerror(errno));
                pthread_mutex_lock(&c->lock);
                if (generation==c->generation) status_set(c,DM_DSU_ERROR,error);
                pthread_mutex_unlock(&c->lock);
                close(fd); fd=-1;
            }
            next_request=now+1000000000ull;
        }
        struct pollfd pf={.fd=fd,.events=POLLIN}; int rc=poll(&pf,1,100);
        if (rc>0 && (pf.revents&POLLIN)) {
            ssize_t n=recv(fd,buffer,sizeof buffer,0); motion_packet packet;
            if (n>0 && decode_packet(buffer,(size_t)n,&packet)) {
                pthread_mutex_lock(&c->lock);
                if (c->enabled && generation==c->generation) {
                    now=motion_now();
                    if (c->received_ns && now-c->received_ns>DSU_TIMEOUT_NS) reset_filter(&c->filter);
                    if (filter_packet(&c->filter,&packet)) {
                        c->received_ns=now;
                        if (c->filter.ready) c->filter.state.sampling=++c->sampling;
                        status_set(c,c->filter.ready?DM_DSU_READY:DM_DSU_CALIBRATING,
                                   c->filter.ready?"Phone motion connected":"Calibrating: hold the phone still for one second");
                        c->status.samples=c->filter.count;
                    }
                }
                pthread_mutex_unlock(&c->lock);
            }
        } else if (rc>0 && (pf.revents&(POLLERR|POLLHUP|POLLNVAL))) { close(fd); fd=-1; }
        pthread_mutex_lock(&c->lock);
        if (c->enabled && generation==c->generation && c->received_ns && motion_now()-c->received_ns>DSU_TIMEOUT_NS)
            status_set(c,DM_DSU_WAITING,"Phone motion lost; reconnecting automatically");
        pthread_mutex_unlock(&c->lock);
    }
    if (fd>=0) close(fd);
    return NULL;
}

dm_dsu_client *dm_dsu_create(void) {
    dm_dsu_client *c=calloc(1,sizeof *c); if (!c) return NULL;
    pthread_mutex_init(&c->lock,NULL); pthread_cond_init(&c->wake,NULL); reset_filter(&c->filter);
    c->active=1;
    if (pthread_create(&c->thread,NULL,network_main,c)) {
        pthread_cond_destroy(&c->wake); pthread_mutex_destroy(&c->lock); free(c); return NULL;
    }
    return c;
}
void dm_dsu_destroy(dm_dsu_client *c) {
    if (!c) return;
    pthread_mutex_lock(&c->lock); c->stop=1; pthread_cond_signal(&c->wake); pthread_mutex_unlock(&c->lock);
    pthread_join(c->thread,NULL); pthread_cond_destroy(&c->wake); pthread_mutex_destroy(&c->lock); free(c);
}
void dm_dsu_configure(dm_dsu_client *c, const char *host, unsigned port) {
    pthread_mutex_lock(&c->lock);
    snprintf(c->host,sizeof c->host,"%s",host?host:""); c->port=port; c->enabled=c->host[0]!=0;
    c->generation++; c->received_ns=0; reset_filter(&c->filter); c->status.samples=0;
    status_set(c,c->enabled?DM_DSU_WAITING:DM_DSU_OFF,c->enabled?"Connecting to phone":"Phone motion off");
    pthread_cond_signal(&c->wake); pthread_mutex_unlock(&c->lock);
}
void dm_dsu_calibrate(dm_dsu_client *c) {
    pthread_mutex_lock(&c->lock); reset_filter(&c->filter); c->status.samples=0;
    if (c->enabled) status_set(c,DM_DSU_CALIBRATING,"Calibrating: hold the phone still for one second");
    pthread_mutex_unlock(&c->lock);
}
void dm_dsu_set_active(dm_dsu_client *c, int active) {
    pthread_mutex_lock(&c->lock); c->active=active; pthread_mutex_unlock(&c->lock);
}
int dm_dsu_read(dm_dsu_client *c, dm_sixaxis_state *state, int fusion) {
    pthread_mutex_lock(&c->lock);
    int ok=c->enabled && c->active && c->filter.ready && c->received_ns && motion_now()-c->received_ns<=DSU_TIMEOUT_NS;
    memset(state,0,sizeof *state);
    if (ok) {
        *state=c->filter.state;
        if (!fusion) memcpy(state->direction,c->filter.raw_direction,sizeof state->direction);
    }
    pthread_mutex_unlock(&c->lock); return ok;
}
dm_dsu_status dm_dsu_get_status(dm_dsu_client *c) {
    pthread_mutex_lock(&c->lock); dm_dsu_status status=c->status; pthread_mutex_unlock(&c->lock); return status;
}
