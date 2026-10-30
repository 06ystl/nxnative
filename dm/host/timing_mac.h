#pragma once
#include "dm.h"

// A verified profile may supply real-time VFR while retaining the original
// explicit time overrides. The extra writable page follows the sealed image.
int dm_timing_mac_prepare(const module_t *module, uint8_t *image, size_t length);
void dm_timing_mac_bind(const module_t *module);
int dm_game_frame_target(void);
void dm_game_frame_sample(uint64_t time_ns, uint64_t frame);
double dm_game_frame_seconds(void);
