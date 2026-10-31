// Read-only, build-gated game state for adaptive bow feedback.
#pragma once
#include "dm.h"

typedef struct {
    const char *build;
    uint32_t mode_global, player_info_global, player_field, charge_global, charge_field;
    uint32_t state_field, life_field, active_life, drawing_state, playing_mode;
    uint32_t bow_link_field, link_generation_field, owner_generation_field, owner_actor_field;
    uint32_t ready_state, reload_state;
    uint32_t shot_bow_reg; // 31 disables the optional successful-shot gate.
} dm_bow_layout;
typedef int (*dm_bow_read_fn)(void *context, uint64_t address, void *out, size_t size);

typedef enum { DM_BOW_UNAVAILABLE, DM_BOW_READY, DM_BOW_RELOAD, DM_BOW_DRAW } dm_bow_phase;
typedef struct {
    dm_bow_phase phase;
    float charge;
    uint64_t player, bow;
    uint32_t generation;
} dm_bow_snapshot;
typedef struct {
    uint64_t sequence, player, time_ns;
    int live;
} dm_bow_shot;

dm_bow_snapshot dm_bow_sample(const dm_bow_layout *layout, uint64_t base, dm_bow_read_fn read, void *context);
int dm_bow_mac_bind(const module_t *modules, int count);
dm_bow_snapshot dm_bow_mac_sample(void);
dm_bow_shot dm_bow_mac_shot_sample(void);
