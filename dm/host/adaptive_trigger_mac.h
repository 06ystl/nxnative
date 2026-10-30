// Called on the existing serial controller-feedback queue.
#pragma once
#include <stdint.h>
#include "bow_state_mac.h"
#include "shield_state_mac.h"
#include "trigger_effect_mac.h"
#ifdef __OBJC__
@class GCController;
void dm_adaptive_trigger_attach(GCController *controller);
#endif
// Bound once before controller startup; NULL for games without a verified reader.
extern dm_bow_snapshot (*dm_adaptive_trigger_sample)(void);
extern dm_shield_snapshot (*dm_adaptive_shield_sample)(void);
int dm_adaptive_trigger_available(void);
void dm_adaptive_trigger_set_active(int active);
void dm_adaptive_trigger_tick(uint64_t now);
void dm_adaptive_trigger_shutdown(void);
// Select the shared USB report owner while audio haptics owns the controller.
// NULL restores native GameController trigger output.
void dm_adaptive_trigger_set_usb_output(dm_trigger_output_fn output);
