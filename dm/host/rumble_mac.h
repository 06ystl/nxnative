// macOS controller feedback. Selection and focus are driven by gamepad_mac.m.
#pragma once
#ifdef __OBJC__
@class GCController;
void dm_rumble_mac_attach(GCController *controller);
#endif
void dm_rumble_mac_start(void);
void dm_rumble_mac_set_active(int active);
void dm_rumble_mac_shutdown(void);
