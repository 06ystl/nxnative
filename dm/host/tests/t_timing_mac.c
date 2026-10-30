// Native contract checks; --apply exposes the production patch to the optional
// original-game instruction test (test_botw_frame_step.py).
#include "../timing_mac.c"
#include <assert.h>

static unsigned checks, failed;
#define CHECK(test) do { checks++; if (!(test)) { failed++; fprintf(stderr,"FAIL %d: %s\n",__LINE__,#test); } } while (0)
static float ratio(void) { uint32_t bits=atomic_load(g_ratio); float value;memcpy(&value,&bits,4);return value; }
static int apply(int argc,char **argv) {
    if(argc!=8)return 2;
    FILE *f=fopen(argv[2],"rb");if(!f)return 2;fseek(f,0,SEEK_END);size_t length=ftell(f);rewind(f);
    size_t size=(length+0x3fff)&~(size_t)0x3fff;
    uint8_t *image=calloc(1,size+0x4000);if(!image)return 2;
    if(fread(image,1,length,f)!=length)return 2;fclose(f);
    module_t m={.base=image,.text_end=strtoull(argv[5],0,0),.ro_off=strtoull(argv[6],0,0)};
    strcpy(m.name,"main");strlcpy(m.build_id,argv[4],sizeof m.build_id);
    int extra=dm_timing_mac_prepare(&m,image,length);if(extra!=0x4000)return 1;
    m.size=size+extra;dm_timing_mac_bind(&m);
    f=fopen(argv[3],"wb");if(!f)return 2;fwrite(image,1,m.size,f);fclose(f);
    f=fopen(argv[7],"w");if(!f)return 2;
    fprintf(f,"{\"data\":%zu,\"stub\":%llu,\"target\":%d}\n",g_data_offset,(m.text_end+15)&~15ull,g_target);fclose(f);
    free(image);return 0;
}
static void patch_contract(void) {
    if(!patches[0].build)return;
    const frame_patch *p=&patches[0];module_t m={0};
    strcpy(m.name,"main");strlcpy(m.build_id,p->build,sizeof m.build_id);
    m.text_end=p->site+0x100;m.ro_off=m.text_end+0x1000;
    size_t size=m.ro_off+0x4000,stub=(m.text_end+15)&~15ull;
    uint8_t *image=calloc(1,size),*original=calloc(1,size);CHECK(image&&original);
    memcpy(original+p->site,&p->original,4);
    for(size_t i=0;i<sizeof guards/sizeof *guards;i++)
        if(guards[i].build&&!strcmp(guards[i].build,p->build))memcpy(original+guards[i].site,&guards[i].original,4);
    memcpy(image,original,size);setenv("DM_FPS","60",1);setenv("DM_FPS_TARGET","60",1);
    CHECK(dm_timing_mac_prepare(&m,image,size)==0);CHECK(!memcmp(image,original,size));
    unsetenv("DM_FPS_TARGET");setenv("DM_FRAME_STEP","ticks",1);
    CHECK(dm_timing_mac_prepare(&m,image,size)==0);CHECK(!memcmp(image,original,size));
    unsetenv("DM_FRAME_STEP");setenv("DM_FPS","30",1);
    CHECK(dm_timing_mac_prepare(&m,image,size)==0);CHECK(!memcmp(image,original,size));
    setenv("DM_FPS","91",1);
    CHECK(dm_timing_mac_prepare(&m,image,size)==0);CHECK(!memcmp(image,original,size));
    setenv("DM_FPS","120",1);m.build_id[0]='0';
    CHECK(dm_timing_mac_prepare(&m,image,size)==-1);CHECK(!memcmp(image,original,size));
    strlcpy(m.build_id,p->build,sizeof m.build_id);image[p->site]^=1;
    CHECK(dm_timing_mac_prepare(&m,image,size)==-1);CHECK(image[p->site]==(original[p->site]^1));
    memcpy(image,original,size);CHECK(dm_timing_mac_prepare(&m,image,p->site+2)==-1);CHECK(!memcmp(image,original,size));
    image[stub]=1;CHECK(dm_timing_mac_prepare(&m,image,size)==-1);CHECK(image[stub]==1);
    memcpy(image,original,size);uint64_t end=m.text_end,ro=m.ro_off;m.text_end=(end+0x3fff)&~0x3fffull;m.ro_off=m.text_end+0x1000;
    CHECK(dm_timing_mac_prepare(&m,image,size)==-1);CHECK(!memcmp(image,original,size));m.text_end=end;m.ro_off=ro;
    memcpy(image,original,size);CHECK(dm_timing_mac_prepare(&m,image,size)==0x4000);
    uint32_t word;memcpy(&word,image+p->site,4);CHECK((word&0xfc000000u)==0x14000000u);
    memcpy(image,original,size);setenv("DM_FPS","60",1);
    CHECK(dm_timing_mac_prepare(&m,image,size)==0x4000);CHECK(g_pending==60);
    memcpy(image,original,size);unsetenv("DM_FPS");
    CHECK(dm_timing_mac_prepare(&m,image,size)==0x4000);CHECK(g_pending==60);
    free(original);free(image);
}
int main(int argc,char **argv) {
    if(argc>1)return apply(argc,argv);
    _Atomic uint32_t storage=0;g_ratio=&storage;_Atomic uint64_t accepted=0;g_accepted=&accepted;g_target=120;g_base_hz=30;g_seconds=1./120;g_seen=UINT64_MAX;
    uint64_t at=1000000000ull;
    dm_game_frame_sample(at,0);
    const unsigned fps[]={15,20,30,60,75,90,100,120};
    for(unsigned i=0;i<sizeof fps/sizeof *fps;i++) {
        uint64_t delta=1000000000ull/fps[i];at+=delta;
        dm_game_frame_sample(at,i+1);
        CHECK(fabs(ratio()-30.0/fps[i])<1e-5);
        CHECK(fabs(g_seconds-1.0/fps[i])<1e-8);
        uint32_t prior=storage;dm_game_frame_sample(at+100,i+1);CHECK(storage==prior);
    }
    dm_game_frame_sample(at+1000000000ull,100);CHECK(fabs(ratio()-.25)<1e-6);
    at+=1000000000ull;dm_game_frame_sample(at+100000,101);CHECK(fabs(ratio()-.25)<1e-6);
    at+=100000;dm_game_frame_sample(at+100000000,102);CHECK(fabs(ratio()-2)<1e-6);
    dm_game_frame_sample(at,103);CHECK(fabs(ratio()-2)<1e-6); // backwards clock does not produce negative time
    atomic_store(g_accepted, float_bits(1.f) | (1ull<<32));
    CHECK(dm_game_frame_target()==30);CHECK(fabs(dm_game_frame_seconds()-1./30)<1e-8);
    atomic_store(g_accepted, float_bits(.5f) | (1ull<<32));CHECK(dm_game_frame_target()==60);
    atomic_store(g_accepted, float_bits(.3333333f));CHECK(dm_game_frame_target()==120);
    g_ratio=NULL;g_accepted=NULL;CHECK(dm_game_frame_seconds()==0);
    patch_contract();
    printf("MAC_TIMING checks=%u failed=%u\n",checks,failed);return failed!=0;
}
