// Observe keyboard focus and visible-window controller eligibility independently.
// Retain the returned observer for as long as the window accepts input.
// It also serves as the game window's delegate for failed fullscreen transitions.
#pragma once
#import <Cocoa/Cocoa.h>
id dm_mac_input_watch(NSApplication *app, NSWindow *window, void (*changed)(int keyboard, int controller));
