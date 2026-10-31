// Physical controllers for the windowed Mac frontend. Call on the main thread.
#pragma once
void dm_gamepad_mac_start(void);
void dm_gamepad_mac_set_active(int active);
int dm_gamepad_mac_is_dualsense(void);
// Once at startup, on the main thread: connected pads can arrive asynchronously
// after the registry's first query. Completes on discovery or after one second.
void dm_gamepad_mac_after_discovery(void (*ready)(void *), void *context);
