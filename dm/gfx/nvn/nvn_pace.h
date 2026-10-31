// Present pacer (pure function, shared by Mac / iOS; unit test tests/t_pace.c).
// Semantics as vsync: present slot = previous present slot + period. Early → wait until the present slot; late by less than one period → present immediately and keep the original phase;
// behind by one period or more (stutter) → restart the cadence from the current time, no burst of presents to catch up. Period 0 = no wait (the present slot follows the current time).
#pragma once
#include <stdint.h>
#include <math.h>

typedef struct { uint64_t target; } nvn_pacer;

// now: monotonic clock (ns); period: this frame's period (ns, 0 = no wait). Returns the ns to wait (0 = present immediately) and updates the internal target time.
static inline uint64_t nvn_pace(nvn_pacer *p, uint64_t now, uint64_t period) {
    if (!period || !p->target) { p->target = now; return 0; }
    uint64_t next = p->target + period;
    if (now <= next) { p->target = next; return next - now; }
    p->target = now - next < period ? next : now;
    return 0;
}

// The host pacer keeps the logical rate. A minimum drawable duration must
// permit its nearest physical refreshes: 60 fps on 144 Hz needs 2/3 ticks,
// whereas a strict 1/60 minimum forces every frame to 3 ticks (48 fps).
// Keep exact multiples and unknown displays unchanged.
static inline double nvn_present_minimum(double period, int hz) {
    if (period <= 0 || hz <= 0) return period;
    double ticks = period * hz;
    if (fabs(ticks - round(ticks)) < 1e-6) return period;
    return floor(ticks) / hz;
}
