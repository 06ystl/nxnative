// Read-only, build-gated shield state; no calls into guest code.
#pragma once
#include "dm.h"

typedef struct {
    const char *build;
    uint32_t mode_global, player_info_global, player_field, life_field;
    uint32_t active_life, playing_mode, shield_link_field, link_generation_field;
    uint32_t owner_generation_field, owner_actor_field, flags_field, guard_mask, durability_field;
} dm_shield_layout;
typedef int (*dm_shield_read_fn)(void *context, uint64_t address, void *out, size_t size);
typedef struct {
    int valid, guarding;
    int32_t durability;
    uint64_t player, shield;
    uint32_t generation;
} dm_shield_snapshot;

dm_shield_snapshot dm_shield_sample(const dm_shield_layout *layout, uint64_t base, dm_shield_read_fn read, void *context);
int dm_shield_mac_bind(const module_t *modules, int count);
dm_shield_snapshot dm_shield_mac_sample(void);
