// macOS controller feedback. Selection and focus are driven by gamepad_mac.m.
#pragma once
#ifdef __OBJC__
@class GCController;
void dm_rumble_mac_attach(GCController *controller);
#endif
void dm_rumble_mac_start(void);
void dm_rumble_mac_set_active(int active);
void dm_rumble_mac_shutdown(void);

// UI calls are serialized with the existing output owner. No hardware work on the UI thread.
typedef struct {
    float rumble,audio,trigger;
    int connected,audio_ready,triggers,previewing;
    char controller[160];
} dm_feedback_mac_status;
dm_feedback_mac_status dm_rumble_mac_get_status(void);
void dm_rumble_mac_set_levels(float rumble,float audio,float trigger);
int dm_rumble_mac_preview(void);
void dm_rumble_mac_stop_preview(void);
