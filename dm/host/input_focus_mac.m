#include "input_focus_mac.h"

@interface DmMacInputFocus : NSObject <NSWindowDelegate>
@property (weak) NSApplication *app;
@property (weak) NSWindow *window;
@property (copy) NSArray *tokens;
@property BOOL transitioning;
@property void (*changed)(int);
- (void)refresh;
- (void)refreshAfterEvent;
@end

@implementation DmMacInputFocus
- (void)refresh {
    NSWindow *window = self.window;
    BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    self.changed(self.app.active && window.keyWindow && !window.miniaturized && visible && !self.transitioning);
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
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    (void)window; self.transitioning = NO; [self refreshAfterEvent];
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
    (void)window; self.transitioning = NO; [self refreshAfterEvent];
}
@end

id dm_mac_input_watch(NSApplication *app, NSWindow *window, void (*changed)(int)) {
    DmMacInputFocus *watch = [DmMacInputFocus new];
    watch.app = app; watch.window = window; watch.changed = changed;
    __weak DmMacInputFocus *weak = watch;
    NSMutableArray *tokens = [NSMutableArray array];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
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
    watch.tokens = tokens;
    window.delegate = watch;
    [watch refreshAfterEvent];
    return watch;
}
