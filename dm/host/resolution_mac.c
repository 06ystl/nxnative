#include "resolution_mac.h"

typedef struct {
    const char *build;
    size_t offset;
    uint32_t original, hd, full_hd;
} resolution_patch;
static const resolution_patch patches[] = {DM_GAME_MAC_RESOLUTION_PATCHES};

int dm_resolution_mac_patch(const module_t *module, uint8_t *image, size_t length) {
    const char *request = getenv("DM_GAME_RES");
    // Other games keep their existing KRES parameter handling, including its
    // accepted values. Only profiles with verified loader sites use this path.
    if (!patches[0].build || !request || !*request || strcmp(module->name, "main")) return 0;
    int full_hd = !strcmp(request, "1920x1080");
    if (!full_hd && strcmp(request, "1280x720")) {
        LOG("【红】DM_GAME_RES for this Mac profile requires 1280x720 or 1920x1080");
        return -1;
    }
    unsigned count = 0;
    // Validate the entire selection before changing any instruction. A new
    // build or modified module must never inherit addresses from another one.
    for (size_t i = 0; i < sizeof patches / sizeof patches[0]; i++) {
        const resolution_patch *p = &patches[i];
        if (strcmp(module->build_id, p->build)) continue;
        if (p->offset > length || length - p->offset < sizeof(uint32_t)) {
            LOG("【红】DM_GAME_RES patch lies outside the module image");
            return -1;
        }
        uint32_t word; memcpy(&word, image + p->offset, sizeof word);
        if (word != p->original) {
            LOG("【红】DM_GAME_RES instruction does not match the verified build at %#zx", p->offset);
            return -1;
        }
        count++;
    }
    if (!count) {
        LOG("【红】DM_GAME_RES has no verified Mac preset for main build %s", module->build_id);
        return -1;
    }
    for (size_t i = 0; i < sizeof patches / sizeof patches[0]; i++) {
        const resolution_patch *p = &patches[i];
        if (strcmp(module->build_id, p->build)) continue;
        uint32_t word = full_hd ? p->full_hd : p->hd;
        memcpy(image + p->offset, &word, sizeof word);
    }
    LOG("Mac render resolution: %s (%u verified sites, main build %s)", request, count, module->build_id);
    return 1;
}
