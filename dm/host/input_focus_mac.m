#include "input_focus_mac.h"

static __weak NSWindow *g_settings_window;
void dm_mac_input_settings_window(NSWindow *window) { g_settings_window=window; }

@interface DmMacInputFocus : NSObject <NSWindowDelegate>
@property (weak) NSApplication *app;
@property (weak) NSWindow *window;
@property (copy) NSArray *tokens;
@property (copy) NSArray *workspaceTokens;
@property BOOL transitioning;
@property BOOL sessionInactive;
@property BOOL displaysAsleep;
@property BOOL closed;
@property void (*changed)(int, int);
- (void)refresh;
- (void)refreshAfterEvent;
@end

@implementation DmMacInputFocus
- (void)refresh {
    NSWindow *window = self.window;
    BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0 ||
                   (g_settings_window.keyWindow && self.app.active && window.visible);
    BOOL available = visible && !window.miniaturized && !self.app.hidden && !self.app.modalWindow && !self.transitioning &&
                     !self.sessionInactive && !self.displaysAsleep && !self.closed;
    BOOL keyboard = available && self.app.active && window.keyWindow;
    // A visible game on another display accepts its controller while a browser
    // is frontmost. An app-owned dialog still excludes gameplay behind it.
    BOOL controller = available && (!self.app.active || window.keyWindow || g_settings_window.keyWindow);
    self.changed(keyboard, controller);
}
- (void)refreshAfterEvent {
    [self refresh];
    // Activation and fullscreen notifications can precede the final key-window
    // state. Sample again after AppKit completes the current event.
    __weak DmMacInputFocus *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak refresh]; });
}
- (void)dealloc {
    for (id token in self.tokens) [NSNotificationCenter.defaultCenter removeObserver:token];
    for (id token in self.workspaceTokens) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:token];
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    (void)window; self.transitioning = NO; [self refreshAfterEvent];
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
    (void)window; self.transitioning = NO; [self refreshAfterEvent];
}
@end

id dm_mac_input_watch(NSApplication *app, NSWindow *window, void (*changed)(int, int)) {
    DmMacInputFocus *watch = [DmMacInputFocus new];
    watch.app = app; watch.window = window; watch.changed = changed;
    __weak DmMacInputFocus *weak = watch;
    NSMutableArray *tokens = [NSMutableArray array];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
                                     NSApplicationDidHideNotification, NSApplicationDidUnhideNotification,
                                     NSApplicationDidChangeScreenParametersNotification])
        [tokens addObject:[nc addObserverForName:name object:app queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; [weak refreshAfterEvent];
        }]];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                     NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
                                     NSWindowDidChangeOcclusionStateNotification, NSWindowDidChangeScreenNotification])
        [tokens addObject:[nc addObserverForName:name object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; [weak refreshAfterEvent];
        }]];
    for (NSNotificationName name in @[NSWindowWillEnterFullScreenNotification, NSWindowWillExitFullScreenNotification])
        [tokens addObject:[nc addObserverForName:name object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; weak.transitioning = YES; [weak refresh];
        }]];
    for (NSNotificationName name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification])
        [tokens addObject:[nc addObserverForName:name object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; weak.transitioning = NO; [weak refreshAfterEvent];
        }]];
    [tokens addObject:[nc addObserverForName:NSWindowWillCloseNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; weak.closed = YES; [weak refresh];
    }]];
    watch.tokens = tokens;
    NSMutableArray *workspaceTokens = [NSMutableArray array];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceSessionDidBecomeActiveNotification])
        [workspaceTokens addObject:[workspace addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            weak.sessionInactive = [note.name isEqualToString:NSWorkspaceSessionDidResignActiveNotification];
            [weak refreshAfterEvent];
        }]];
    for (NSNotificationName name in @[NSWorkspaceScreensDidSleepNotification, NSWorkspaceScreensDidWakeNotification])
        [workspaceTokens addObject:[workspace addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            weak.displaysAsleep = [note.name isEqualToString:NSWorkspaceScreensDidSleepNotification];
            [weak refreshAfterEvent];
        }]];
    watch.workspaceTokens = workspaceTokens;
    window.delegate = watch;
    [watch refreshAfterEvent];
    return watch;
}
