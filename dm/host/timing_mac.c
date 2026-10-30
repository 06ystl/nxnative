#include "timing_mac.h"
#include <math.h>
#include <stdatomic.h>

#define PAGE_SIZE_MAC 0x4000u
#define VENEER_WORDS 15
typedef struct { const char *build; uint32_t site, original, override_field, ratio_field, base_hz; } frame_patch;
typedef struct { const char *build; uint32_t site, original; } frame_guard;
static const frame_patch patches[] = {DM_GAME_MAC_FRAME_STEP};
static const frame_guard guards[] = {DM_GAME_MAC_FRAME_GUARDS};
static _Atomic uint32_t *g_ratio;
static _Atomic uint64_t *g_accepted;
static int g_target, g_pending;
static size_t g_data_offset;
static uint64_t g_last, g_seen = UINT64_MAX;
static unsigned g_base_hz;
static _Atomic double g_seconds;

static uint32_t float_bits(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }
static uint32_t branch_word(size_t from, size_t to) {
    int64_t delta = (int64_t)to - (int64_t)from;
    return 0x14000000u | ((uint32_t)(delta / 4) & 0x3ffffffu);
}
static int word_is(const uint8_t *image, size_t length, size_t at, uint32_t wanted) {
    uint32_t actual;
    if (at > length || length - at < 4 || at % 4) return 0;
    memcpy(&actual, image + at, 4); return actual == wanted;
}
int dm_timing_mac_prepare(const module_t *module, uint8_t *image, size_t length) {
    if (strcmp(module->name, "main")) return 0;
    const char *env = getenv("DM_FPS");
    if (env && strcmp(env, "60") && strcmp(env, "90") && strcmp(env, "120")) return 0;
    // Keep explicit upstream timing experiments available. For this verified
    // Mac profile, elapsed-time 60 avoids a persistent whole-vsync 30 Hz hold.
    if ((!env || !strcmp(env, "60")) && (getenv("DM_FPS_TARGET") || getenv("DM_FRAME_STEP"))) return 0;
    int target = env ? atoi(env) : 60;
    if (!patches[0].build) {
        if (env && target > 60) LOG("DM_FPS=%s: this profile keeps its existing 30/60 Hz timing", env);
        return 0;
    }
    const frame_patch *p = NULL;
    for (size_t i = 0; i < sizeof patches / sizeof *patches; i++)
        if (patches[i].build && !strcmp(module->build_id, patches[i].build)) p = &patches[i];
    if (!p || module->patch_off < 0 || !word_is(image, length, p->site, p->original)) {
        LOG("【红】High-refresh timing requires a verified main build and matching instructions"); return -1;
    }
    for (size_t i = 0; i < sizeof guards / sizeof *guards; i++) {
        const frame_guard *guard = &guards[i];
        if (guard->build && !strcmp(module->build_id, guard->build) &&
            !word_is(image, length, guard->site, guard->original)) {
            LOG("【红】High-refresh timing guard differs at main+%#x", guard->site); return -1;
        }
    }
    size_t stub = (module->text_end + 15u) & ~(size_t)15u;
    size_t executable_end = (module->text_end + PAGE_SIZE_MAC - 1) & ~(size_t)(PAGE_SIZE_MAC - 1);
    size_t data = (length + PAGE_SIZE_MAC - 1) & ~(size_t)(PAGE_SIZE_MAC - 1);
    if (stub > length || VENEER_WORDS * 4 > length - stub || stub + VENEER_WORDS * 4 > module->ro_off ||
        stub + VENEER_WORDS * 4 > executable_end ||
        p->override_field > 0xfff || p->ratio_field > 0x3ffc || p->ratio_field % 4 || p->base_hz < 1 || p->base_hz > 240 ||
        llabs((int64_t)stub - p->site) >= (1ll << 27) || data >= (1ull << 32)) {
        LOG("【红】High-refresh timing veneer does not fit the verified image"); return -1;
    }
    for (size_t i = 0; i < VENEER_WORDS * 4; i++) if (image[stub + i]) {
        LOG("【红】High-refresh timing veneer padding is not empty"); return -1;
    }
    // Disassembly verifies that x9/x10/x11 are dead at the hook: the child-update
    // loop reloads x9; x10/x11 are unused before the next call.
    // Keep explicit interval overrides (Game Over/retry and intentional scaling).
    // Otherwise replace the nominal ratio, preserving downstream VFR scales.
    int64_t pages = (int64_t)(data >> 12) - (int64_t)((stub + 8) >> 12);
    uint32_t imm = (uint32_t)pages & 0x1fffff;
    int64_t out_pages = (int64_t)(data >> 12) - (int64_t)((stub + 32) >> 12);
    uint32_t out_imm = (uint32_t)out_pages & 0x1fffff;
    uint32_t code[VENEER_WORDS] = {
        0x39400269u | (p->override_field << 10),       // ldrb w9,[x19,#override]
        0x35000009u | (7u << 5),                     // cbnz w9, publish accepted step
        0x90000009u | ((imm & 3) << 29) | ((imm >> 2) << 5),
        0xbd400121u,                                // ldr s1,[x9] (dt * base FPS)
        0xbd000261u | ((p->ratio_field / 4) << 10),   // str s1,[x19,#ratio]
        p->original,                                // fcmp s1,s0 (previous ratio)
        0x1a9f07e9u,                                // cset w9,ne
        0x2a090108u,                                // orr w8,w8,w9 (changed flag)
        0x90000009u | ((out_imm & 3) << 29) | ((out_imm >> 2) << 5),
        0x1e26002au,                                // fmov w10,s1
        0x3940026bu | (p->override_field << 10),      // ldrb w11,[x19,#override]
        0xaa0b814au,                                // orr x10,x10,x11,lsl #32
        0xf900052au,                                // str x10,[x9,#8] (atomic pair)
        p->original,
        branch_word(stub + 56, p->site + 4)
    };
    memcpy(image + stub, code, sizeof code);
    uint32_t hook = branch_word(p->site, stub); memcpy(image + p->site, &hook, 4);
    g_data_offset = data; g_pending = target; g_base_hz = p->base_hz;
    LOG("Mac real-time VFR: %d Hz, verified main %s, VFR hook +%#x", g_pending, module->build_id, p->site);
    return PAGE_SIZE_MAC;
}
void dm_timing_mac_bind(const module_t *module) {
    if (!g_pending || strcmp(module->name, "main")) return;
    g_ratio = (_Atomic uint32_t *)(module->base + g_data_offset);
    g_accepted = (_Atomic uint64_t *)(module->base + g_data_offset + 8);
    g_seconds = 1.0 / g_pending;
    // The profile supplies the base rate verified at VFR initialization.
    atomic_store(g_ratio, float_bits((float)(g_seconds * g_base_hz)));
    atomic_store(g_accepted, atomic_load(g_ratio));
    g_target = g_pending; g_pending = 0; g_last = 0; g_seen = UINT64_MAX;
}
int dm_game_frame_target(void) {
    if (!g_target || !g_accepted) return 0;
    uint64_t accepted = atomic_load_explicit(g_accepted, memory_order_acquire);
    if (accepted >> 32) {
        uint32_t bits = (uint32_t)accepted; float ratio; memcpy(&ratio, &bits, 4);
        if (isfinite(ratio) && ratio > 0) {
            int hz = (int)lround(g_base_hz / ratio);
            return hz < 15 ? 15 : hz > g_target ? g_target : hz;
        }
    }
    return g_target;
}
void dm_game_frame_sample(uint64_t time_ns, uint64_t frame) {
    if (!g_ratio || !time_ns || frame == g_seen) return;
    g_seen = frame;
    uint64_t last = g_last;
    if (last && time_ns <= last) return;
    g_last = time_ns;
    if (!last) return;
    double seconds = (time_ns - last) * 1e-9;
    // Resume/loading gaps do not become a large physics step. Ordinary slow
    // frames still advance real time, down to the engine's tested 15 Hz range.
    if (seconds > .25) { g_seconds = 1.0 / g_target; }
    else { g_seconds = fmax(1.0 / 120.0, fmin(1.0 / 15.0, seconds)); }
    atomic_store_explicit(g_ratio, float_bits((float)(g_seconds * g_base_hz)), memory_order_release);
}
double dm_game_frame_seconds(void) {
    if (!g_accepted) return 0;
    uint32_t bits = (uint32_t)atomic_load_explicit(g_accepted, memory_order_acquire);
    float ratio; memcpy(&ratio, &bits, 4); return ratio / g_base_hz;
}
