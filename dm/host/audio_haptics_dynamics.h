#pragma once
// 48 kHz stereo output: 2 ms look-ahead, 50 ms recovery, linked channels, full PCM scale.
enum { DM_HAPTIC_LOOKAHEAD=96, DM_HAPTIC_DELAY_SIZE=DM_HAPTIC_LOOKAHEAD+1 };
typedef struct {
    double samples[DM_HAPTIC_DELAY_SIZE][2],bound[DM_HAPTIC_DELAY_SIZE];
    double gain,release;
    unsigned position;
} dm_haptic_dynamics;
void dm_haptic_dynamics_reset(dm_haptic_dynamics *state);
void dm_haptic_dynamics_process(dm_haptic_dynamics *state,double left,double right,float out[2]);
