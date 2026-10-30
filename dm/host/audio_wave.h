#pragma once
#include <stddef.h>
#include <stdint.h>
// Decode a non-looping, mono Nintendo FWAV into floating-point original PCM.
// The caller owns *pcm on success. No filtering, synthesis or normalization.
int dm_fwav_decode(const uint8_t *data,size_t size,float **pcm,uint32_t *frames,uint32_t *rate);
