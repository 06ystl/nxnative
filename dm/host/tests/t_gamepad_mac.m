// Apple snapshot controllers exercise the real Mac callback -> GetNpadState path.
// No physical device, game files, UI events or application window is required.
#include "../gamepad_mac.m"
#include "../input_focus_mac.m"
#include "../hle_hid.c"
#import <objc/runtime.h>

// Snapshot controllers are not in Apple's physical-device registry. Replace only
// that lookup; the production selection, callbacks and HID reads stay in use.
static NSArray<GCController *> *connected;
static NSArray *test_controllers(id cls, SEL sel) { (void)cls; (void)sel; return connected; }

@interface TestMacApp : NSObject
@property (getter=isActive) BOOL active;
@property (getter=isHidden) BOOL hidden;
@property NSWindow *modalWindow;
@end
@implementation TestMacApp
@end
@interface TestMacWindow : NSObject
@property (getter=isKeyWindow) BOOL keyWindow;
@property (getter=isMiniaturized) BOOL miniaturized;
@property NSWindowOcclusionState occlusionState;
@property (weak) id<NSWindowDelegate> delegate;
@end
@implementation TestMacWindow
@end

uint64_t dm_guest_frame(void) { return 0; }
int dm_opmode(void) { return 1; }
void hle_bind_system_event(void *event, int autoclear) { (void)event; (void)autoclear; }
void hle_signal_system_event(void *event) { (void)event; }

static int checks, fails;
static int keyboard_enabled;
static void discovered(void *context) { (*(int *)context)++; }
static void input_changed(int keyboard, int controller) {
    keyboard_enabled = keyboard;
    dm_gamepad_mac_set_active(controller);
}
#define CHECK(c, message) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); } } while (0)
static NpadState sample(void) { NpadState s; uint32_t id = 0; h_hid_StateFullKey(&s, &id); return s; }
static void changed(GCExtendedGamepad *g) {
    if (g.valueChangedHandler) g.valueChangedHandler(g, g.buttonA);
}
static uint64_t buttons(void) { return sample().buttons & 0xffff; }
static void notify(NSString *name, id object) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:object];
}
static void settle(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!done && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:limit];
    CHECK(done, "queued AppKit state refresh completes");
}

