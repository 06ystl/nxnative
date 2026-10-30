// Renderer-only tests omit hle_nvn.c. Tests linking the real NVN layer use its
// strong allocator instead; every synthetic object still gets a unique serial.
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
__attribute__((weak)) uint64_t nvn_new_serial(void) {
    static _Atomic uint64_t next = 1000000;
    return atomic_fetch_add(&next, 1) + 1;
}
// Tests already run on a host stack. Preserve the trampoline's target and
// register arguments without the production guest-to-host stack switch.
__attribute__((weak, naked, visibility("hidden"))) void dm_bigstack_enter(void) { __asm__("br x16"); }
// Renderer-only fixtures register ordinary pools, never sparse guest mappings.
// t_nvn links the real NVN implementations and exercises sparse mappings there.
__attribute__((weak)) int nvn_sparse_pool(const void *p) { (void)p; return 0; }
__attribute__((weak)) uint64_t nvn_sparse_gen(void) { return 0; }
__attribute__((weak)) uint64_t nvn_sparse_copy(const void *p, void *dst, uint64_t a, uint64_t n) { (void)p; (void)a; memset(dst, 0, n); return 0; }
__attribute__((weak)) int nvn_sparse_since(const void *p, uint64_t a, uint64_t n, uint64_t g, uint64_t s) { (void)p; (void)a; (void)n; (void)g; (void)s; return 0; }
__attribute__((weak)) void nvn_sparse_protect(const void *p, uint64_t a, uint64_t n) { (void)p; (void)a; (void)n; }
__attribute__((weak)) int nvn_sparse_mapped(const void *p, uint64_t a, uint64_t n) { (void)p; (void)a; (void)n; return 0; }
extern int mtl_addr(uint64_t address, uint64_t length, void **buffer, uint64_t *offset);
__attribute__((weak)) int nvn_host_readable(uint64_t a, uint64_t n) { void *buffer; uint64_t offset; return mtl_addr(a, n, &buffer, &offset); }
