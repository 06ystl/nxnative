#pragma once
#include <stddef.h>
#include <stdint.h>
// Bracket the SDK's single processing pass under the audio renderer lock.
void dm_audio_haptics_begin(const uint8_t *commands,size_t bytes);
void dm_audio_haptics_end(void);
