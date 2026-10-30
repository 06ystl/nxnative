// Exercise pool lookup lifetime and real GPU binding changes with caches on/off.
#define NVN_OPTIMIZATION_TEST 1
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(label, expected, actual) do { uint64_t a = (actual), e = (expected); checks++; \
    if (a != e) { failed++; printf("FAIL %s: expected %llu, got %llu\n", label, e, a); } } while (0)

static void compare_lookups(uint8_t *memory) {
    // Repeated exact queries, different lengths, overlap, misses and a hash collision.
    const uint64_t offsets[] = {123, 65536+123, 123, 16384+123, 123, 65536+123, 16384+123, 131071, 131072};
    const uint64_t lengths[] = {16, 16, 16, 16, 32768, 16, 32768, 2, 16};
    struct { int ok; void *buffer; uint64_t offset, gpu; } baseline[9] = {0};
    for (int mode = 0; mode < 2; mode++) {
        g_test_pool_cache = mode; g_plast = -1;
        for (int repeat = 0; repeat < 3; repeat++) for (int i = 0; i < 9; i++) {
            void *buffer = NULL; uint64_t offset = 0, gpu = 0;
            int ok = mtl_gpu_addr((uint64_t)memory + offsets[i], lengths[i], &buffer, &offset, &gpu);
            if (!mode) {
                baseline[i].ok = ok; baseline[i].buffer = buffer; baseline[i].offset = offset; baseline[i].gpu = gpu;
            } else {
                EXPECT("lookup validity", baseline[i].ok, ok);
                if (ok) {
                    EXPECT("same pool selected", (uintptr_t)baseline[i].buffer, (uintptr_t)buffer);
                    EXPECT("same buffer offset", baseline[i].offset, offset);
                    EXPECT("same GPU address", baseline[i].gpu, gpu);
                }
            }
        }
    }
}

