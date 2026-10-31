// Pacer unit tests: given a clock sequence, the expected wait durations are hand-calculated. The period 16.666 ms is written as P = 16666667 ns.
#include "../nvn/nvn_pace.h"
#include <stdio.h>

int main(void) {
    const uint64_t P = 16666667, MS = 1000000;
    struct { uint64_t now, period, want; const char *why; } c[] = {
        {1000 * MS, P, 0, "first frame: starts the beat, no wait"},
        {1005 * MS, P, 1000 * MS + P - 1005 * MS, "5 ms early: wait until 1000+P"},
        {1000 * MS + 2 * P - 2 * MS, P, 2 * MS, "third frame 2 ms early: wait 2 ms"},
        {1000 * MS + 3 * P + 3 * MS, P, 0, "3 ms late (less than a period): present at once, beat point stays 1000+3P"},
        {1000 * MS + 4 * P - 1 * MS, P, 1 * MS, "next frame 1 ms early: wait until 1000+4P in the original phase"},
        {1000 * MS + 7 * P, P, 0, "two periods behind (stall): restart the beat now, no burst to catch up"},
        {1000 * MS + 7 * P + 4 * MS, P, P - 4 * MS, "next frame after the restart: wait until the new target"},
        {1000 * MS + 9 * P, 0, 0, "period 0 (DM_PRESENT_HZ=0): no wait"},
        {1000 * MS + 9 * P + 1 * MS, 2 * P, 2 * P - 1 * MS, "back to interval 2: beat point = previous frame time 9P + 2P"},
        {1000 * MS + 11 * P + 3 * MS, 2 * P, 2 * P - 3 * MS, "interval 2, next frame: beat point 13P"},
    };
    nvn_pacer p = {0}; int fail = 0, n = sizeof c / sizeof *c;
    for (int i = 0; i < n; i++) {
        uint64_t got = nvn_pace(&p, c[i].now, c[i].period);
        int ok = got == c[i].want;
        printf("%-52s expected wait %8.3f ms → got %8.3f ms %s\n", c[i].why, c[i].want / 1e6, got / 1e6, ok ? "✓" : "✗");
        fail += !ok;
    }
    struct { double period; int hz; double want; } physical[] = {
        {1.0/60,120,1.0/60}, {1.0/30,120,1.0/30},
        {1.0/60,144,2.0/144}, {1.0/30,144,4.0/144},
        {1.0/60,165,2.0/165}, {1.0/120,144,1.0/144},
        {0,144,0}, {1.0/60,0,1.0/60}, {1.0/240,144,0}
    };
    for (unsigned i=0;i<sizeof physical/sizeof *physical;i++) {
        double got=nvn_present_minimum(physical[i].period,physical[i].hz);
        int ok=fabs(got-physical[i].want)<1e-12; fail+=!ok;n++;
        printf("physical hold at %d Hz: %.9f s %s\n",physical[i].hz,got,ok?"PASS":"FAIL");
    }
    // Ideal 60 fps arrivals on a 144 Hz display. The presentation model rounds
    // each arrival and minimum hold up to a physical refresh, independently of
    // the host's duration calculation. 600 intervals should span 10 seconds.
    for (int original=0;original<2;original++) {
        double hold=original?1.0/60:nvn_present_minimum(1.0/60,144);
        int ticks=(int)ceil(hold*144-1e-9),last=0;
        for(int frame=1;frame<=600;frame++) {
            int arrival=(frame*144+59)/60;
            last=arrival>last+ticks?arrival:last+ticks;
        }
        int ok=last==(original?1800:1440);fail+=!ok;n++;
        printf("144 Hz cadence %s: 600 intervals span %.3f s %s\n",original?"original":"corrected",last/144.0,ok?"PASS":"FAIL");
    }
    printf("== %d checks, %d failed ==\n", n, fail);
    return fail != 0;
}
