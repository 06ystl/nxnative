#import <GameController/GameController.h>
#include <math.h>
#include <stdio.h>
#include "adaptive_trigger_mac.h"

dm_bow_snapshot (*dm_adaptive_trigger_sample)(void);
dm_shield_snapshot (*dm_adaptive_shield_sample)(void);
static GCDualSenseAdaptiveTrigger *g_right_trigger, *g_left_trigger;
static dm_shield_snapshot g_shield_previous;
static uint64_t g_shield_time, g_impact_until;
static int g_left_sent = -1;
static int g_active, g_closed, g_sent = -1, g_rearm = 1;
static uint64_t g_sampled;
static float g_charge;
static dm_bow_snapshot g_previous;
static dm_trigger_output_fn g_usb_output;
static int g_native_stale;
static void write_slope(unsigned side,dm_trigger_slope effect) {
    if(g_usb_output){g_usb_output(side,&effect);return;}
    if(g_native_stale){[g_left_trigger setModeOff];[g_right_trigger setModeOff];g_native_stale=0;}
    GCDualSenseAdaptiveTrigger *trigger=side?g_right_trigger:g_left_trigger;
    if(effect.enabled)[trigger setModeSlopeFeedbackWithStartPosition:effect.start endPosition:effect.end startStrength:effect.low endStrength:effect.high];
    else [trigger setModeOff];
}
void dm_adaptive_trigger_set_usb_output(dm_trigger_output_fn output) {
    if(g_usb_output==output)return;
    dm_trigger_slope off={0};
    if(g_usb_output){g_usb_output(0,&off);g_usb_output(1,&off);}
    g_usb_output=output;
    // Enter USB without emitting a native report: that report can switch the
    // device back to emulated rumble and suppress its audio actuator channels.
    if(output){output(0,&off);output(1,&off);g_native_stale=1;}
    g_sent=g_left_sent=-1;
}

