// Drive the actual DM_KEYS worker with a fake clock, then read real Npad states.
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
static int fake_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
static int fake_sleep(useconds_t);
static int fake_clock(clockid_t, struct timespec *);
#define pthread_create fake_create
#define usleep fake_sleep
#define clock_gettime fake_clock
#include "../hle_hid.c"
#undef pthread_create
#undef usleep
#undef clock_gettime

static uint64_t frame, clock_ns;
static int checks, fails, held;
uint64_t dm_guest_frame(void) { return frame; }
int dm_opmode(void) { return 1; }
void hle_bind_system_event(void *event, int autoclear) { (void)event; (void)autoclear; }
void hle_signal_system_event(void *event) { (void)event; }
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL %s\n", msg); } } while (0)
static NpadState read_pad(void) { NpadState s; uint32_t id = 0; h_hid_StateFullKey(&s, &id); return s; }
static int fake_create(pthread_t *thread, const pthread_attr_t *attr, void *(*entry)(void *), void *arg) {
    (void)thread; (void)attr; (void)arg;
    CHECK(entry == keys_main, "the parser selects the real input worker");
    return EAGAIN; // The test invokes the worker synchronously.
}
static int fake_clock(clockid_t which, struct timespec *time) {
    (void)which; time->tv_sec = clock_ns / 1000000000; time->tv_nsec = clock_ns % 1000000000; return 0;
}
static int fake_sleep(useconds_t microseconds) {
    NpadState s = read_pad();
    if (microseconds == 20000) {
        static const int32_t expected[7][4] = {
            {0,0,-32767,0}, {0,0,0,32767}, {0,0,32767,0}, {0,0,0,-32767},
            {32767,0,0,32767}, {32767,0,0,32767}, {0,0,0,0}
        };
        CHECK(held < 7, "no extra held inputs");
        if (held < 7) {
            CHECK(s.lx == expected[held][0] && s.ly == expected[held][1] &&
                  s.rx == expected[held][2] && s.ry == expected[held][3], "scripted axes reach Npad unchanged");
            uint64_t expected_buttons = held == 4 || held == 5 ? DM_BTN_A : held == 6 ? DM_BTN_RIGHT : 0;
            CHECK((s.buttons & 0xffff) == expected_buttons, "stick names stay distinct from D-pad and button names");
            if (held < 4) CHECK((s.buttons & (1ull << (20 + held))) != 0, "right-stick pseudo-button follows its axis");
        }
        held++;
    } else CHECK(!s.buttons && !s.lx && !s.ly && !s.rx && !s.ry, "input releases while waiting for the next step");
    clock_ns += (uint64_t)microseconds * 1000; frame++; return 0;
}
int main(void) {
    setenv("DM_KEYS", "f2:RLeft~0.02,f5:RUp~0.02,f8:RRight~0.02,f11:RDown~0.02,f14:A+LRight+RUp~0.02*2/3,0.20:Right~0.02", 1);
    hid_keys_init(); CHECK(g_nsteps == 7, "repeat expansion preserves both sticks");
    keys_main(NULL); CHECK(held == 7, "every scripted input is delivered");
    NpadState s = read_pad(); CHECK(!s.buttons && !s.lx && !s.ly && !s.rx && !s.ry, "last step releases both sticks");
    printf("HID_AXES_SCRIPT checks=%d failed=%d\n", checks, fails); return fails != 0;
}
