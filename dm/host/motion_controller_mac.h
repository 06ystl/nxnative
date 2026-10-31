// The selected 1P controller's motion. Lifecycle calls belong to the main queue;
// game threads may read snapshots independently of rendering and button input.
#pragma once
#include "dm_input.h"
#ifdef __OBJC__
@class GCController;
void dm_controller_motion_attach(GCController *controller);
#endif
typedef struct { const char *message; int can_calibrate; } dm_controller_motion_status;
void dm_controller_motion_enable(int enabled);
void dm_controller_motion_set_active(int active);
void dm_controller_motion_calibrate(void);
dm_controller_motion_status dm_controller_motion_get_status(void);
int dm_controller_motion_read(dm_sixaxis_state *state, int fusion);
void dm_controller_motion_set_response(double horizontal, double vertical);
