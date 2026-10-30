// Exercise command routing and before/after capture with simulated SDK endpoints.
#include "../audio_haptics_dsp_mac.c"
#include "audio_wave_fixture.h"
static int checks,failed,dispatches,decodes,submits;static unsigned enabled=7;
static float result[16];static uint8_t commands[4096],buffers[4*48],args[0x50];static int32_t audio[40*4];
static unsigned used,count;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
unsigned dm_footsteps_begin(void){return enabled;}
int dm_footsteps_source(uint64_t p){return p==0xfeed;}
void dm_footsteps_finish(unsigned e,const float *p,unsigned n){if(e==enabled){submits++;memcpy(result,p,n*8);}}
static void fake_decode(const void *a){(void)a;decodes++;}
static void fake_dispatch(void *processor,const void *data){
    (void)processor;const uint8_t *c=data;dispatches++;
    if(c[5]==6){memset(buffers,0,sizeof buffers);uint64_t value=u32(c+12)==0x10010001?0xfeed:0xbeef;memcpy(buffers,&value,8);uint64_t ptr=(uintptr_t)buffers;memcpy(args+0x18,&ptr,8);h_haptic_decode(args);}
    else if(c[5]==MIX_GROUP){for(unsigned j=0;j<4;j++){audio[j]+=1000;audio[4+j]+=250;audio[6*4+j]+=2000;}}
    else if(c[5]==MIX){unsigned a=u16(c+32),b=u16(c+34);for(unsigned j=0;j<4;j++)audio[b*4+j]+=(int32_t)(audio[a*4+j]*f32(c+36));}
    else if(c[5]==VOLUME){unsigned a=u16(c+32),b=u16(c+34);float g=ldexpf((int32_t)u32(c+36),-(int)c[31]);for(unsigned j=0;j<4;j++)audio[b*4+j]=(int32_t)(audio[a*4+j]*g);}
}
void *guest_sym(const char *name){return strstr(name,"DispatchCommand")?(void*)fake_dispatch:(void*)fake_decode;}
static uint8_t *add(unsigned kind,unsigned size,uint32_t node){uint8_t *c=commands+used;memset(c,0,size);put32(c,0xcafebabe);c[4]=1;c[5]=kind;put16(c+6,size);put32(c+12,node);used+=size;count++;return c;}
static void fixture(void){
    memset(commands,0,sizeof commands);memset(audio,0,sizeof audio);memset(result,0,sizeof result);used=32;count=0;dispatches=decodes=submits=0;enabled=7;
    for(unsigned i=0;i<2;i++){
        add(6,0x108,0x10010001+i);uint8_t *c=add(MIX_GROUP,0x150,0x10010001+i);put32(c+32,3);put16(c+0x54,0);put16(c+0x56,1);put16(c+0x58,6);
    }
    uint8_t *c=add(AUX,0x58,0x20010000);put16(c+32,6);put16(c+34,6);
    for(unsigned i=0;i<3;i++){c=add(MIX,0x28,0x20010000);put16(c+32,i==2?6:i);put16(c+34,i==1?25:24);float gain=1;memcpy(c+36,&gain,4);}
    for(unsigned i=0;i<2;i++){c=add(VOLUME,0x28,0x20000000);put16(c+32,24+i);put16(c+34,24+i);c[31]=23;put32(c+36,1u<<22);}
    c=add(DEVICE_SINK,0x148,0xf0000000);put32(c+0x130,2);put16(c+0x134,24);put16(c+0x136,25);
    put32(commands,used);put32(commands+4,count);uint64_t a=(uintptr_t)audio;memcpy(commands+8,&a,8);put32(commands+16,40);put32(commands+20,4);put32(commands+24,48000);
}
static void run(void){dm_audio_haptics_begin(commands,used);unsigned p=32;for(unsigned i=0;i<count;i++){h_haptic_dispatch(NULL,commands+p);p+=u16(commands+p+6);}dm_audio_haptics_end();}
int main(void){
    fixture();uint8_t saved[4096];memcpy(saved,commands,used);run();
    CHECK(submits==1&&result[0]==500/32768.f&&result[1]==125/32768.f,"original unequal L/R contribution includes downstream master gain");
    CHECK(dispatches==(int)count&&decodes==2,"SDK dispatch and decoding execute exactly once");
    CHECK(!memcmp(saved,commands,used),"capture never rewrites command bytes or DSP state pointers");
    int32_t original[160];memcpy(original,audio,sizeof audio);fixture();enabled=0;run();
    CHECK(!memcmp(original,audio,sizeof audio)&&!submits,"audible buffers identical with capture enabled or disabled");
    fixture();uint8_t *sink=commands+used-0x148;put16(sink+0x134,25);put16(sink+0x136,24);run();
    CHECK(result[0]==125/32768.f&&result[1]==500/32768.f,"sink routing determines actuator direction");
    fixture();put32(commands+32+12,0x10010002);run();CHECK(result[0]==0&&result[1]==0,"unselected sounds never enter haptics");
    fixture();put32(commands+16,MAX_BUFFERS+1);run();CHECK(!submits,"unsupported buffer dimensions disable capture without skipping original audio");
    fixture();put16(commands+32+6,0xffff);CHECK(!routes(commands,used),"truncated command rejected");
    fixture();commands[used-0x148+5]=99;CHECK(!routes(commands,used),"a real output sink is required");
    fixture();dm_audio_haptics_begin(commands,used);tap.stereo[0]=1;enabled=8;dm_audio_haptics_end();CHECK(!submits,"lifecycle epoch rejects stale output");
    printf("Spatial DSP capture: %d checks, %d failures\n",checks,failed);return !!failed;
}
