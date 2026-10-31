#include "controller_ui_mac.h"
#include "game_profile.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>

static char app_bundle[PATH_MAX];

void dm_controller_ui_mac_set_app_bundle(const char *path) {
    app_bundle[0] = 0;
    if (path && !realpath(path, app_bundle)) app_bundle[0] = 0;
}

static int local_pack(char root[4096]) {
    if (!app_bundle[0]) return 0;
    const char *slash = strrchr(app_bundle, '/');
    if (!slash) return 0;
    size_t parent = (size_t)(slash - app_bundle);
    char marker[4096];
    if (snprintf(root, 4096, "%.*s/patches/dualsense-ui/romfs", (int)parent, app_bundle) >= 4096 ||
        snprintf(marker, sizeof marker, "%.*s/patches/dualsense-ui/manifest.tsv", (int)parent, app_bundle) >= (int)sizeof marker) return 0;
    FILE *f = fopen(marker, "r"); char line[128];
    int valid = f && fgets(line, sizeof line, f) && !strcmp(line, "game\t" DM_GAME_ID "\n");
    if (f) fclose(f);
    struct stat st;
    return valid && !stat(root, &st) && S_ISDIR(st.st_mode) && !access(root, R_OK);
}

int dm_controller_ui_mac_available(void) { char root[4096]; return local_pack(root); }

int dm_controller_ui_mac_select(int dualsense) {
    if (!dualsense) return 0;
    char root[4096];
    if (!local_pack(root)) {
        fprintf(stderr, "[dm] Controller UI: DualSense detected; compatible local UI pack not installed, keeping original prompts\n");
        return 0;
    }
    // Explicit user overlays keep their original priority and precedence.
    const char *overlays = getenv("DM_ROMFS_OVERLAY"); char combined[4096];
    int n = overlays && *overlays ? snprintf(combined, sizeof combined, "%s:%s", overlays, root)
                                 : snprintf(combined, sizeof combined, "%s", root);
    if (n >= (int)sizeof combined || setenv("DM_ROMFS_OVERLAY", combined, 1)) {
        fprintf(stderr, "[dm] Controller UI: cannot add local UI overlay; keeping existing resources\n");
        return 0;
    }
    fprintf(stderr, "[dm] Controller UI: PS5 prompts selected at startup (cross=A, circle=B, square=X, triangle=Y); restart after changing controllers\n");
    return 1;
}