static void test_pools(void) {
    uint8_t *memory; if (posix_memalign((void **)&memory, getpagesize(), 131072)) abort();
    memset(memory, 0, 131072);
    mtl_pool_add(memory, 65536); mtl_pool_add(memory + 65536, 65536);
    compare_lookups(memory);
    mtl_pool_add(memory + 16384, 16384); // An overlapping pool changes lookup precedence.
    compare_lookups(memory);
    mtl_pool_del(memory); // Deletion moves the last pool into the deleted index.
    compare_lookups(memory);
    void *buffer; uint64_t offset;
    EXPECT("deleted outer pool is unavailable", 0, mtl_addr((uint64_t)memory + 123, 16, &buffer, &offset));
    mtl_pool_add(memory, 65536); // Same guest address, new Metal allocation.
    compare_lookups(memory);
    mtl_pool_del(memory + 16384); mtl_pool_del(memory + 65536); mtl_pool_del(memory);
    EXPECT("all mappings removed", 0, mtl_addr((uint64_t)memory + 123, 16, &buffer, &offset));
    // Keep no-copy storage alive until deferred Metal objects have retired.
    mtl_sub_begin(); EXPECT("pool retirement completes", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
    free(memory);
}

static id<MTLTexture> color;
static id<MTLRenderPipelineState> pipeline;
static id<MTLBuffer> vertices, tints;
static const uint64_t tint_stride = 16;
static void bind(id e, int hidden, int tint) {
    enc_r_vbuf(e, 16, vertices.gpuAddress + (hidden ? 48 : 0));
    enc_r_args(e, MTLRenderStageVertex, tints.gpuAddress + tint * tint_stride, 0);
    enc_r_args(e, MTLRenderStageFragment, tints.gpuAddress, 0);
    enc_r_args(e, MTLRenderStageFragment, tints.gpuAddress, 30);
}
static void render(int mode, id<MTLBuffer> __strong out[2]) {
    g_vbuf_cache = mode; mtl_sub_begin();
    for (int pass = 0; pass < 2; pass++) {
        // Perturb the persistent table between encoders: the next draw must
        // restore its bindings after every intervening table write.
        enc_r_vbuf(nil, 16, vertices.gpuAddress + 48);
        enc_r_vbuf(nil, 0, tints.gpuAddress + tint_stride);
        MTLRenderPassDescriptor *rp = backend_render_pass();
        rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id e = enc_r_begin(rp); enc_r_pso(e, pipeline);
        enc_r_viewport(e, (MTLViewport){0, 0, 8, 2, 0, 1});
        enc_r_cull(e, MTLCullModeNone);
        if (pass) {
            bind(e, 0, 2); enc_r_scissor(e, (MTLScissorRect){0, 0, 8, 2});
            enc_r_draw(e, MTLPrimitiveTypeTriangle, 0, 3);
        } else for (int k = 0; k < 8; k++) {
            if (k == 6) g_vbuf_cache = 0;
            if (k == 7) g_vbuf_cache = mode;
            bind(e, k == 2, k < 3 || k == 6 ? 1 : 2);
            // Both wrapper types write the same vertex-table slot. The next
            // draw must restore green rather than reusing a stale cache entry.
            if (k == 4) enc_r_vbuf(e, 0, tints.gpuAddress + 3 * tint_stride);
            enc_r_scissor(e, (MTLScissorRect){(NSUInteger)k, 0, 1, 2});
            enc_r_draw(e, MTLPrimitiveTypeTriangle, 0, 3);
        }
        enc_r_end(e);
        [blit() copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(8, 2, 1) toBuffer:out[pass] destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:64];
        enc_b_end(g_blit); g_blit = nil;
    }
    EXPECT("render completes", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
    EXPECT("GPU has no error", 0, mtl_last_commit_error());
}

int main(void) { @autoreleasepool {
    mtl_init(); test_pools(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V{float4 p[[position]];float4 c;};\n"
        "vertex V v(uint i[[vertex_id]],constant float4*p[[buffer(16)]],constant float4&c[[buffer(0)]]){return {p[i],c};}\n"
        "fragment float4 f(V v[[stage_in]],constant float4&c[[buffer(0)]],constant float4&m[[buffer(30)]]){return v.c*c*m;}\n"
        options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; if (!pipeline) abort();
    const float positions[6][4] = {{-1,-1,0,1},{3,-1,0,1},{-1,3,0,1},{5,5,0,1},{9,5,0,1},{5,9,0,1}};
    const float colors[4][4] = {{1,1,1,1},{1,0,0,1},{0,1,0,1},{0,0,1,1}};
    vertices = [g_dev newBufferWithBytes:positions length:sizeof positions options:MTLResourceStorageModeShared]; res_add(vertices);
    tints = [g_dev newBufferWithBytes:colors length:sizeof colors options:MTLResourceStorageModeShared]; res_add(tints);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:2 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget;
    color = [g_dev newTextureWithDescriptor:td]; res_add(color);
    id<MTLBuffer> out[2][2];
    for (int m = 0; m < 2; m++) for (int p = 0; p < 2; p++) { out[m][p] = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(out[m][p]); }
    render(0, out[0]); render(1, out[1]);
    for (int p = 0; p < 2; p++) EXPECT("cached and uncached pixels match", 0, memcmp(out[0][p].contents, out[1][p].contents, 64));
    const uint8_t expected[8][4] = {{255,0,0,255},{255,0,0,255},{0,0,0,255},{0,255,0,255},{0,0,255,255},{0,255,0,255},{255,0,0,255},{0,255,0,255}};
    for (int y = 0; y < 2; y++) for (int x = 0; x < 8; x++) {
        EXPECT("each draw sees its own bindings", 0, memcmp((uint8_t *)out[1][0].contents + (y*8+x)*4, expected[x], 4));
        EXPECT("new encoder reapplies bindings", 0, memcmp((uint8_t *)out[1][1].contents + (y*8+x)*4, expected[7], 4));
    }
    // Reusing addresses must still expose new data written after completion.
    memcpy((uint8_t *)tints.contents + 32, colors[3], 16); render(1, out[1]);
    for (int i = 0; i < 16; i++) EXPECT("same address exposes updated contents", 0, memcmp((uint8_t *)out[1][1].contents + i*4, expected[4], 4));
    printf("BINDING_CACHE checks=%d failed=%d\n", checks, failed); return failed != 0;
} }
