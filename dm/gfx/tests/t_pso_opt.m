// Hot pipelines compile in the background; pending/failed builds keep drawing
// with the specialized pipeline, and adoption preserves its in-flight lifetime.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

@interface OptGate : NSObject { @public id<MTL4Compiler> compiler; dispatch_semaphore_t entered, release; _Atomic int calls; int fail; MTL4RenderPipelineDescriptor *seen; } @end
@implementation OptGate
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d compilerTaskOptions:(MTL4CompilerTaskOptions *)opts error:(NSError **)error {
    int call = atomic_fetch_add(&calls, 1); seen = d;
    if (!call) { dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); }
    if (fail) { if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil]; return nil; }
    return [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:opts error:error];
}
@end

static void pixels(id<MTLRenderPipelineState> ps, uint8_t result[16]) {
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; id<MTLTexture> target[2];
    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:i ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget;
        target[i] = [g_dev newTextureWithDescriptor:d];
        rp.colorAttachments[i].texture = target[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear;
        rp.colorAttachments[i].clearColor = MTLClearColorMake(1, 0, 0, 1); rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:ps]; [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
    [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted, "pixel comparison completes");
    memset(result, 0, 16);
    [target[0] getBytes:result bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    [target[1] getBytes:result+8 bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
}
int main(void) { @autoreleasepool {
    setenv("DM_PSO_ARCHIVE", "off", 1); mtl_init(); pso4_init();
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "constant bool bright [[function_constant(0)]];\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "struct O {float4 a[[color(0)]];float4 b[[color(1)]];};\n"
        "fragment O f() {return {bright?float4(0.5,0.25,1,0.5):float4(0),float4(0.2,0.4,0.6,0.8)};}\n" options:nil error:&error];
    CHECK(lib != nil, "fixture shaders compile"); if (!lib) return 1;
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    vs->fn = fn4_note([lib newFunctionWithName:@"v"], lib, @"v", nil);
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; bool bright = true; [cv setConstantValue:&bright type:MTLDataTypeBool atIndex:0];
    fs->fn = fn_spec(lib, @"f", cv, &error); fs->rf.color_known = 1; fs->rf.color_mask = 3;
    pso_key k = {0}; k.vs = (__bridge void *)vs; k.fs = (__bridge void *)fs;
    k.cfmt[0] = MTLPixelFormatRGBA8Unorm; k.cfmt[1] = MTLPixelFormatRGBA16Float; k.samples = 1; k.chmask = 0x9f;
    pso_key second = k; second.chmask = 0xff;
    id<MTLRenderPipelineState> initial = pso_build(pso_desc(&k, vs, fs, nil, 0), &error);
    id<MTLRenderPipelineState> other = pso_build(pso_desc(&second, vs, fs, nil, 0), &error);
    CHECK(initial && other, "specialized pipelines available first"); if (!initial || !other) return 1;
    hm_put_id(&g_pso, &k, initial); hm_put_id(&g_pso, &second, other);
    OptGate *gate = [OptGate new]; gate->compiler = g_comp4; gate->entered = dispatch_semaphore_create(0); gate->release = dispatch_semaphore_create(0); g_comp4 = (id<MTL4Compiler>)gate;
    for (int i = 1; i < PSO_OPT_USES; i++) CHECK(pso_opt_use(&k, vs, fs, initial) == initial, "cold pipeline remains immediately usable");
    CHECK(!gate->calls, "cold pipelines do not compile again");
    CHECK(pso_opt_use(&k, vs, fs, initial) == initial, "hot pipeline queues without waiting");
    CHECK(dispatch_semaphore_wait(gate->entered, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0, "background compile entered");
    CHECK(gate->seen.colorAttachments[0].pixelFormat == MTLPixelFormatRGBA8Unorm && gate->seen.colorAttachments[1].writeMask == (MTLColorWriteMaskRed|MTLColorWriteMaskAlpha), "full descriptor preserves formats and channel masks");
    for (int i = 0; i < PSO_OPT_USES+1; i++) CHECK(pso_opt_use(&second, vs, fs, other) == other, "another hot pipeline keeps drawing during compile");
    CHECK(gate->calls == 1, "only one optimization compiles at a time");
    CHECK(pso_opt_use(&k, vs, fs, initial) == initial && hm_get_id(&g_pso, &k) == initial, "pending result cannot replace live pipeline");
    dispatch_semaphore_signal(gate->release); dispatch_sync(pso_opt_queue(), ^{});
    id<MTLRenderPipelineState> optimized = pso_opt_use(&k, vs, fs, initial);
    CHECK(optimized != initial && hm_get_id(&g_pso, &k) == optimized, "submit thread adopts the completed full pipeline");
    CHECK(g_deferred.lastObject->object == initial && g_deferred.lastObject->keep_resident, "old pipeline survives through its completion fence");
    uint8_t a[16], b[16]; pixels(initial, a); pixels(optimized, b);
    CHECK(!memcmp(a, b, sizeof a), "full pipeline preserves all attachment bytes and function constants");
    CHECK(a[0] == 128 && a[1] == 64 && a[2] == 255 && a[3] == 128, "first target has literal expected colour");
    __fp16 want[4] = {0.2,0,0,0.8}, actual[4]; memcpy(actual, a+8, sizeof actual);
    int channels_equal = 1; for (int i=0;i<4;i++) channels_equal &= actual[i] == want[i];
    CHECK(channels_equal, "second target retains unwritten channels");
    gate->fail = 1; CHECK(pso_opt_use(&second, vs, fs, other) == other, "failed candidate starts without blocking");
    dispatch_sync(pso_opt_queue(), ^{});
    CHECK(pso_opt_use(&second, vs, fs, other) == other && hm_get_id(&g_pso, &second) == other, "compiler failure retains working pipeline");
    int calls = gate->calls; pso_opt_use(&second, vs, fs, other); CHECK(gate->calls == calls, "failed optimization is not retried every draw");
    pso_key diagnostic = k; diagnostic.fsfn = AMP_MARK; unsigned entries = g_pso_opt.n;
    CHECK(pso_opt_use(&diagnostic, vs, fs, initial) == initial && g_pso_opt.n == entries, "special fragments keep their existing policy");
    g_comp4 = nil; CHECK(pso_opt_use(&k, vs, fs, initial) == initial, "legacy compilation policy remains usable"); g_comp4 = gate->compiler;
    printf("t_pso_opt: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
