#pragma once
#import <Cocoa/Cocoa.h>
// Main-thread native settings. Runtime changes go through each subsystem's owner.
void dm_settings_mac_start(NSWindow *game);
int dm_settings_mac_interacting(void);
