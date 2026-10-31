#pragma once
#include "dm.h"
// Module/object offsets are supplied by the verified game profile.
typedef struct {
    const char *build, *event_patterns;
    uint32_t mode_global, info_global, player_field, life_field, live, playing;
    uint32_t event_reg, event_gen, event_resource, resource_name;
    uint32_t head_field, node_parent, node_phase, phase_first, phase_last;
    uint32_t handle_field, handle_gen, sound_gen, sound_state, inactive_state;
    uint32_t sound_player, player_vtable, wave_field;
} dm_audio_source_layout;
typedef int (*dm_audio_source_read_fn)(void*,uint64_t,void*,size_t);
int dm_audio_sources_prepare(const module_t *modules,int count);
int dm_audio_sources_configured(void);
void dm_audio_sources_set_active(int active);
void dm_audio_sources_observe(const uint64_t *regs);
// Called only inside the serialized audio-render path. No independent playback.
unsigned dm_audio_sources_begin(void);
int dm_audio_sources_source(uint64_t encoded_buffer);
void dm_audio_sources_finish(unsigned epoch,const float *stereo,unsigned frames);
extern void (*dm_audio_sources_submit)(const float *stereo,unsigned frames);
