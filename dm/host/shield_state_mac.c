#include "shield_state_mac.h"
#include <mach/mach.h>

static const dm_shield_layout layouts[] = {DM_GAME_MAC_SHIELD_STATE};
static const dm_shield_layout *g_layout;
static uint64_t g_base;

dm_shield_snapshot dm_shield_sample(const dm_shield_layout *l, uint64_t base, dm_shield_read_fn read, void *ctx) {
    uint64_t info, player, owner, shield, again;
    uint32_t mode, flags, generation, word;
    uint8_t life;
    int32_t durability;
#define READ(at, value) do { if (!read(ctx,(at),&(value),sizeof(value))) return (dm_shield_snapshot){0}; } while (0)
    if (!l || !base || !read) return (dm_shield_snapshot){0};
    READ(base+l->mode_global,mode); if (mode != l->playing_mode) return (dm_shield_snapshot){0};
    READ(base+l->player_info_global,info); if (!info) return (dm_shield_snapshot){0};
    READ(info+l->player_field,player); if (!player) return (dm_shield_snapshot){0};
    READ(player+l->life_field,life); if (life != l->active_life) return (dm_shield_snapshot){0};
    READ(player+l->flags_field,flags);
    READ(player+l->shield_link_field,owner); if (!owner) return (dm_shield_snapshot){0};
    READ(player+l->shield_link_field+l->link_generation_field,generation);
    if (generation == UINT32_MAX) return (dm_shield_snapshot){0};
    READ(owner+l->owner_generation_field,word); if (word != generation) return (dm_shield_snapshot){0};
    READ(owner+l->owner_actor_field,shield); if (!shield) return (dm_shield_snapshot){0};
    READ(shield+l->life_field,life); if (life != l->active_life) return (dm_shield_snapshot){0};
    READ(shield+l->durability_field,durability); if (durability <= 0) return (dm_shield_snapshot){0};
    // Recheck the equipment and simulation state across the copies. An old
    // guard flag can survive a pause; an old actor can survive unequip/break.
    READ(base+l->mode_global,word); if (word != mode) return (dm_shield_snapshot){0};
    READ(base+l->player_info_global,again); if (again != info) return (dm_shield_snapshot){0};
    READ(info+l->player_field,again); if (again != player) return (dm_shield_snapshot){0};
    READ(player+l->life_field,life); if (life != l->active_life) return (dm_shield_snapshot){0};
    READ(player+l->flags_field,word); if ((word^flags)&l->guard_mask) return (dm_shield_snapshot){0};
    READ(player+l->shield_link_field,again); if (again != owner) return (dm_shield_snapshot){0};
    READ(player+l->shield_link_field+l->link_generation_field,word); if (word != generation) return (dm_shield_snapshot){0};
    READ(owner+l->owner_generation_field,word); if (word != generation) return (dm_shield_snapshot){0};
    READ(owner+l->owner_actor_field,again); if (again != shield) return (dm_shield_snapshot){0};
    READ(shield+l->life_field,life); if (life != l->active_life) return (dm_shield_snapshot){0};
    return (dm_shield_snapshot){1,!!(flags&l->guard_mask),durability,player,shield,generation};
#undef READ
}
static int copy_guest(void *ctx, uint64_t address, void *out, size_t size) {
    (void)ctx;
    if (!address || address > UINT64_MAX-size) return 0;
    vm_size_t got=0;
    return !vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)out,&got) && got==size;
}
int dm_shield_mac_bind(const module_t *modules, int count) {
    g_layout=NULL; g_base=0;
    for (int i=0;i<count;i++) if (!strcmp(modules[i].name,"main")) {
        const module_t *m=&modules[i];
        for (size_t k=0;k<sizeof layouts/sizeof *layouts;k++) {
            const dm_shield_layout *l=&layouts[k];
            if (!l->build || strcmp(l->build,m->build_id)) continue;
            uint32_t globals[]={l->mode_global,l->player_info_global};
            for (size_t j=0;j<sizeof globals/sizeof *globals;j++)
                if (globals[j]<m->data_off || globals[j]>m->size || m->size-globals[j]<8) return 0;
            g_layout=l;g_base=(uint64_t)m->base;
            LOG("Mac shield feedback: verified main %s",m->build_id);
            return 1;
        }
    }
    return 0;
}
dm_shield_snapshot dm_shield_mac_sample(void) { return dm_shield_sample(g_layout,g_base,copy_guest,NULL); }
