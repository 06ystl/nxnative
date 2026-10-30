// Input/rumble tests never open a physical audio or HID endpoint.
#include <stddef.h>
int test_audio_ready,test_audio_active,test_foot_active,test_audio_closed;
void (*dm_footsteps_submit)(const float*,unsigned);
int dm_footsteps_configured(void){return 0;}
void dm_footsteps_set_active(int on){test_foot_active=on;}
int dm_haptic_usb_open(void){return 0;}
void dm_haptic_usb_close(void){test_audio_ready=0;test_audio_closed++;}
void dm_haptic_usb_set_active(int on){test_audio_active=on;}
int dm_haptic_usb_ready(void){return test_audio_ready;}
void dm_haptic_usb_set_gain(float g){(void)g;}
size_t dm_haptic_usb_enqueue(const float *p,size_t n){(void)p;return n;}
const char *dm_haptic_usb_status(void){return "test";}
