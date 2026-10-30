// Exercise indirect argument buffers, GPU writes, indexed draws and presentation.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, condition) do { checks++; if (!(condition)) { failed++; fprintf(stderr, "FAIL %s\n", name); } } while (0)
static void test_uploads(void) {
    // One batch mixes native BC1 and ordinary uploads on a BC-capable GPU.
    static uint8_t memory[65536] __attribute__((aligned(16384)));
    pool_t pool = {.magic=MAGIC('P','O','O','L'),.flags=0x24,.mem=memory,.size=sizeof memory};
    tex_t t[2] = {0}; uint8_t rgba[64];
    for (int i=0;i<16;i++) memcpy(rgba+4*i,(uint8_t[]){64,128,192,255},4);
    const uint8_t green_bc1[8] = {0xe0,0x07,0,0,0,0,0,0};
    for (int i=0;i<2;i++) {
        t[i].magic=MAGIC('T','E','X',0); t[i].serial=nvn_new_serial(); t[i].has_layout=1;
        t[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=i?NVN_FORMAT_RGBA8:NVN_FORMAT_RGBA_DXT1,.samples=1,.width=4,.height=4,.depth=1,.levels=1};
        nvn_tex_layout(&t[i].d,&t[i].L); t[i].mem=memory+i*16384; t[i].pool=&pool; t[i].off=i*16384;
        EXPECT("fixture swizzle",!nvn_swizzle(&t[i].d,0,0,i?rgba:green_bc1,i?16:8,t[i].mem));
    }
    mtl_pool_add(memory,sizeof memory); mtl_sub_begin();
    id<MTLTexture> textures[2] = {tex_mtl(&t[0]),tex_mtl(&t[1])};
    EXPECT("ordinary upload queued",g_nup_blits>0);
    up_flush();
    id<MTLBuffer> readback=[g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared]; res_add(readback);
    for(int i=0;i<2;i++) enc_b_copy_texture_buffer(blit(),textures[i],0,0,MTLOriginMake(0,0,0),MTLSizeMake(4,4,1),readback,i*64,i?16:8,i?64:8);
    EXPECT("upload completion",mtl_wait(mtl_sub_commit(),5000000000ull)); EXPECT("upload GPU success",!mtl_last_commit_error());
    for(int i=0;i<8;i++) EXPECT("native BC1 upload bytes",((uint8_t *)readback.contents)[i]==green_bc1[i]);
    for(int i=0;i<64;i++) EXPECT("mixed upload pixels",((uint8_t *)readback.contents)[64+i]==rgba[i]);
}
int main(void) { @autoreleasepool {
    mtl_init(); test_uploads(); NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion3_1;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct C { device float4 *value; };\n"
        "kernel void k(constant C &a [[buffer(0)]]) { a.value[0] = float4(1); }\n"
        "vertex float4 v(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "struct A { device float4 *value; texture2d<float> tex; sampler smp; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { return a.value[0] * a.tex.sample(a.smp,float2(0.5)); }\n"
        options:options error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
    id<MTLComputePipelineState> cp = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!cp || !pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
    id<MTLBuffer> values = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(values);
    id<MTLBuffer> copied = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(copied);
    id<MTLBuffer> args = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(args);
    const uint16_t indices[] = {99,0,1,2};
    id<MTLBuffer> ib = [g_dev newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared]; res_add(ib);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td]; res_add(tex);
    uint8_t pixels[64]; for (int i=0;i<16;i++) memcpy(pixels+4*i,(uint8_t[]){64,128,192,255},4);
    [tex replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td]; res_add(target);
    id<MTLTexture> presented = [g_dev newTextureWithDescriptor:td]; res_add(presented);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> sampler = [g_dev newSamplerStateWithDescriptor:sd];
    uint64_t *a = args.contents; a[0] = values.gpuAddress + 16;
    a[4] = copied.gpuAddress + 16; a[5] = tex.gpuResourceID._impl; a[6] = sampler.gpuResourceID._impl;
    id<MTLBuffer> out = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(out);
    uint32_t records[16] = {3,1,0,0, 3,1,0,0,0, 0,0,0, 1,1,1,0};
    id<MTLBuffer> indirect = [g_dev newBufferWithBytes:records length:sizeof records options:MTLResourceStorageModeShared]; res_add(indirect);
    id<MTLBuffer> counts = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(counts);
    mtl_sub_begin();
    id ce = enc_c_begin(nil);
    copy_dispatch_counts(ce,indirect,48,counts,16);
    enc_c_pso(ce, cp); enc_c_args(ce,args.gpuAddress,0);
    if (!g_metal4) nvl_use_resource(ce,values,MTLResourceUsageWrite,0);
    enc_c_dispatch_indirect(ce,counts.gpuAddress+16,MTLSizeMake(1,1,1)); enc_c_end(ce);
    enc_b_copy_buffer(blit(),values,16,copied,16,16); enc_b_end(g_blit); g_blit=nil;
    for(int mode=0;mode<3;mode++) {
    if(mode) mtl_sub_begin();
    MTLRenderPassDescriptor *rp = backend_render_pass(); rp.colorAttachments[0].texture=target;
    rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id en = enc_r_begin(rp); enc_r_pso(en,pipeline); enc_r_cull(en,MTLCullModeNone);
    enc_r_viewport(en,(MTLViewport){0,0,4,4,0,1}); enc_r_args(en,MTLRenderStageFragment,args.gpuAddress+32,0);
    if (!g_metal4) { nvl_use_resource(en,copied,MTLResourceUsageRead,MTLRenderStageFragment); nvl_use_resource(en,tex,MTLResourceUsageRead,MTLRenderStageFragment); }
    if(mode==0) enc_r_draw_indexed(en,MTLPrimitiveTypeTriangle,3,MTLIndexTypeUInt16,ib.gpuAddress+2,6,1,0,0);
    else if(mode==1) enc_r_draw_indirect(en,MTLPrimitiveTypeTriangle,indirect.gpuAddress);
    else enc_r_draw_indexed_indirect(en,MTLPrimitiveTypeTriangle,MTLIndexTypeUInt16,ib.gpuAddress+2,6,indirect.gpuAddress+16);
    enc_r_end(en);
    int crop[4]={1,1,2,2}; EXPECT("present encoded",present_encode_replay(g_cb,target,presented,crop,0));
    enc_b_copy_texture_buffer(blit(),presented,0,0,MTLOriginMake(0,0,0),MTLSizeMake(4,4,1),out,0,16,64);
    EXPECT("completion",mtl_wait(mtl_sub_commit(),5000000000ull));
    EXPECT("GPU success",!mtl_last_commit_error());
    for(int i=0;i<4;i++) EXPECT("indirect compute then copy",((float *)copied.contents)[4+i]==1.0f);
    for(int i=0;i<64;i++) EXPECT("indexed rendering and cropped present pixels",((uint8_t *)out.contents)[i]==pixels[i]);
    }
    for(int i=0;i<3;i++) EXPECT("GPU-written indirect group count",((uint32_t *)counts.contents)[4+i]==1);
    NSUInteger offset=999; EXPECT("registered offset",nvl_buffer_at(values.gpuAddress+16,16,&offset)==(g_metal4?nil:values));
    if(!g_metal4) { EXPECT("offset value",offset==16); EXPECT("out of bounds rejected",!nvl_buffer_at(values.gpuAddress+255,2,&offset)); }
    printf("BACKEND Metal%d checks=%d failed=%d\n",g_metal4?4:3,checks,failed); return failed!=0;
} }
