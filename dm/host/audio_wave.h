#pragma once
#include <stddef.h>
#include <stdint.h>
enum { DM_WAVE_CHANNELS = 6 };
typedef struct {uint32_t channels, frames, rate, data_offset[DM_WAVE_CHANNELS], data_bytes;} dm_wave_source;
// Locate encoded channel buffers; the game's SDK performs all decoding and DSP.
int dm_fwav_source(const uint8_t *data,size_t size,dm_wave_source *source);
