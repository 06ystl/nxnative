#pragma once
#include <stddef.h>
// A dedicated four-channel DualSense USB stream. These calls do not change the
// system's default audio device. Open/close/active belong to one control queue;
// enqueue has one producer and the AudioUnit callback is the only consumer.
int dm_haptic_usb_open(void);
void dm_haptic_usb_close(void);
void dm_haptic_usb_set_active(int active);
int dm_haptic_usb_ready(void);
void dm_haptic_usb_set_gain(float gain);
size_t dm_haptic_usb_enqueue(const float *stereo, size_t frames);
const char *dm_haptic_usb_status(void);
