#include "bow_state_mac.h"
#include <mach/mach.h>
#include <math.h>
#include <pthread.h>

static const dm_bow_layout layouts[] = {DM_GAME_MAC_BOW_STATE};
static const dm_bow_layout *g_layout;
static uint64_t g_base;
static pthread_mutex_t shot_lock = PTHREAD_MUTEX_INITIALIZER;
static dm_bow_shot g_shot;

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
static uint64_t live_player(void) {
    const dm_bow_layout *l = g_layout;
    uint32_t mode; uint64_t info, player; uint8_t life;
    if (!l || !copy_guest(NULL,g_base+l->mode_global,&mode,4) || mode!=l->playing_mode ||
        !copy_guest(NULL,g_base+l->player_info_global,&info,8) || !info ||
        !copy_guest(NULL,info+l->player_field,&player,8) || !player ||
        !copy_guest(NULL,player+l->life_field,&life,1) || life!=l->active_life) return 0;
    return player;
}
static void shot_observe(const uint64_t *regs) {
    if (!g_layout || g_layout->shot_bow_reg>30) return;
    uint64_t player=live_player(),owner,bow,again; uint32_t generation,word;
    const dm_bow_layout *l=g_layout;
    if (!player || !copy_guest(NULL,player+l->bow_link_field,&owner,8) || !owner ||
        !copy_guest(NULL,player+l->bow_link_field+l->link_generation_field,&generation,4) || generation==UINT32_MAX ||
        !copy_guest(NULL,owner+l->owner_generation_field,&word,4) || word!=generation ||
        !copy_guest(NULL,owner+l->owner_actor_field,&bow,8) || !bow || regs[l->shot_bow_reg]!=bow) return;
    // The arrow can break this bow: match the equipment link, not its later
    // lifecycle or charge state. The verified gate runs only on committed shots.
    if (live_player()!=player || !copy_guest(NULL,player+l->bow_link_field,&again,8) || again!=owner ||
        !copy_guest(NULL,player+l->bow_link_field+l->link_generation_field,&word,4) || word!=generation ||
        !copy_guest(NULL,owner+l->owner_generation_field,&word,4) || word!=generation ||
        !copy_guest(NULL,owner+l->owner_actor_field,&again,8) || again!=bow) return;
    pthread_mutex_lock(&shot_lock);
    g_shot=(dm_bow_shot){g_shot.sequence+1,player,clock_gettime_nsec_np(CLOCK_MONOTONIC),1};
    pthread_mutex_unlock(&shot_lock);
}
dm_bow_shot dm_bow_mac_shot_sample(void) {
    pthread_mutex_lock(&shot_lock); dm_bow_shot shot=g_shot; pthread_mutex_unlock(&shot_lock);
    shot.live=shot.player && live_player()==shot.player;
    return shot;
}
static void shot_gate_observe(uint64_t *regs,int param) { (void)param;shot_observe(regs); }
int dm_bow_mac_bind(const module_t *modules, int count) {
    g_layout = NULL; g_base = 0;
    pthread_mutex_lock(&shot_lock); g_shot=(dm_bow_shot){0}; pthread_mutex_unlock(&shot_lock);
    for (int i = 0; i < count; i++) if (!strcmp(modules[i].name, "main")) {
        const module_t *m = &modules[i];
        for (size_t k = 0; k < sizeof layouts / sizeof *layouts; k++) {
            const dm_bow_layout *l = &layouts[k];
            if (!l->build || strcmp(l->build, m->build_id)) continue;
            uint32_t globals[] = {l->mode_global, l->player_info_global, l->charge_global};
            for (size_t n = 0; n < sizeof globals / sizeof *globals; n++)
                if (globals[n] < m->data_off || globals[n] > m->size || m->size - globals[n] < 8) return 0;
            g_layout = l; g_base = (uint64_t)m->base;
            if (l->shot_bow_reg<=30 && gate_obs_present(OBS_BOW_SHOT)) gate_obs_set(OBS_BOW_SHOT,shot_gate_observe);
            LOG("Mac bow feedback: verified main %s", m->build_id);
            return 1;
        }
    }
    return 0;
}
dm_bow_snapshot dm_bow_mac_sample(void) { return dm_bow_sample(g_layout, g_base, copy_guest, NULL); }
