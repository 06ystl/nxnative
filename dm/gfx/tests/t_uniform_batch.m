// Real replay and GPU readback: successive uniform values must reach the right
// draws, query counts must accumulate, and only the updated bytes are written back.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks,failed;
#define EXPECT(label, expected, actual) do { uint64_t a=(actual),e=(expected); checks++; \
    if(a!=e){failed++;printf("FAIL %s: expected %llu, got %llu\n",label,e,a);} }while(0)
// Indirect-count metadata enlarged draw records; retain the 94-update fixture.
typedef struct { uint8_t bytes[16384]; size_t n; } commands;
static void emit(commands *c,unsigned op,const void *p,size_t n) {
    size_t z=(8+n+7)&~7ull;op_hdr h={op,(uint32_t)z};
    if(c->n+z>sizeof c->bytes)abort();memcpy(c->bytes+c->n,&h,8);
    if(n)memcpy(c->bytes+c->n+8,p,n);c->n+=z;
}
static void state(commands *c,int kind,const void *p,size_t n) {
    p_bind_state b={.kind=kind};memcpy(b.bytes,p,n);emit(c,OP_BIND_STATE,&b,sizeof b);
}
static void update(commands *c,uint64_t address,const float value[4]) {
    struct {uint64_t address,size;float value[4];} u={address,16};memcpy(u.value,value,16);emit(c,OP_UPDATE_UB,&u,sizeof u);
}
static tex_t color={.magic=MAGIC('T','E','X',0),.serial=90000};
static prog_t program={.serial=90001};static NvProg *shader;
static uint8_t *uniforms;
// Upstream shadows preserve both full and partial updates inside one pass.
// Verify distinct draw values, untouched bytes and a following GPU copy.
static void run_deferred(int partial,int later_partial,int updates) {
    memset(uniforms,0x5a,65536);memset(uniforms+65536,0,128);
    float first[4]={.125,0,0,0};memcpy(uniforms+112,first,16);
    state_reset();memset(&R,0,sizeof R);vis_clear();g_vis_on=g_vis_counting=0;
    commands c={0};p_set_rt rt={.n=1};rt.color[0]=&color;emit(&c,OP_SET_RT,&rt,sizeof rt);
    p_clear_color clear={.index=0,.mask=15};emit(&c,OP_CLEAR_COLOR,&clear,sizeof clear);
    p_bind_program pr={&program,3};emit(&c,OP_BIND_PROGRAM,&pr,sizeof pr);
    p_bind_buf u={.stage=1,.index=0,.addr=(uint64_t)uniforms,.size=128};emit(&c,OP_BIND_UBO,&u,sizeof u);
    color_st col={1,NVN_LOGIC_OP_COPY,NVN_ALPHA_FUNC_ALWAYS};state(&c,1,&col,sizeof col);
    blend_st blend={0,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,
        NVN_BLEND_EQUATION_ADD,NVN_BLEND_EQUATION_ADD};state(&c,0,&blend,sizeof blend);
    p_draw draw={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3};emit(&c,OP_DRAW,&draw,sizeof draw);
    uint8_t expected[128];memset(expected,0x5a,sizeof expected);
    for(int i=0;i<updates;i++) {
        float value[4]={0,i?0:.25,i?.5:0,0};
        if(updates>2) { value[0]=1.0f/128;value[1]=value[2]=0; }memcpy(expected+112,value,16);
        if(partial || (later_partial && i)) update(&c,(uint64_t)(uniforms+112),value);
        else {
            struct {uint64_t address,size;uint8_t value[128];} update_all={(uint64_t)uniforms,128};
            memcpy(update_all.value,expected,128);emit(&c,OP_UPDATE_UB,&update_all,sizeof update_all);
        }
        emit(&c,OP_DRAW,&draw,sizeof draw);
    }
    uint64_t cp[3]={(uint64_t)uniforms,(uint64_t)(uniforms+65536),128};emit(&c,OP_COPY_B2B,cp,sizeof cp);
    emit(&c,OP_END,NULL,0);
    id<MTLBuffer> out=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];res_add(out);
    mtl_sub_begin();uint64_t before=g_stat_pass,conflicts=g_ubd_conflicts;
    mtl_exec(c.bytes);rp_end();
    EXPECT("full and partial updates preserve one render pass",1,g_stat_pass-before);
    EXPECT("shadowed reads do not need a conflict flush",0,g_ubd_conflicts-conflicts);
    enc_b_copy_texture_buffer(blit(),tex_mtl(&color),0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,8,1),out,0,32,256);
    EXPECT("deferred submission completes",1,mtl_wait(mtl_sub_commit(),5000000000ull));
    EXPECT("deferred submission has no GPU error",0,mtl_last_commit_error());
    const uint8_t pixel[4]={updates>2?220:32,updates>2?0:64,updates>2?0:128,0};
    for(int i=0;i<64;i++)EXPECT("deferred draws read distinct values",0,memcmp((uint8_t *)out.contents+i*4,pixel,4));
    EXPECT("deferred final bytes reach guest buffer",0,memcmp(uniforms,expected,128));
    EXPECT("copy after deferred draws sees final value",0,memcmp(uniforms+65536,expected,128));
    res_remove(out);
}
int main(void){@autoreleasepool{
    setenv("DM_NVN_TBDR","0",1);mtl_init();NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
        "struct A{constant float4 *u[[id(0)]];};fragment float4 f(constant A&a[[buffer(0)]]){return a.u[7];}\n"options:nil error:&error];
    if(!lib){fprintf(stderr,"%s\n",error.description.UTF8String);return 1;}
    shader=[NvProg new];for(int st=0;st<2;st++){shader->sh[st]=[NvShader new];shader->sh[st]->stage=st;}
    shader->sh[0]->fn=[lib newFunctionWithName:@"v"];shader->sh[1]->fn=[lib newFunctionWithName:@"f"];
    shader->sh[1]->rf.nb=1;shader->sh[1]->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF};
    shader->sh[1]->rf.color_mask=shader->sh[1]->rf.color_known=1;
    shader->sh[1]->ae=[shader->sh[1]->fn newArgumentEncoderWithBufferIndex:0];serial_put(program.serial,shader);
    color.d.width=color.d.height=8;color.d.depth=color.d.levels=color.d.samples=1;
    color.d.target=NVN_TEXTURE_TARGET_2D;color.d.format=NVN_FORMAT_RGBA8;(void)tex_mtl(&color);
    if(posix_memalign((void **)&uniforms,getpagesize(),131072))abort();mtl_pool_add(uniforms,131072);
    run_deferred(0,0,2);run_deferred(0,1,2);run_deferred(1,0,2);
    run_deferred(1,0,94); // Large sequence spans multiple immutable shadow arenas.
    mtl_pool_del(uniforms);free(uniforms);
    printf("UNIFORM_SNAPSHOTS checks=%d failed=%d\n",checks,failed);return failed!=0;
}}
