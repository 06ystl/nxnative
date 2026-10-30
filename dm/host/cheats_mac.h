#pragma once
#include "dm.h"

// Optional, build-specific instruction patches. Apply only to the private image
// before executable pages are sealed; no guest code is changed while running.
int dm_cheats_mac_patch(const module_t *module, uint8_t *image, size_t length);
