#pragma once
// Normalized trigger slope; side 0 is L2, side 1 is R2.
typedef struct {
    int enabled;
    float start,end,low,high;
} dm_trigger_slope;
typedef void (*dm_trigger_output_fn)(unsigned side,const dm_trigger_slope *effect);
