#include "cheats_mac.h"
#include <ctype.h>

typedef struct {
    const char *build, *name;
    size_t offset;
    uint32_t original, replacement;
} cheat_patch;
static const cheat_patch patches[] = {DM_GAME_MAC_CHEAT_PATCHES};

int dm_cheats_mac_patch(const module_t *module, uint8_t *image, size_t length) {
    const char *request = getenv("DM_CHEATS");
    if (strcmp(module->name, "main") || !request || !*request || !strcmp(request, "none")) return 0;
    unsigned char selected[sizeof patches / sizeof *patches] = {0};
    const char *next = request;
    for (;;) {
        const char *end = strchr(next, ',');
        if (!end) end = next + strlen(next);
        const char *start = next, *stop = end;
        while (start < stop && isspace((unsigned char)*start)) start++;
        while (stop > start && isspace((unsigned char)stop[-1])) stop--;
        size_t size = stop - start;
        int found = 0;
        if (size) for (size_t i = 0; i < sizeof patches / sizeof *patches; i++) {
            const cheat_patch *p = &patches[i];
            if (p->build && !strcmp(p->build, module->build_id) &&
                strlen(p->name) == size && !strncmp(p->name, start, size)) selected[i] = found = 1;
        }
        if (!found) {
            LOG("【红】DM_CHEATS: unsupported option '%.*s' for main build %s", (int)size, start, module->build_id);
            return -1;
        }
        if (!*end) break;
        next = end + 1;
    }
    // Validate the complete selection, including empty veneer slots, before
    // changing any byte. Never apply partial cheats to an unexpected image.
    uint64_t executable_end = (module->text_end + 0x3fff) & ~0x3fffull;
    for (size_t i = 0; i < sizeof patches / sizeof *patches; i++) if (selected[i]) {
        const cheat_patch *p = &patches[i];
        uint32_t actual;
        if (p->offset % 4 || p->offset > length || length - p->offset < 4 ||
            p->offset + 4 > executable_end || p->offset + 4 > module->ro_off) {
            LOG("【红】DM_CHEATS: %s site outside executable image at main+%#zx", p->name, p->offset);
            return -1;
        }
        memcpy(&actual, image + p->offset, 4);
        if (actual != p->original) {
            LOG("【红】DM_CHEATS: %s instruction mismatch at main+%#zx", p->name, p->offset);
            return -1;
        }
    }
    for (size_t i = 0; i < sizeof patches / sizeof *patches; i++) if (selected[i])
        memcpy(image + patches[i].offset, &patches[i].replacement, 4);
    LOG("Mac cheats enabled: %s (verified main %s; restart to change)", request, module->build_id);
    return 1;
}
