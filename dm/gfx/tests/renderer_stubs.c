// Renderer-only tests omit hle_nvn.c. Tests linking the real NVN layer use its
// strong allocator instead; every synthetic object still gets a unique serial.
#include <stdint.h>
#include <stdatomic.h>
__attribute__((weak)) uint64_t nvn_new_serial(void) {
    static _Atomic uint64_t next = 1000000;
    return atomic_fetch_add(&next, 1) + 1;
}
// Tests already run on a host stack. Preserve the trampoline's target and
// register arguments without the production guest-to-host stack switch.
__attribute__((weak, naked, visibility("hidden"))) void dm_bigstack_enter(void) { __asm__("br x16"); }
