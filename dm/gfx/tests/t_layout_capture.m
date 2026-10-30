// GPU sampling of layout capture views: RG stores luminance/alpha, while the
// existing R-only masks and explicit/asset channel mappings keep their meaning.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, condition) do { checks++; if (!(condition)) { failed++; fprintf(stderr,"FAIL %s\n",label); } } while (0)
static id<MTLComputePipelineState> read_pipeline;
static uint16_t channels(unsigned r,unsigned g,unsigned b,unsigned a) { return r | g<<3 | b<<6 | a<<9; }
static tex_t fixture(int tid, MTLPixelFormat pf, int render_target, int subresource, uint16_t swz) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:4 height:2 mipmapped:subresource];
    d.storageMode=MTLStorageModeShared;
    d.usage=MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView | (render_target?MTLTextureUsageRenderTarget:0);
    if(subresource) { d.textureType=MTLTextureType2DArray; d.arrayLength=2; }
    id<MTLTexture> base=[g_dev newTextureWithDescriptor:d]; CHECK("texture created",base!=nil);
    const uint8_t data[32]={255,0, 128,64, 64,192, 0,255, 16,32, 96,128, 224,240, 255,255};
    NSUInteger level=subresource?1:0, slice=subresource?1:0, w=base.width>>level, h=base.height>>level;
    size_t bpp=pf==MTLPixelFormatRG8Unorm?2:pf==MTLPixelFormatR8Unorm?1:4;
    [base replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:level slice:slice withBytes:data bytesPerRow:w*bpp bytesPerImage:w*h*bpp];
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial(),.set_swz=1,.swz=swz};
    t.d.width=4;t.d.height=2;t.d.depth=1;t.d.levels=(uint32_t)base.mipmapLevelCount;t.d.samples=1;
    t.d.target=subresource?NVN_TEXTURE_TARGET_2D_ARRAY:NVN_TEXTURE_TARGET_2D;
    t.d.format=pf==MTLPixelFormatRG8Unorm?NVN_FORMAT_RG8:pf==MTLPixelFormatR8Unorm?NVN_FORMAT_R8:NVN_FORMAT_RGBA8;
    serial_put(t.serial,base);
    view_t v={.set_levels=1,.base_level=1,.nlevels=1,.set_layers=1,.min_layer=1,.nlayers=1,.set_target=1,.target=NVN_TEXTURE_TARGET_2D};
    mtl_reg_tex(tid,&t,subresource?&v:NULL);
    return t;
}
static id<MTLTexture> mapped(int tid, int expected) {
    pthread_mutex_lock(&g_rmu);
    id<MTLTexture> original=tex_by_id(tid); uint64_t rid=0;
    id<MTLTexture> view=tex_layout_capture(tid,original,&rid);
    CHECK("only implicit render-target mappings change",(view!=nil)==expected);
    if(view) {
        uint64_t second=0;
        CHECK("resource ID is the sampled view",rid==view.gpuResourceID._impl);
        CHECK("repeated lookup reuses view",tex_layout_capture(tid,original,&second)==view && second==rid);
    }
    pthread_mutex_unlock(&g_rmu);
    return view ?: original;
}
static void sample(id<MTLTexture> texture,const float *expected) {
    NSUInteger n=texture.width*texture.height;
    id<MTLBuffer> out=[g_dev newBufferWithLength:n*16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=q_cb();id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e setComputePipelineState:read_pipeline];[e setTexture:texture atIndex:0];[e setBuffer:out offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(texture.width,texture.height,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [e endEncoding];[cb commit];[cb waitUntilCompleted];
    CHECK("GPU read completes",cb.status==MTLCommandBufferStatusCompleted);
    const float *actual=out.contents;
    for(NSUInteger i=0;i<n*4;i++) CHECK("sampled channel equals expected",fabsf(actual[i]-expected[i])<0.00001f);
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_ALPHA_RED","f29dde3d00fb2972",1);
    mtl_init(); NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void readtex(texture2d<float,access::read> t[[texture(0)]],device float4 *o[[buffer(0)]],uint2 p[[thread_position_in_grid]]){o[p.y*t.get_width()+p.x]=t.read(p);}\n"
        options:nil error:&error];
    read_pipeline=[g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readtex"] error:&error];
    if(!read_pipeline){fprintf(stderr,"%s\n",error.description.UTF8String);return 1;}
    uint16_t rg=channels(2,3,0,1),r=channels(2,0,0,1);
    const uint8_t pixels[16]={255,0,128,64,64,192,0,255,16,32,96,128,224,240,255,255};
    float expected[32];for(int i=0;i<8;i++){expected[i*4]=expected[i*4+1]=expected[i*4+2]=pixels[i*2]/255.f;expected[i*4+3]=pixels[i*2+1]/255.f;}
    fixture(1000,MTLPixelFormatRG8Unorm,1,0,rg);id<MTLTexture> old=mapped(1000,1);sample(old,expected);
    fixture(1000,MTLPixelFormatRG8Unorm,1,1,rg);id<MTLTexture> sub=mapped(1000,1);
    CHECK("registration invalidates cached view",old!=sub);
    CHECK("mip and slice are retained",sub.width==2 && sub.height==1 && sub.mipmapLevelCount==1 && sub.parentRelativeSlice==1);
    sample(sub,expected);
    fixture(1001,MTLPixelFormatR8Unorm,1,0,r);
    for(int i=0;i<8;i++){expected[i*4]=expected[i*4+3]=pixels[i]/255.f;expected[i*4+1]=expected[i*4+2]=0;}
    sample(mapped(1001,1),expected);
    fixture(1002,MTLPixelFormatRG8Unorm,0,0,rg);mapped(1002,0);
    fixture(1003,MTLPixelFormatRG8Unorm,1,0,channels(2,2,2,3));mapped(1003,0);
    fixture(1004,MTLPixelFormatRGBA8Unorm,1,0,channels(2,3,4,5));mapped(1004,0);
    NvShader *sh=[NvShader new];strlcpy(sh->key,"f29dde3d00fb2972_b",sizeof sh->key);CHECK("configured layout shader selected",afr_want(sh));
    sh=[NvShader new];strlcpy(sh->key,"0000000000000000_b",sizeof sh->key);CHECK("other shaders retain native channels",!afr_want(sh));
    printf("LAYOUT_CAPTURE checks=%d failed=%d\n",checks,failed);return failed!=0;
} }
