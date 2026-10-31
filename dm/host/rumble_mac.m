// Switch vibration -> GameController/Core Haptics. Adapted from MacNativeGames
// gamepad_feedback.m at f5cc1519 (MIT; dm/third_party/macnativegames/LICENSE).
// Guest threads only publish the latest value. All haptic objects belong to one
// serial queue, sampled at 100 Hz independently of rendering. Values persist
// until replaced, as on Switch HID; window ineligibility, detach and shutdown clear them.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include "dm_input.h"
#include "hle_haptics.h"
#include "rumble_mac.h"
#include "adaptive_trigger_mac.h"
#include "audio_sources_mac.h"
#include "audio_haptics_usb_mac.h"

enum { RUMBLE_TICK_MS = 10, RUMBLE_EVENT_S = 30, RUMBLE_RENEW_S = 25, RUMBLE_RETRY_S = 5 };
static dispatch_queue_t g_rumble_queue;
static dispatch_source_t g_rumble_timer;
static char g_rumble_queue_key;
static GCController *g_rumble_controller;
static GCDeviceHaptics *g_rumble_haptics;
static int g_rumble_active, g_rumble_closed, g_rumble_split, g_rumble_xbox;
static CHHapticEngine *g_rumble_engines[2];
static id<CHHapticPatternPlayer> g_rumble_players[2];
static CHHapticPattern *g_rumble_pattern;
static uint64_t g_rumble_retry[2], g_rumble_started[2];
static float g_rumble_intensity[2] = {-1,-1}, g_rumble_sharpness[2] = {-1,-1};
static float g_rumble_gain = 1;
static int g_audio_haptics;
static uint64_t g_audio_retry;
static void audio_submit(const float *pcm, unsigned frames) {
    size_t queued = dm_haptic_usb_enqueue(pcm, frames);
    static int reported;
    if (!reported && queued) {
        float peak = 0;
        for (size_t i = 0; i < queued * 2; i++) peak = fmaxf(peak, fabsf(pcm[i]));
        if (peak > 0) {
            fprintf(stderr,"[dm] Audio haptics: selected game PCM reached USB queue (input peak %.6f)\n",peak);
            reported = 1;
        }
    }
}
static void audio_close(void) {
    dm_audio_sources_set_active(0);
    dm_adaptive_trigger_set_usb_output(NULL);
    if (g_audio_haptics) {
        dm_haptic_usb_stats s = dm_haptic_usb_get_stats();
        fprintf(stderr,"[dm] Audio haptics output: callbacks %u, queued %u frames, signal %u frames, input peak %.6f, USB peak %.6f, layout errors %u, dropped %u frames\n",
                s.callbacks,s.queued_frames,s.signal_frames,s.input_peak,s.output_peak,s.layout_errors,s.dropped_frames);
        dm_haptic_usb_close();
    }
    g_audio_haptics = 0;
}
static void audio_open(void) { // rumble queue; only the selected, unique DualSense
    if (!dm_audio_sources_configured() || ![g_rumble_controller.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) return;
    unsigned count = 0;
    for (GCController *c in GCController.controllers) if ([c.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) count++;
    if (count != 1) return;
    g_audio_haptics = dm_haptic_usb_open();
    if(g_audio_haptics){
        dm_adaptive_trigger_set_usb_output(dm_haptic_usb_set_trigger);
        if(dm_haptic_usb_ready())fprintf(stderr,"[dm] Audio haptics: R2/L2 share the USB report owner\n");
    }
    fprintf(stderr,"[dm] Audio haptics: %s%s\n",dm_haptic_usb_status(),g_audio_haptics ? "" : "; using game rumble");
}
static pthread_mutex_t g_rumble_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_rumble_accepting;
static dm_vibration_value g_rumble_want[2] = {{0,160,0,320}, {0,160,0,320}};

static float rumble_read_gain(void) {
    const char *text = getenv("DM_RUMBLE_GAIN");
    if (!text) return 1;
    char *end;
    float gain = strtof(text, &end);
    if (end == text || *end || !isfinite(gain) || gain < 0) {
        fprintf(stderr,"【红】DM_RUMBLE_GAIN=%s: must be finite and nonnegative; using 1\n",text);
        return 1;
    }
    fprintf(stderr,"[dm] Mac rumble gain: %.2fx (DM_RUMBLE_GAIN)\n",gain);
    return gain;
}
static float audio_read_gain(void) {
    const char *text = getenv("DM_AUDIO_HAPTICS_GAIN");
    if (!text) return .3f;
    char *end;
    float gain = strtof(text, &end);
    if (end == text || *end || !isfinite(gain) || gain < 0) {
        fprintf(stderr,"【红】DM_AUDIO_HAPTICS_GAIN must be finite and nonnegative; using 0.3\n");
        return .3f;
    }
    return gain;
}

static void rumble_sync(dispatch_block_t block) {
    if (dispatch_get_specific(&g_rumble_queue_key)) block();
    else dispatch_sync(g_rumble_queue, block);
}
static void rumble_clear_want(void) { // g_rumble_mu held
    g_rumble_want[0] = g_rumble_want[1] = (dm_vibration_value){0,160,0,320};
}
static void rumble_send(unsigned side, const dm_vibration_value *v) {
    if (side > 1) return;
    pthread_mutex_lock(&g_rumble_mu);
    if (g_rumble_accepting) g_rumble_want[side] = *v;
    pthread_mutex_unlock(&g_rumble_mu);
}
// Shared HID owns accepted per-player values. Keep the existing Mac output
// adapter and publish only changed motors, under the shared state's ordering.
static void rumble_snapshot(dm_haptic_state state) {
    static dm_vibration_value previous[2];
    static int initialized;
    if (state.player || !dm_vibration_send) return;
    for (unsigned side=0;side<2;side++) {
        if (!initialized || memcmp(&previous[side],&state.motor[side],sizeof previous[side]))
            dm_vibration_send(side,&state.motor[side]);
        previous[side]=state.motor[side];
    }
    initialized=1;
}
static void rumble_drop_engine(unsigned side) { // rumble queue
    CHHapticEngine *engine = g_rumble_engines[side];
    engine.resetHandler = ^{}; engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; };
    [engine stopWithCompletionHandler:nil];
    g_rumble_engines[side] = nil;
}
static void rumble_stop_player(unsigned side) { // rumble queue
    NSError *error = nil;
    if (g_rumble_players[side] && ![g_rumble_players[side] stopAtTime:CHHapticTimeImmediate error:&error]) {
        fprintf(stderr,"【红】Mac rumble: stop player failed: %s; stopping its engine\n",error.localizedDescription.UTF8String ?: "unknown error");
        rumble_drop_engine(side);
    }
    g_rumble_players[side] = nil;
    g_rumble_started[side] = 0;
    g_rumble_intensity[side] = g_rumble_sharpness[side] = -1;
}
static void rumble_retire(unsigned side) { // rumble queue
    rumble_stop_player(side);
    rumble_drop_engine(side);
}
static void rumble_failed(unsigned side, const char *operation, NSError *error) {
    fprintf(stderr, "【红】Mac rumble %s: %s failed: %s; retry in 5 s\n", side ? "right" : "left/default",
            operation, error.localizedDescription.UTF8String ?: "haptic engine unavailable");
    rumble_retire(side);
    g_rumble_retry[side] = clock_gettime_nsec_np(CLOCK_MONOTONIC) + RUMBLE_RETRY_S * 1000000000ull;
}
static int rumble_engine(unsigned side) { // rumble queue
    if (g_rumble_engines[side]) return 1;
    if (!g_rumble_haptics) return 0;
    GCHapticsLocality locality = g_rumble_split ? (side ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle) : GCHapticsLocalityDefault;
    CHHapticEngine *engine = [g_rumble_haptics createEngineWithLocality:locality];
    if (!engine) { rumble_failed(side,"create engine",nil); return 0; }
    NSError *error = nil;
    if (![engine startAndReturnError:&error]) { [engine stopWithCompletionHandler:nil]; rumble_failed(side,"start engine",error); return 0; }
    g_rumble_engines[side] = engine;
    __weak CHHapticEngine *weakEngine = engine;
    void (^reset)(void) = ^{
        dispatch_async(g_rumble_queue, ^{
            // A delayed callback from a retired controller must not reset its replacement.
            CHHapticEngine *old = weakEngine;
            if (old && g_rumble_engines[side] == old) rumble_retire(side);
        });
    };
    engine.resetHandler = reset;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; reset(); };
    return 1;
}
static float rumble_energy(dm_vibration_value v) {
    return v.amplitude_low * v.amplitude_low + v.amplitude_high * v.amplitude_high;
}
static float rumble_sharpness(dm_vibration_value v) {
    float weight = v.amplitude_low + v.amplitude_high;
    if (weight <= 0) return 0.5f;
    float frequency = (v.amplitude_low * v.frequency_low + v.amplitude_high * v.frequency_high) / weight;
    frequency = fmaxf(40, fminf(1250, frequency));
    return log2f(frequency / 40) / log2f(1250.0f / 40);
}
static int rumble_params(unsigned side, id<CHHapticPatternPlayer> player, float intensity, float sharpness) {
    CHHapticDynamicParameter *i = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0];
    CHHapticDynamicParameter *s = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness - 0.5f relativeTime:0];
    NSError *error = nil;
    if (![player sendParameters:@[i,s] atTime:CHHapticTimeImmediate error:&error]) { rumble_failed(side,"update player",error); return 0; }
    g_rumble_intensity[side] = intensity; g_rumble_sharpness[side] = sharpness;
    return 1;
}
static void rumble_play(unsigned side, dm_vibration_value value, uint64_t now) { // rumble queue
    float intensity = fminf(1, sqrtf(rumble_energy(value)));
    // Captured short HD-rumble ramps were imperceptible on Xbox at the linear
    // level. This response made the same waveform perceptible without extending it.
    if (g_rumble_xbox) intensity = sqrtf(intensity);
    intensity = fminf(1, g_rumble_gain * intensity);
    if (intensity <= 0) { rumble_stop_player(side); return; }
    if (now < g_rumble_retry[side] || !rumble_engine(side)) return;
    float sharpness = rumble_sharpness(value);
    NSError *error = nil;
    if (!g_rumble_pattern) {
        CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1];
        CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f];
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[i,s] relativeTime:0 duration:RUMBLE_EVENT_S];
        g_rumble_pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!g_rumble_pattern) { rumble_failed(side,"create pattern",error); return; }
    }
    // Ordinary continuous players avoid the advanced-player compatibility issue
    // recorded in MacNativeGames. Renew before the finite event expires.
    if (!g_rumble_players[side] || now - g_rumble_started[side] >= RUMBLE_RENEW_S * 1000000000ull) {
        if (g_rumble_players[side]) {
            rumble_stop_player(side);
            if (!g_rumble_engines[side]) return; // A failed stop retired this engine; rebuild on the next tick.
        }
        id<CHHapticPatternPlayer> player = [g_rumble_engines[side] createPlayerWithPattern:g_rumble_pattern error:&error];
        if (!player) { rumble_failed(side,"create player",error); return; }
        // Set strength before starting; never start with the pattern's full intensity.
        if (!rumble_params(side,player,intensity,sharpness)) return;
        if (![player startAtTime:CHHapticTimeImmediate error:&error]) { rumble_failed(side,"start player",error); return; }
        g_rumble_players[side] = player; g_rumble_started[side] = now;
    } else if (intensity != g_rumble_intensity[side] || sharpness != g_rumble_sharpness[side])
        rumble_params(side,g_rumble_players[side],intensity,sharpness);
}
static int audio_candidate(void) {
    return dm_audio_sources_configured() &&
           [g_rumble_controller.extendedGamepad isKindOfClass:GCDualSenseGamepad.class];
}
static void rumble_accept_at(uint64_t now);
static void rumble_accept(void) { rumble_accept_at(clock_gettime_nsec_np(CLOCK_MONOTONIC)); }
static void rumble_tick(uint64_t now) { // rumble queue
    dm_adaptive_trigger_tick(now);
    if (g_audio_haptics && !dm_haptic_usb_ready()) {
        audio_close(); g_audio_retry = now + RUMBLE_RETRY_S * 1000000000ull;
        fprintf(stderr,"[dm] Audio haptics: USB disconnected; using game rumble\n");
        rumble_accept_at(now);
    }
    if (g_rumble_active && !g_rumble_closed && !g_audio_haptics && audio_candidate() && now >= g_audio_retry)
        rumble_accept_at(now);
    if (!g_rumble_active || g_rumble_closed || g_audio_haptics || !g_rumble_haptics) return;
    dm_vibration_value values[2];
    pthread_mutex_lock(&g_rumble_mu); memcpy(values,g_rumble_want,sizeof values); pthread_mutex_unlock(&g_rumble_mu);
    if (g_rumble_split) { rumble_play(0,values[0],now); rumble_play(1,values[1],now); }
    else {
        // Default-only devices get one engine and the stronger side. Two engines
        // on the same motors would interfere when the other game side stops.
        unsigned side = rumble_energy(values[1]) > rumble_energy(values[0]);
        rumble_play(0,values[side],now);
    }
}
static void rumble_accept_at(uint64_t now) { // rumble queue
    int eligible = g_rumble_active && !g_rumble_closed;
    // Stop ordinary engines before restoring the device audio mode.
    if (eligible && !g_audio_haptics && audio_candidate() && now >= g_audio_retry) {
        for (unsigned s = 0; s < 2; s++) rumble_retire(s);
        audio_open();
        g_audio_retry = now + RUMBLE_RETRY_S * 1000000000ull;
    }
    dm_haptic_usb_set_active(eligible && g_audio_haptics);
    dm_audio_sources_set_active(eligible && g_audio_haptics);
    int on = eligible && !g_audio_haptics && g_rumble_haptics != nil;
    pthread_mutex_lock(&g_rumble_mu); g_rumble_accepting = on; if (!on) rumble_clear_want(); pthread_mutex_unlock(&g_rumble_mu);
    if (!on) for (unsigned s = 0; s < 2; s++) rumble_retire(s);
    int tick = g_rumble_active && !g_rumble_closed && (g_rumble_haptics || dm_adaptive_trigger_available() || audio_candidate());
    if (g_rumble_timer) dispatch_source_set_timer(g_rumble_timer, tick ? dispatch_time(DISPATCH_TIME_NOW,0) : DISPATCH_TIME_FOREVER,
                                                  RUMBLE_TICK_MS * NSEC_PER_MSEC, NSEC_PER_MSEC);
}
void dm_rumble_mac_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_rumble_gain = rumble_read_gain();
        dm_audio_sources_submit = audio_submit;
        float gain = audio_read_gain();
        dm_haptic_usb_set_gain(gain);
        if (dm_audio_sources_configured()) fprintf(stderr,"[dm] Audio haptics gain: %.2fx (DM_AUDIO_HAPTICS_GAIN; PCM full scale +/-1)\n",gain);
        g_rumble_queue = dispatch_queue_create("dm.controller.rumble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(g_rumble_queue,&g_rumble_queue_key,&g_rumble_queue_key,NULL);
#ifndef DM_RUMBLE_TEST
        g_rumble_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,g_rumble_queue);
        dispatch_source_set_timer(g_rumble_timer,DISPATCH_TIME_FOREVER,RUMBLE_TICK_MS*NSEC_PER_MSEC,NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_rumble_timer, ^{ @autoreleasepool { rumble_tick(clock_gettime_nsec_np(CLOCK_MONOTONIC)); } });
        dispatch_resume(g_rumble_timer);
