// One physical Mac controller -> the host's independent dm_pad_set input channel.
// Keyboard input stays on dm_input_set; hle_hid merges both when the game reads it.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "dm_input.h"
#include "gamepad_mac.h"
#include "rumble_mac.h"

static GCController *g_mac_controller;
static GCExtendedGamepad *g_mac_profile;
static int g_mac_input_active, g_mac_scripted;

static void pad_axes(GCControllerDirectionPad *stick, int32_t *x, int32_t *y) {
    float sx = fmaxf(-1, fminf(1, stick.xAxis.value));
    float sy = fmaxf(-1, fminf(1, stick.yAxis.value));
    if (sx * sx + sy * sy <= 0.12f * 0.12f) sx = sy = 0;
    *x = (int32_t)(sx * DM_STICK_MAX); *y = (int32_t)(sy * DM_STICK_MAX);
}

static void pad_read(GCExtendedGamepad *g) {
    if (!g_mac_input_active || !g) { dm_pad_set(0, 0, 0, 0, 0); return; }
    uint64_t buttons = 0;
#define KEY(button, bit) if (button.isPressed) buttons |= bit
    // GameController already normalizes Nintendo face buttons by letter. Like
    // d2r-mobile, preserve these names instead of swapping Nintendo twice.
    KEY(g.buttonA, DM_BTN_A); KEY(g.buttonB, DM_BTN_B);
    KEY(g.buttonX, DM_BTN_X); KEY(g.buttonY, DM_BTN_Y);
    KEY(g.leftShoulder, DM_BTN_L); KEY(g.rightShoulder, DM_BTN_R);
    KEY(g.leftTrigger, DM_BTN_ZL); KEY(g.rightTrigger, DM_BTN_ZR);
    KEY(g.buttonMenu, DM_BTN_PLUS); KEY(g.buttonOptions, DM_BTN_MINUS);
    KEY(g.leftThumbstickButton, DM_BTN_LS); KEY(g.rightThumbstickButton, DM_BTN_RS);
    KEY(g.dpad.left, DM_BTN_LEFT); KEY(g.dpad.up, DM_BTN_UP);
    KEY(g.dpad.right, DM_BTN_RIGHT); KEY(g.dpad.down, DM_BTN_DOWN);
#undef KEY
    int32_t lx, ly, rx, ry;
    pad_axes(g.leftThumbstick, &lx, &ly); pad_axes(g.rightThumbstick, &rx, &ry);
    dm_pad_set(buttons, lx, ly, rx, ry);
}

static void pad_select(NSArray<GCController *> *controllers) {
    GCController *next = nil;
    // Keep the current 1P controller when a second one connects. After disconnect,
    // use the next extended gamepad, matching the host's single-player contract.
    if (g_mac_controller && [controllers containsObject:g_mac_controller]) next = g_mac_controller;
    else for (GCController *c in controllers) if (c.extendedGamepad) { next = c; break; }
    GCExtendedGamepad *profile = next.extendedGamepad;
    BOOL changed = next != g_mac_controller || profile != g_mac_profile;
    if (changed) {
        g_mac_profile.valueChangedHandler = nil;
        dm_pad_set(0, 0, 0, 0, 0);
        g_mac_controller = next;
        g_mac_profile = profile;
        dm_rumble_mac_attach(next);
    }
    if (next) {
        // Rebind even for the same device: foreground changes can replace its
        // input profile or leave its previous callback detached.
        next.handlerQueue = dispatch_get_main_queue();
        profile.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *element) {
            (void)element;
            if (g == g_mac_profile) pad_read(g);
        };
        if (changed)
            fprintf(stderr, "[dm] Mac controller connected: %s (%s), system A/B/X/Y mapping\n",
                    next.vendorName.UTF8String ?: "Unknown", next.productCategory.UTF8String ?: "Unknown");
    } else if (changed) fprintf(stderr, "[dm] Mac controller disconnected; keyboard remains available\n");
    pad_read(g_mac_profile);
}

void dm_gamepad_mac_start(void) {
    static int started; if (started++) return;
    dm_rumble_mac_start();
    // macOS otherwise stops delivering events as soon as another app activates.
    // Window/session eligibility still gates pad_read, motion and rumble.
    GCController.shouldMonitorBackgroundEvents = YES;
    // DM_KEYS owns dm_pad_set during diagnostic replays, including windowed runs.
    const char *script = getenv("DM_KEYS"); g_mac_scripted = script && *script;
    if (g_mac_scripted) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; pad_select(GCController.controllers);
        }];
    pad_select(GCController.controllers);
    if (!g_mac_controller) fprintf(stderr, "[dm] Mac controller: waiting for an extended gamepad\n");
}

void dm_gamepad_mac_set_active(int active) {
    if (g_mac_scripted) return;
    g_mac_input_active = !!active;
    dm_rumble_mac_set_active(active);
    if (g_mac_input_active) pad_select(GCController.controllers);
    else pad_read(nil);
}
