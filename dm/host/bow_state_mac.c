#include "bow_state_mac.h"
#include <mach/mach.h>
#include <math.h>

static const dm_bow_layout layouts[] = {DM_GAME_MAC_BOW_STATE};
static const dm_bow_layout *g_layout;
static uint64_t g_base;

// All copies go through the reader: the feedback queue never dereferences guest
// pointers or invokes guest functions. Revalidate identities/state after copying
// to reject teardown, equipment replacement and pause transitions mid-sample.
dm_bow_snapshot dm_bow_sample(const dm_bow_layout *l, uint64_t base, dm_bow_read_fn read, void *ctx) {
    uint64_t info, player, charge_owner, owner, bow, again;
    uint32_t mode, state, generation, owner_generation, word;
    uint8_t life;
    float charge;
#define READ(at, value) do { if (!read(ctx, (at), &(value), sizeof(value))) return (dm_bow_snapshot){0}; } while (0)
    if (!l || !base || !read) return (dm_bow_snapshot){0};
    READ(base + l->mode_global, mode);
    if (mode != l->playing_mode) return (dm_bow_snapshot){0};
    READ(base + l->player_info_global, info); if (!info) return (dm_bow_snapshot){0};
    READ(info + l->player_field, player); if (!player) return (dm_bow_snapshot){0};
    READ(player + l->life_field, life); if (life != l->active_life) return (dm_bow_snapshot){0};
    READ(player + l->state_field, state);
    dm_bow_phase phase = state == l->drawing_state ? DM_BOW_DRAW :
                         state == l->ready_state ? DM_BOW_READY :
                         state == l->reload_state ? DM_BOW_RELOAD : DM_BOW_UNAVAILABLE;
    if (!phase) return (dm_bow_snapshot){0};
    READ(player + l->bow_link_field, owner); if (!owner) return (dm_bow_snapshot){0};
    READ(player + l->bow_link_field + l->link_generation_field, generation);
    if (generation == UINT32_MAX) return (dm_bow_snapshot){0};
    READ(owner + l->owner_generation_field, owner_generation);
    if (owner_generation != generation) return (dm_bow_snapshot){0};
    READ(owner + l->owner_actor_field, bow); if (!bow) return (dm_bow_snapshot){0};
    READ(bow + l->life_field, life); if (life != l->active_life) return (dm_bow_snapshot){0};
    charge_owner = 0; charge = 0;
    if (phase == DM_BOW_DRAW) {
        READ(base + l->charge_global, charge_owner); if (!charge_owner) return (dm_bow_snapshot){0};
        READ(charge_owner + l->charge_field, charge);
        if (!isfinite(charge) || charge < 0 || charge > 1) return (dm_bow_snapshot){0};
    }
    READ(base + l->mode_global, word); if (word != mode) return (dm_bow_snapshot){0};
    READ(base + l->player_info_global, again); if (again != info) return (dm_bow_snapshot){0};
    READ(info + l->player_field, again); if (again != player) return (dm_bow_snapshot){0};
    READ(player + l->life_field, life); if (life != l->active_life) return (dm_bow_snapshot){0};
    READ(player + l->state_field, word); if (word != state) return (dm_bow_snapshot){0};
    READ(player + l->bow_link_field, again); if (again != owner) return (dm_bow_snapshot){0};
    READ(player + l->bow_link_field + l->link_generation_field, word); if (word != generation) return (dm_bow_snapshot){0};
    READ(owner + l->owner_generation_field, word); if (word != generation) return (dm_bow_snapshot){0};
    READ(owner + l->owner_actor_field, again); if (again != bow) return (dm_bow_snapshot){0};
    READ(bow + l->life_field, life); if (life != l->active_life) return (dm_bow_snapshot){0};
    if (phase == DM_BOW_DRAW) {
        READ(base + l->charge_global, again); if (again != charge_owner) return (dm_bow_snapshot){0};
    }
    return (dm_bow_snapshot){phase, charge, player, bow, generation};
#undef READ
}
static int copy_guest(void *context, uint64_t address, void *out, size_t size) {
    (void)context;
    if (!address || address > UINT64_MAX - size) return 0;
    vm_size_t got = 0;
    return !vm_read_overwrite(mach_task_self(), address, size, (vm_address_t)out, &got) && got == size;
}
int dm_bow_mac_bind(const module_t *modules, int count) {
    g_layout = NULL; g_base = 0;
    for (int i = 0; i < count; i++) if (!strcmp(modules[i].name, "main")) {
        const module_t *m = &modules[i];
        for (size_t k = 0; k < sizeof layouts / sizeof *layouts; k++) {
            const dm_bow_layout *l = &layouts[k];
            if (!l->build || strcmp(l->build, m->build_id)) continue;
            uint32_t globals[] = {l->mode_global, l->player_info_global, l->charge_global};
            for (size_t n = 0; n < sizeof globals / sizeof *globals; n++)
                if (globals[n] < m->data_off || globals[n] > m->size || m->size - globals[n] < 8) return 0;
            g_layout = l; g_base = (uint64_t)m->base;
            LOG("Mac bow feedback: verified main %s", m->build_id);
            return 1;
        }
    }
    return 0;
}
dm_bow_snapshot dm_bow_mac_sample(void) { return dm_bow_sample(g_layout, g_base, copy_guest, NULL); }