static void trigger_off(void) {
    if (g_sent >= 0) write_slope(1,(dm_trigger_slope){0});
    g_sent = -1; g_charge = 0;
}
static void shield_off(void) {
    if (g_left_sent >= 0) write_slope(0,(dm_trigger_slope){0});
    g_left_sent = -1; g_impact_until = 0;
}
static void shield_tick(uint64_t now) {
    if (!g_left_trigger || !dm_adaptive_shield_sample) return;
    dm_shield_snapshot shield = dm_adaptive_shield_sample();
    float travel = g_left_trigger.value;
    int held = isfinite(travel) && travel > .02f;
    int same = shield.valid && g_shield_previous.valid &&
               shield.player == g_shield_previous.player && shield.shield == g_shield_previous.shield &&
               shield.generation == g_shield_previous.generation;
    // Durability loss on the same, actively guarding shield is damage to that
    // shield. Weapon swaps, menu resume, repairs and unguarded loss are not hits.
    int hit = same && held && g_shield_previous.guarding && shield.durability > 0 &&
              shield.durability < g_shield_previous.durability &&
              now >= g_shield_time && now - g_shield_time <= 100000000ull;
    if (!same) g_impact_until = 0;
    g_shield_previous = shield; g_shield_time = now;
    if (!shield.valid || shield.durability <= 0 || !held) { shield_off(); return; }
    if (hit) g_impact_until = now + 120000000ull;
    int pulse = now < g_impact_until ? (int)((g_impact_until-now+19999999ull)/20000000ull) : 0;
    if (!shield.guarding && !pulse) { shield_off(); return; }
    if (pulse == g_left_sent) return;
    float impact = pulse / 6.f;
    write_slope(0,(dm_trigger_slope){1,0,1,.10f + .06f*impact,.28f + .15f*impact});
    g_left_sent = pulse;
}
static void reset_pull(void) {
    trigger_off(); shield_off(); g_shield_previous = (dm_shield_snapshot){0};
    g_shield_time = 0; g_rearm = 1; g_sampled = 0;
    g_previous = (dm_bow_snapshot){0};
}
void dm_adaptive_trigger_attach(GCController *controller) {
    GCExtendedGamepad *profile = controller.extendedGamepad;
    GCDualSenseAdaptiveTrigger *next = [profile isKindOfClass:GCDualSenseGamepad.class] ? ((GCDualSenseGamepad *)profile).rightTrigger : nil;
    GCDualSenseAdaptiveTrigger *left = [profile isKindOfClass:GCDualSenseGamepad.class] ? ((GCDualSenseGamepad *)profile).leftTrigger : nil;
    if (next == g_right_trigger && left == g_left_trigger) return;
    reset_pull();
    g_right_trigger = next; g_left_trigger = left;
    if (next && dm_adaptive_trigger_sample)
        fprintf(stderr,"[dm] DualSense R2: preloaded progressive bow resistance enabled\n");
    if (left && dm_adaptive_shield_sample)
        fprintf(stderr,"[dm] DualSense L2: game-driven shield resistance enabled\n");
}
int dm_adaptive_trigger_available(void) { return !g_closed && ((g_right_trigger && dm_adaptive_trigger_sample) || (g_left_trigger && dm_adaptive_shield_sample)); }
void dm_adaptive_trigger_set_active(int active) {
    g_active = !!active;
    if (!g_active) reset_pull();
}
void dm_adaptive_trigger_tick(uint64_t now) {
    if (!g_active || !dm_adaptive_trigger_available()) return;
    if (g_sampled && now >= g_sampled && now - g_sampled < 20000000ull) return;
    // Cap the ramp after a scheduling gap; never jump straight to full load.
    float dt = g_sampled && now >= g_sampled ? fminf((now-g_sampled)*1e-9f,.05f) : 0;
    g_sampled = now;
    shield_tick(now);
    if (!g_right_trigger || !dm_adaptive_trigger_sample) return;
    dm_bow_snapshot bow = dm_adaptive_trigger_sample();
    float travel = g_right_trigger.value;
    int released = isfinite(travel) && travel <= .02f;
    int valid = bow.phase >= DM_BOW_READY && bow.phase <= DM_BOW_DRAW &&
                isfinite(bow.charge) && bow.charge >= 0 && bow.charge <= 1 && isfinite(travel);
    int replaced = g_previous.phase && (bow.player != g_previous.player ||
                   bow.bow != g_previous.bow || bow.generation != g_previous.generation);
    int cancelled = bow.phase == DM_BOW_READY &&
                    (g_previous.phase == DM_BOW_DRAW || g_previous.phase == DM_BOW_RELOAD);
    // Idle and damage both use READY. A cancelled pull must be released before
    // idle preloading can resume; a stale charge must never revive its effect.
    if (!valid || replaced || cancelled) { trigger_off(); g_rearm = 1; }
    g_previous = bow;
    if (!valid) return;
    if (released) { g_rearm = 0; g_charge = 0; }
    if (g_rearm) return;

    // Preload before the digital ZR threshold and the game's reload animation.
    // The controller supplies the position slope locally; analog movement does
    // not generate device writes. Only actual game charge modulates its weight.
    float target = !released && bow.phase == DM_BOW_DRAW ? bow.charge : 0;
    if (target <= g_charge) g_charge = target;
    else g_charge = fminf(target, g_charge + 2.f * dt);
    int level = (int)floorf(g_charge * 32.f + .0001f);
    if (level == g_sent) return;
    float q = level / 32.f;
    // Full travel avoids the old 15% dead zone and the release beyond 85%.
    // Keep slope feedback throughout the pull; do not stop/restart on updates.
    // Independent of DM_RUMBLE_GAIN (handle vibration).
    write_slope(1,(dm_trigger_slope){1,0,1,.10f + .05f*q,.35f + .20f*q});
    g_sent = level;
}
void dm_adaptive_trigger_shutdown(void) { reset_pull(); g_closed = 1; g_active = 0; g_right_trigger = nil; g_left_trigger = nil; }
