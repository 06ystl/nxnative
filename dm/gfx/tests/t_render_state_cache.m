// GPU equivalence for cached dynamic state, including changes within a pass and
// a new encoder starting with exactly the previous encoder's final values.
#define NVN_OPTIMIZATION_TEST 1
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static id<MTLTexture> color,depth;
static id<MTLRenderPipelineState> pipeline;
static id<MTLDepthStencilState> ds;
static int checks,failed;
#define EXPECT(label, expected, actual) do{uint64_t a=(actual),e=(expected);checks++;if(a!=e){failed++;printf("FAIL %s: expected %llu, got %llu\n",label,e,a);}}while(0)
static void settings(id e,int k){
    MTLViewport vp={0,0,k==5?4:8,k==5?4:8,0,1};
    MTLScissorRect sc=k==1?(MTLScissorRect){4,0,4,4}:k>=2&&k<=4?(MTLScissorRect){0,4,8,4}:(MTLScissorRect){0,0,4,4};
    enc_r_viewport(e,vp);enc_r_scissor(e,sc);
    enc_r_cull(e,k==2?MTLCullModeFront:k==3?MTLCullModeBack:MTLCullModeNone);
    enc_r_winding(e,k==4?MTLWindingClockwise:MTLWindingCounterClockwise);
    enc_r_fill(e,k==4?MTLTriangleFillModeLines:MTLTriangleFillModeFill);
    enc_r_depth_bias(e,k==4?1:0,k==4?1:0,k==4?1:0);
    enc_r_depth_clip(e,k==4);
    enc_r_stencil_ref(e,(uint32_t)(k+1),(uint32_t)(k+1));
    enc_r_blend_color(e,k==0||k==4,k==1||k==4||k==5,k>=2&&k<=4,1);
}
static void read_planes(id<MTLBuffer> __strong out[3]){
    [blit() copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
        toBuffer:out[0] destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [blit() copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
        toBuffer:out[1] destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256 options:MTLBlitOptionDepthFromDepthStencil];
    [blit() copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
        toBuffer:out[2] destinationOffset:0 destinationBytesPerRow:8 destinationBytesPerImage:64 options:MTLBlitOptionStencilFromDepthStencil];
    enc_b_end(g_blit);g_blit=nil;
}
static void render(int cache,id<MTLBuffer> __strong out[2][3]){
    g_test_render_state_cache=cache;mtl_sub_begin();
    for(int pass=0;pass<2;pass++){
        MTLRenderPassDescriptor *rp=backend_render_pass();
        rp.colorAttachments[0].texture=color;rp.colorAttachments[0].loadAction=MTLLoadActionClear;
        rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
        rp.depthAttachment.texture=rp.stencilAttachment.texture=depth;
        rp.depthAttachment.loadAction=rp.stencilAttachment.loadAction=MTLLoadActionClear;
        rp.depthAttachment.storeAction=rp.stencilAttachment.storeAction=MTLStoreActionStore;
        rp.depthAttachment.clearDepth=.75;rp.stencilAttachment.clearStencil=0;
        id e=enc_r_begin(rp);enc_r_pso(e,pipeline);enc_r_dss(e,ds);
        for(int k=pass?5:0;k<6;k++){
            settings(e,k);enc_r_draw(e,MTLPrimitiveTypeTriangle,0,3);
            settings(e,k);enc_r_draw(e,MTLPrimitiveTypeTriangle,0,3);
        }
        enc_r_end(e);read_planes(out[pass]);
    }
    EXPECT("GPU completes",1,mtl_wait(mtl_sub_commit(),5000000000ull));
    EXPECT("GPU reports no error",0,mtl_last_commit_error());
}
int main(void){@autoreleasepool{
    mtl_init();NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],.5,1);}\n"
        "fragment float4 f(){return float4(1);}\n"options:nil error:&error];if(!lib)abort();
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;pd.colorAttachments[0].blendingEnabled=YES;
    pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorBlendColor;pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorZero;
    pd.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;pd.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorZero;
    pd.depthAttachmentPixelFormat=pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
    pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];if(!pipeline)abort();
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];dd.depthCompareFunction=MTLCompareFunctionAlways;dd.depthWriteEnabled=YES;
    MTLStencilDescriptor *sd=[MTLStencilDescriptor new];sd.stencilCompareFunction=MTLCompareFunctionAlways;sd.depthStencilPassOperation=MTLStencilOperationReplace;
    dd.frontFaceStencil=dd.backFaceStencil=sd;ds=[g_dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;color=[g_dev newTextureWithDescriptor:td];res_add(color);
    td.pixelFormat=MTLPixelFormatDepth32Float_Stencil8;depth=[g_dev newTextureWithDescriptor:td];res_add(depth);
    id<MTLBuffer> out[2][2][3];for(int m=0;m<2;m++)for(int p=0;p<2;p++)for(int i=0;i<3;i++){out[m][p][i]=[g_dev newBufferWithLength:i==2?64:256 options:MTLResourceStorageModeShared];res_add(out[m][p][i]);}
    render(0,out[0]);render(1,out[1]);
    for(int p=0;p<2;p++)for(int i=0;i<3;i++)EXPECT("cached and uncached planes match byte-for-byte",0,memcmp(out[0][p][i].contents,out[1][p][i].contents,i==2?64:256));
    const uint8_t green[4]={0,255,0,255},black[4]={0,0,0,255};
    for(int y=0;y<8;y++)for(int x=0;x<8;x++)EXPECT("new encoder applies viewport and scissor",0,memcmp((uint8_t *)out[1][1][0].contents+4*(y*8+x),x<4&&y<4?green:black,4));
    printf("RENDER_STATE_CACHE checks=%d failed=%d\n",checks,failed);return failed!=0;
}}