#endif
        dm_vibration_send = rumble_send;
        dm_vibration_shutdown = dm_rumble_mac_shutdown;
        dm_haptics_init(rumble_snapshot,1);
        dm_haptics_route(0,1);
        atexit(dm_rumble_mac_shutdown);
    });
}
void dm_rumble_mac_attach(GCController *controller) {
    dm_rumble_mac_start();
    GCDeviceHaptics *haptics = controller.haptics;
    NSSet *localities = haptics.supportedLocalities;
    rumble_sync(^{
        dm_adaptive_trigger_attach(controller);
        if (g_rumble_controller == controller && g_rumble_haptics == haptics) { rumble_accept(); return; }
        audio_close(); g_audio_retry = 0;
        for (unsigned s = 0; s < 2; s++) { rumble_retire(s); g_rumble_retry[s] = 0; }
        dm_haptics_clear(0);
        pthread_mutex_lock(&g_rumble_mu); rumble_clear_want(); pthread_mutex_unlock(&g_rumble_mu);
        g_rumble_controller = controller; g_rumble_haptics = haptics;
        g_rumble_xbox = [controller.productCategory isEqualToString:GCProductCategoryXboxOne];
        g_rumble_split = [localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle];
        rumble_accept();
        if (controller) fprintf(stderr,"[dm] Mac rumble: %s; %s\n",controller.vendorName.UTF8String ?: "controller",
                                haptics ? (g_rumble_split ? "independent left/right handles" : "shared default haptics") : "haptics unavailable on this connection");
    });
}
void dm_rumble_mac_set_active(int active) {
    dm_rumble_mac_start();
    rumble_sync(^{ g_rumble_active = !!active; dm_adaptive_trigger_set_active(active); rumble_accept(); });
    dm_haptics_suspend(DM_HAPTICS_INACTIVE,!active);
}
void dm_rumble_mac_shutdown(void) {
    if (!g_rumble_queue) return;
    rumble_sync(^{
        dm_adaptive_trigger_shutdown();
        audio_close();
        g_rumble_closed = 1; rumble_accept();
        g_rumble_haptics = nil; g_rumble_controller = nil;
    });
}
