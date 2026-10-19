// Cemuhook DSU motion client. Networking and fusion run on a worker thread.
#pragma once
#include "dm_input.h"

typedef struct dm_dsu_client dm_dsu_client;
typedef enum {
    DM_DSU_OFF, DM_DSU_WAITING, DM_DSU_CALIBRATING, DM_DSU_READY, DM_DSU_ERROR
} dm_dsu_phase;
typedef struct {
    dm_dsu_phase phase;
    char message[192];
    unsigned samples;
} dm_dsu_status;

dm_dsu_client *dm_dsu_create(void);
void dm_dsu_destroy(dm_dsu_client *client);
// Empty host disconnects. Configuration changes never wait for network I/O.
void dm_dsu_configure(dm_dsu_client *client, const char *host, unsigned port);
void dm_dsu_calibrate(dm_dsu_client *client);
void dm_dsu_set_active(dm_dsu_client *client, int active);
int dm_dsu_read(dm_dsu_client *client, dm_sixaxis_state *state, int fusion);
dm_dsu_status dm_dsu_get_status(dm_dsu_client *client);
