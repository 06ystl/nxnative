// HID fixtures link the real touch store; tests with a fake clock override this.
#include <stdint.h>
#include <time.h>
#include <stdlib.h>
__attribute__((weak)) uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
__attribute__((weak)) uint64_t guest_ns(void) { return now_ns(); }

// HID-only tests do not link graphics or live guest-memory diagnostics. Fail
// explicitly if a fixture accidentally starts one of those control commands.
void dm_gfx_shot_at(long k, const char *path) { (void)k; (void)path; abort(); }
void dm_gfx_passdump_next(long n) { (void)n; abort(); }
void dm_gfx_texdump_next(const char *path) { (void)path; abort(); }
void dm_gfx_texlist(int target) { (void)target; abort(); }
void dm_gfx_texraw(uint64_t serial, const char *path) { (void)serial; (void)path; abort(); }
void dm_ctl_peek(uint64_t address, int n) { (void)address; (void)n; abort(); }
void dm_ctl_memdump(uint64_t address, uint64_t n, const char *path) { (void)address; (void)n; (void)path; abort(); }
void dm_ctl_cvar_i32(uint64_t offset, int32_t value) { (void)offset; (void)value; abort(); }
void dm_ctl_cvar_f32(uint64_t offset, float value) { (void)offset; (void)value; abort(); }
void crash_dump_now(void) { abort(); }
void dm_applet_enter(const char *name) { (void)name; }
void dm_applet_leave(void) {}
int hle_signal_bound_system_event(void *event) { (void)event; return 0; }
