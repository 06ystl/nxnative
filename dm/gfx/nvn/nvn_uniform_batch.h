// Included by nvn_mtl.m after the replay state and drawing helpers.
// A flat run of small updates to one uniform range followed by read-only draws
// can use immutable GPU snapshots. Prepare them in one copy encoder, draw with
// each version, then write only the updated bytes back to the guest buffer.
// Everything else terminates the run and keeps the normal ordered-copy path.
#define UNIFORM_BATCH_MAX 256
static struct {
    int active, count, next, current;
    const uint8_t *end;
    uint64_t base, size, dst, length, original_offset, registry;
    __unsafe_unretained id<MTLBuffer> original;
    struct {
        const uint8_t *op;
        __unsafe_unretained id<MTLBuffer> buffer, patch;
        size_t offset, patch_offset; uint64_t gpu;
    } version[UNIFORM_BATCH_MAX];
} g_uniform_batch;
static uint64_t g_uniform_batches;
static int uniform_overlap(uint64_t a, uint64_t n, uint64_t b, uint64_t m) {
    return n && m && (a <= b ? b - a < n : a - b < m);
}
static int uniform_contains(uint64_t a, uint64_t n, uint64_t b, uint64_t m) {
    return b >= a && b - a <= n && m <= n - (b - a);
}
static uint64_t uniform_version_gpu(uint64_t address, uint64_t size) {
    if (!g_uniform_batch.active || g_uniform_batch.current < 0 ||
        !uniform_contains(g_uniform_batch.base, g_uniform_batch.size, address, size)) return 0;
    return g_uniform_batch.version[g_uniform_batch.current].gpu + address - g_uniform_batch.base;
}
static int uniform_batch_program(uint64_t base, uint64_t size) {
    NvProg *p = S.prog ? prog_get(S.prog) : nil;
    if (!p || !p->sh[0] || g_ui_moff != 0 || tbdr_on()) return 0;
    for (int st = 0; st < 6; st++) {
        NvShader *sh = p->sh[st]; if (!sh) continue;
        if (st > 1 || sh->stage != st || !sh->uniform_ro) return 0;
        for (int i = 0; i < sh->rf.nb; i++) {
            const nvn_rbind *b = &sh->rf.b[i];
            if (b->kind == NVN_RB_CBUF) {
                if (b->reg >= 16) return 0;
                const p_bind_buf *u = &S.ubo[st][b->reg];
                if (uniform_overlap(base, size, u->addr, u->size) && !uniform_contains(base, size, u->addr, u->size)) return 0;
            } else if (b->kind == NVN_RB_TEX) {
                if (b->reg >= 128) return 0;
                int tid = (int)(S.tex[st][b->reg] & 0xfffff);
                // Private textures cannot alias the guest's uniform buffer.
                pthread_mutex_lock(&g_rmu);
                id<MTLTexture> t = tid > 0 && tid < g_ntreg && g_treg[tid].ok ? tex_mtl(&g_treg[tid].t) : nil;
                int private = t && t.storageMode == MTLStorageModePrivate && !t.buffer;
                pthread_mutex_unlock(&g_rmu);
                if (!private) return 0;
            } else if (b->kind != NVN_RB_C1 && b->kind != NVN_RB_SUPPORT &&
                       b->kind != NVN_RB_SAMP && b->kind != NVN_RB_SAMPT) return 0;
        }
    }
    for (int i = 0; i < 16; i++)
        if (uniform_overlap(base, size, S.vbuf[i].address, S.vbuf[i].size)) return 0;
    for (int i = 0; i < R.rt.n + 1; i++) {
        const tex_t *t = i == R.rt.n ? R.rt.depth : R.rt.color[i];
        if (!t) continue;
        id<MTLTexture> texture = tex_mtl(t);
        if (!texture || texture.storageMode != MTLStorageModePrivate || texture.buffer) return 0;
    }
    return 1;
}
static void uniform_batch_finish(void) {
    if (!g_uniform_batch.active) return;
    int i = g_uniform_batch.current;
    // End the draws before restoring the final guest-visible value. Unmodified
    // bytes in the uniform binding are never written back.
    g_uniform_batch.active = 0;
    if (i >= 0) enc_b_copy_buffer(blit(), g_uniform_batch.version[i].buffer,
        g_uniform_batch.version[i].offset + g_uniform_batch.dst - g_uniform_batch.base,
        g_uniform_batch.original, g_uniform_batch.original_offset + g_uniform_batch.dst - g_uniform_batch.base,
        g_uniform_batch.length);
    args_dirty_all();
}
static void uniform_batch_boundary(const uint8_t *p) {
    if (g_uniform_batch.active && p == g_uniform_batch.end) uniform_batch_finish();
}
static int uniform_batch_draw_guard(void) {
    if (!g_uniform_batch.active || g_uniform_batch.registry == g_reg_gen) return 0;
    uniform_batch_finish();
    return 1;
}
static int uniform_batch_prepare(const uint8_t *start, uint64_t dst, uint64_t length) {
    if (!uniform_batch_on() || !g_enc || !length || length > 256) return 0;
    uint64_t base = 0, size = 0;
    for (int st = 0; st < 2 && !base; st++) for (int reg = 0; reg < 16; reg++) {
        const p_bind_buf *u = &S.ubo[st][reg];
        if (u->addr && u->size <= 65536 && uniform_contains(u->addr, u->size, dst, length)) { base = u->addr; size = u->size; break; }
    }
    if (!base || !uniform_batch_program(base, size)) return 0;
    const uint8_t *updates[UNIFORM_BATCH_MAX], *p = start;
    int count = 0, draws = 0;
    for (int ops = 0; ops < 1024; ops++) {
        op_hdr h; memcpy(&h, p, sizeof h);
        if (h.op == OP_UPDATE_UB) {
            uint64_t d, n; memcpy(&d, p + 8, 8); memcpy(&n, p + 16, 8);
            if (d != dst || n != length || count == UNIFORM_BATCH_MAX) break;
            updates[count++] = p;
        } else if (h.op == OP_DRAW) { draws++; }
        else if (h.op == OP_DRAW_IDX) {
            const p_draw_idx *d = (const p_draw_idx *)(p + 8);
            uint64_t bytes = (uint64_t)d->count * (d->itype == 1 ? 2 : d->itype == 2 ? 4 : 1);
            if (uniform_overlap(base, size, d->ibuf, bytes)) break;
            draws++;
        } else break;
        p += h.size;
    }
    if (count < 2 || draws < 2) return 0;
    void *original; uint64_t offset;
    if (!mtl_addr(base, size, &original, &offset)) return 0;
    g_uniform_batch.base = base; g_uniform_batch.size = size;
    g_uniform_batch.dst = dst; g_uniform_batch.length = length;
    g_uniform_batch.original = (__bridge id<MTLBuffer>)original; g_uniform_batch.original_offset = offset;
    g_uniform_batch.end = p; g_uniform_batch.count = count; g_uniform_batch.next = 0; g_uniform_batch.current = -1;
    g_uniform_batch.registry = g_reg_gen;
    for (int i = 0; i < count; i++) {
        id<MTLBuffer> buffer, patch;
        size_t off = arena_alloc((size_t)size, &buffer);
        uint64_t gpu = buffer.gpuAddress + off;
        size_t patch_off = arena_alloc((size_t)length, &patch);
        memcpy((uint8_t *)patch.contents + patch_off, updates[i] + 24, (size_t)length);
        g_uniform_batch.version[i].op = updates[i]; g_uniform_batch.version[i].buffer = buffer;
        g_uniform_batch.version[i].offset = off; g_uniform_batch.version[i].gpu = gpu;
        g_uniform_batch.version[i].patch = patch; g_uniform_batch.version[i].patch_offset = patch_off;
    }
    // Every update replaces exactly the same byte range. All other bytes
    // come from the original buffer, so versions do not depend on one
    // another. Their destination and patch ranges are disjoint allocations.
    id encoder = blit();
    for (int i = 0; i < count; i++) {
        __typeof__(g_uniform_batch.version[0]) *v = &g_uniform_batch.version[i];
        enc_b_copy_buffer(encoder, g_uniform_batch.original, offset, v->buffer, v->offset, size);
    }
    // Each patch overwrites bytes copied above. One barrier orders every
    // base copy before every patch; patches have no dependencies on each other.
    blit_barrier();
    for (int i = 0; i < count; i++) {
        __typeof__(g_uniform_batch.version[0]) *v = &g_uniform_batch.version[i];
        enc_b_copy_buffer(encoder, v->patch, v->patch_offset, v->buffer, v->offset + dst - base, length);
    }
    // Later generic copies must see all writes from this specialized batch.
    g_bw_lo[0] = 0; g_bw_hi[0] = UINT64_MAX; g_bw_n = 1; g_blit_ops = 1;
    g_uniform_batch.active = 1;
    if (g_npend < PEND_MAX) { g_pend_lo[g_npend] = dst; g_pend_hi[g_npend++] = dst + length; } else g_pend_over = 1;
    g_uniform_batches++;
    if (g_uniform_batches == 1) MLOG("Uniform snapshots: first batch has %d updates, %d draws, %llu-byte binding", count, draws, (unsigned long long)size);
    return 1;
}
static int uniform_batch_update(const uint8_t *p, uint64_t dst, uint64_t length) {
    if (!g_uniform_batch.active && !uniform_batch_prepare(p, dst, length)) return 0;
    int next = g_uniform_batch.next;
    if (next >= g_uniform_batch.count || g_uniform_batch.version[next].op != p) {
        uniform_batch_finish(); return 0;
    }
    g_uniform_batch.current = next; g_uniform_batch.next++;
    args_dirty_all();
    return 1;
}