int main(void) {
    @autoreleasepool {
        unsetenv("DM_KEYS");
        GCController *first = [GCController controllerWithExtendedGamepad];
        GCController *second = [GCController controllerWithExtendedGamepad];
        connected = @[first];
        Method registry = class_getClassMethod(GCController.class, @selector(controllers));
        IMP original = method_setImplementation(registry, (IMP)test_controllers);
        GCExtendedGamepad *g = first.extendedGamepad;
        CHECK(g != nil && second.extendedGamepad != nil, "Apple extended snapshot profiles exist");
        dm_gamepad_mac_set_active(1);
        [g.buttonA setValue:1];
        pad_select(@[first]);
        CHECK(!dm_gamepad_mac_is_dualsense(), "an extended profile alone does not identify a DualSense");
        CHECK(buttons() == DM_BTN_A, "already-connected controller publishes its held buttons immediately");
        [g.buttonA setValue:0]; changed(g);
        CHECK(buttons() == 0, "face button release reaches the game");

        struct { GCControllerButtonInput *button; uint64_t expected; } mapping[] = {
            {g.buttonA, DM_BTN_A}, {g.buttonB, DM_BTN_B}, {g.buttonX, DM_BTN_X}, {g.buttonY, DM_BTN_Y},
            {g.leftShoulder, DM_BTN_L}, {g.rightShoulder, DM_BTN_R},
            {g.leftTrigger, DM_BTN_ZL}, {g.rightTrigger, DM_BTN_ZR},
            {g.buttonMenu, DM_BTN_PLUS}, {g.buttonOptions, DM_BTN_MINUS},
            {g.leftThumbstickButton, DM_BTN_LS}, {g.rightThumbstickButton, DM_BTN_RS}
        };
        for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++) {
            CHECK(mapping[i].button != nil, "snapshot exposes every supported button");
            [mapping[i].button setValue:1]; changed(g);
            uint64_t got = buttons();
            if (got != mapping[i].expected) fprintf(stderr, "button %u: expected %#llx, got %#llx\n", i, (unsigned long long)mapping[i].expected, (unsigned long long)got);
            CHECK(got == mapping[i].expected, "mapped press reaches GetNpadState");
            [mapping[i].button setValue:0]; changed(g);
            CHECK(buttons() == 0, "mapped release reaches GetNpadState");
        }
        // Snapshot D-pad buttons are derived from its axes, rather than setValue
        // on the individual direction buttons (which Apple ignores).
        struct { float x, y; uint64_t expected; } dpad[] = {
            {-1, 0, DM_BTN_LEFT}, {0, 1, DM_BTN_UP}, {1, 0, DM_BTN_RIGHT},
            {0, -1, DM_BTN_DOWN}, {1, 1, DM_BTN_RIGHT | DM_BTN_UP}
        };
        for (unsigned i = 0; i < sizeof dpad / sizeof *dpad; i++) {
            [g.dpad setValueForXAxis:dpad[i].x yAxis:dpad[i].y]; changed(g);
            CHECK(buttons() == dpad[i].expected, "D-pad axes publish the correct direction buttons");
            [g.dpad setValueForXAxis:0 yAxis:0]; changed(g);
            CHECK(buttons() == 0, "D-pad release reaches the guest");
        }
        [g.leftThumbstick setValueForXAxis:0.5f yAxis:-1];
        [g.rightThumbstick setValueForXAxis:-1 yAxis:0.25f]; changed(g);
        NpadState s = sample();
        CHECK(s.lx == 16383 && s.ly == -32767 && s.rx == -32767 && s.ry == 8191, "both analog sticks reach the guest with correct signs and scale");
        [g.leftThumbstick setValueForXAxis:0.05f yAxis:-0.04f]; changed(g);
        s = sample(); CHECK(s.lx == 0 && s.ly == 0, "small stick drift is neutral");

        dm_input_set(DM_BTN_Y, DM_STICK_MAX, 0, 0, 0);
        [g.buttonA setValue:1]; changed(g);
        s = sample();
        CHECK((s.buttons & 0xffff) == (DM_BTN_A | DM_BTN_Y), "keyboard and controller buttons are merged");
        CHECK(s.lx == DM_STICK_MAX && s.rx == -DM_STICK_MAX, "keyboard movement does not erase the controller's right stick");
        dm_input_set(0, 0, 0, 0, 0); sample();

        dm_gamepad_mac_set_active(0); s = sample();
        CHECK((s.buttons & 0xffff) == 0 && !s.lx && !s.ly && !s.rx && !s.ry, "ineligible window releases physical buttons and axes");
        [g.buttonB setValue:1]; changed(g);
        CHECK(buttons() == 0, "controller changes stay neutral while disabled");
        [g.buttonA setValue:0]; [g.buttonB setValue:0];
        [g.leftThumbstick setValueForXAxis:0 yAxis:0]; [g.rightThumbstick setValueForXAxis:0 yAxis:0];
        dm_gamepad_mac_set_active(1);
        CHECK(buttons() == 0, "focus regain samples current state instead of restoring stale presses");

        pad_select(@[first, second]);
        CHECK(g_mac_controller == first, "connecting a second pad keeps the active one");
        [g.buttonA setValue:1]; changed(g); sample();
        pad_select(@[]); s = sample();
        CHECK(g.valueChangedHandler == nil, "disconnect removes the old callback");
        CHECK((s.buttons & 0xffff) == 0 && !s.lx && !s.ly && !s.rx && !s.ry, "disconnect clears held input");
        pad_select(@[first]); CHECK(buttons() == DM_BTN_A, "reconnect resamples the controller");
        [second.extendedGamepad.buttonB setValue:1];
        pad_select(@[second]);
        CHECK(g_mac_controller == second && buttons() == DM_BTN_B, "active-pad disconnect selects and samples the remaining controller");
        CHECK(g.valueChangedHandler == nil, "switched-away controller cannot write input");
        pad_select(@[]); sample();

        connected = @[first];
        TestMacApp *app = [TestMacApp new]; app.active = YES;
        TestMacWindow *window = [TestMacWindow new]; window.keyWindow = YES;
        window.occlusionState = NSWindowOcclusionStateVisible;
        id watch = dm_mac_input_watch((NSApplication *)app, (NSWindow *)window, input_changed);
        CHECK(watch != nil, "focus watcher is retained for the game window's lifetime");
        settle();
        CHECK(buttons() == DM_BTN_A && keyboard_enabled, "foreground watcher enables keyboard and connected controller");

        app.active = NO; notify(NSApplicationDidResignActiveNotification, app);
        CHECK(buttons() == DM_BTN_A && !keyboard_enabled, "visible background game keeps its pad but disables keyboard input");
        window.keyWindow = NO; notify(NSWindowDidResignKeyNotification, window);
        [g.buttonA setValue:0];
        [g.rightThumbstick setValueForXAxis:-0.75f yAxis:0.5f]; changed(g);
        s = sample();
        CHECK((s.buttons & 0xffff) == 0 && s.rx == -24575 && s.ry == 16383, "background button release and right-stick motion reach GetNpadState");
        [g.rightThumbstick setValueForXAxis:0 yAxis:0];
        [g.buttonA setValue:1]; changed(g);
        g.valueChangedHandler = nil;
        window.keyWindow = YES;
        app.active = YES; notify(NSApplicationDidBecomeActiveNotification, app);
        CHECK(g.valueChangedHandler != nil && buttons() == DM_BTN_A, "Command-Tab back reinstalls a lost callback on the same pad");
        [g.buttonA setValue:0]; changed(g);
        CHECK(buttons() == 0, "rebound callback delivers subsequent releases");
        [g.buttonA setValue:1]; changed(g); sample();

        app.active = NO; window.keyWindow = NO;
        notify(NSApplicationDidResignActiveNotification, app);
        app.active = YES; notify(NSApplicationDidBecomeActiveNotification, app);
        CHECK(buttons() == 0 && !keyboard_enabled, "app-owned dialog or activation before key restoration stays neutral");
        window.keyWindow = YES; settle();
        CHECK(buttons() == DM_BTN_A && keyboard_enabled, "queued refresh observes AppKit's final key-window state");

        app.active = NO; window.keyWindow = NO;
        notify(NSApplicationDidResignActiveNotification, app);
        app.hidden = YES; notify(NSApplicationDidHideNotification, app);
        CHECK(buttons() == 0 && !keyboard_enabled, "hiding a background app clears input even before occlusion updates");
        [g.buttonA setValue:0]; changed(g);
        app.hidden = NO; notify(NSApplicationDidUnhideNotification, app);
        CHECK(buttons() == 0, "unhiding rereads releases instead of restoring stale buttons");
        [g.buttonA setValue:1]; changed(g);
        CHECK(buttons() == DM_BTN_A && !keyboard_enabled, "unhidden background game accepts controller without keyboard focus");
        app.modalWindow = (NSWindow *)window;
        notify(NSWindowDidResignKeyNotification, window);
        CHECK(buttons() == 0, "app modal dialog blocks gameplay even while the browser is frontmost");
        app.modalWindow = nil; notify(NSWindowDidBecomeKeyNotification, window);
        CHECK(buttons() == DM_BTN_A && !keyboard_enabled, "dismissing a modal restores background pad without enabling keyboard");

        NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
        [workspace postNotificationName:NSWorkspaceSessionDidResignActiveNotification object:nil];
        CHECK(buttons() == 0, "inactive user session clears a visible game's input");
        [workspace postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
        CHECK(buttons() == 0, "display wake cannot override an inactive session");
        [workspace postNotificationName:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
        CHECK(buttons() == DM_BTN_A && !keyboard_enabled, "session return restores visible background controller");
        [workspace postNotificationName:NSWorkspaceScreensDidSleepNotification object:nil];
        CHECK(buttons() == 0, "display sleep clears controller input");
        notify(NSApplicationDidBecomeActiveNotification, app);
        CHECK(buttons() == 0, "app notification cannot override display sleep");
        [workspace postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
        CHECK(buttons() == DM_BTN_A, "display wake resamples current controller state");

        window.occlusionState = 0; notify(NSWindowDidChangeOcclusionStateNotification, window);
        CHECK(buttons() == 0, "switching Spaces releases input when game becomes occluded");
        window.occlusionState = NSWindowOcclusionStateVisible;
        notify(NSWindowDidChangeOcclusionStateNotification, window);
        CHECK(buttons() == DM_BTN_A && !keyboard_enabled, "returning to a visible background Space restores only controller input");
        app.active = YES; window.keyWindow = YES;
        notify(NSApplicationDidBecomeActiveNotification, app);

        for (NSString *direction in @[@"enter", @"exit"]) {
            BOOL enter = [direction isEqualToString:@"enter"];
            notify(enter ? NSWindowWillEnterFullScreenNotification : NSWindowWillExitFullScreenNotification, window);
            CHECK(buttons() == 0, "fullscreen transition releases input");
            notify(NSWindowDidBecomeKeyNotification, window);
            CHECK(buttons() == 0, "intermediate key notifications cannot reactivate a fullscreen transition");
            notify(enter ? NSWindowDidEnterFullScreenNotification : NSWindowDidExitFullScreenNotification, window);
            CHECK(buttons() == DM_BTN_A, "fullscreen transition completion restores input");
            notify(enter ? NSWindowWillEnterFullScreenNotification : NSWindowWillExitFullScreenNotification, window);
            if (enter) [window.delegate windowDidFailToEnterFullScreen:(NSWindow *)window];
            else [window.delegate windowDidFailToExitFullScreen:(NSWindow *)window];
            CHECK(buttons() == DM_BTN_A, "failed fullscreen transition cannot leave input disabled");
        }
        window.miniaturized = YES; notify(NSWindowDidMiniaturizeNotification, window);
        CHECK(buttons() == 0, "minimizing clears input");
        window.miniaturized = NO; notify(NSWindowDidDeminiaturizeNotification, window);
        CHECK(buttons() == DM_BTN_A, "restoring window restores input");
        g.valueChangedHandler = nil; notify(NSWindowDidChangeScreenNotification, window);
        CHECK(g.valueChangedHandler != nil && buttons() == DM_BTN_A, "moving to another display rebinds controller");
        g.valueChangedHandler = nil; notify(NSApplicationDidChangeScreenParametersNotification, app);
        CHECK(g.valueChangedHandler != nil, "display configuration change rebinds controller");

        app.active = NO; window.keyWindow = NO; notify(NSApplicationDidResignActiveNotification, app);
        connected = @[second];
        notify(NSApplicationDidChangeScreenParametersNotification, app);
        CHECK(g_mac_controller == second && buttons() == DM_BTN_B && !keyboard_enabled, "visible background refresh discovers a replacement controller");
        CHECK(g.valueChangedHandler == nil, "background replacement detaches the old controller");
        notify(NSWindowWillCloseNotification, window);
        CHECK(buttons() == 0, "closing the game clears input before it disappears");
        notify(NSWindowDidChangeOcclusionStateNotification, window);
        CHECK(buttons() == 0, "later visibility notifications cannot reactivate a closed window");
        settle();
        watch = nil;
        CHECK(window.delegate == nil, "releasing focus watcher removes the window delegate");
        dm_gamepad_mac_set_active(0);
        notify(NSApplicationDidBecomeActiveNotification, app); settle();
        CHECK(buttons() == 0, "released watcher no longer handles notifications");

        pad_select(@[]); connected = @[];
        int ready = 0;
        dm_gamepad_mac_after_discovery(discovered, &ready);
        CHECK(ready == 0, "an initially empty registry waits for discovery before selecting cached UI");
        connected = @[first]; pad_select(connected);
        CHECK(ready == 1, "asynchronous initial controller discovery completes startup");
        pad_select(connected); pad_discovery_timeout();
        CHECK(ready == 1, "subsequent refresh and timeout cannot restart the guest");
        dm_gamepad_mac_after_discovery(discovered, &ready);
        CHECK(ready == 2, "an already discovered controller does not delay startup");
        connected = @[]; pad_select(connected);
        dm_gamepad_mac_after_discovery(discovered, &ready); pad_discovery_timeout();
        CHECK(ready == 3 && !dm_gamepad_mac_is_dualsense(), "keyboard-only startup completes with original prompts after discovery");

        dm_pad_set(DM_BTN_PLUS, 0, 0, 0, 0); sample();
        setenv("DM_KEYS", "0:Plus~10", 1);
        dm_gamepad_mac_start(); dm_gamepad_mac_set_active(0);
        CHECK(GCController.shouldMonitorBackgroundEvents, "Mac startup enables Apple's background event delivery");
        CHECK(buttons() == DM_BTN_PLUS, "windowed DM_KEYS replay retains ownership of the scripted input channel");
        method_setImplementation(registry, original);
        fprintf(stdout, "Mac controller: %d checks, %d failures\n", checks, fails);
        return fails != 0;
    }
}
