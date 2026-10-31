#pragma once
#include "dm.h"

// Apply a profile's verified resolution preset to the private loader image.
// Unset DM_GAME_RES and profiles without presets keep their original behavior.
int dm_resolution_mac_patch(const module_t *module, uint8_t *image, size_t length);
int dm_resolution_mac_has_presets(const char *build);
