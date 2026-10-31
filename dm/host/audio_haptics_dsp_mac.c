// Observe the SDK's actual voice mix contributions. The original commands run
// once, with their original buffers/state; capture never changes audible audio.
#include "audio_haptics_dsp_mac.h"
#include "audio_sources_mac.h"
#include "hle.h"
#include <math.h>

enum { MAX_BUFFERS=256, MAX_SAMPLES=1024, MAX_COMMANDS=4096, MAX_VOICES=256, MAX_ROUTES=24 };
enum { VOLUME=7, VOLUME_RAMP=8, MIX=11, MIX_RAMP=12, MIX_GROUP=13, DEPOP_MIX=15,
       AUX=19, DEVICE_SINK=20, COPY=24, CLEAR=25 };
typedef struct {
    const uint8_t *start,*end,*current,*commands[MAX_COMMANDS];
    int32_t *mix;
    unsigned frames,buffers,epoch,nselected;
    uint32_t selected[MAX_VOICES];
    float route[MAX_BUFFERS][2],stereo[MAX_SAMPLES*2];
    int32_t before[MAX_ROUTES][MAX_SAMPLES];
} tap_state;
static tap_state tap; // hle_audren's render mutex owns all writes.
static _Thread_local int in_frame;
static uint16_t u16(const void *p){uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t u32(const void *p){uint32_t v;memcpy(&v,p,4);return v;}
static uint64_t u64(const void *p){uint64_t v;memcpy(&v,p,8);return v;}
static float f32(const void *p){float v;memcpy(&v,p,4);return v;}
static int valid_buffer(unsigned i){return i<tap.buffers;}
static int has_route(unsigned i){return valid_buffer(i)&&(tap.route[i][0]!=0||tap.route[i][1]!=0);}
static int selected(uint32_t node){for(unsigned i=0;i<tap.nselected;i++)if(tap.selected[i]==node)return 1;return 0;}
static int transfer(unsigned src,unsigned dst,float gain,int overwrite){
    if(!valid_buffer(src)||!valid_buffer(dst)||!isfinite(gain))return 0;
    float a=tap.route[dst][0],b=tap.route[dst][1];
    if(overwrite)tap.route[dst][0]=tap.route[dst][1]=0;
    tap.route[src][0]+=a*gain;tap.route[src][1]+=b*gain;return 1;
}
static int routes(const uint8_t *cl,size_t bytes){
    if(bytes<32||u32(cl)<32||u32(cl)>bytes)return 0;
    bytes=u32(cl);
    unsigned count=u32(cl+4);tap.frames=u32(cl+0x14);tap.buffers=u32(cl+0x10);
    if(!count||count>MAX_COMMANDS||!tap.frames||tap.frames>MAX_SAMPLES||!tap.buffers||tap.buffers>MAX_BUFFERS||u32(cl+0x18)!=48000||!u64(cl+8))return 0;
    const uint8_t **list=tap.commands,*p=cl+32;unsigned sinks=0;
    for(unsigned i=0;i<count;i++){
        if((size_t)(p-cl)>bytes||bytes-(size_t)(p-cl)<32||u32(p)!=0xcafebabe)return 0;
        unsigned size=u16(p+6);if(size<32||size>bytes-(size_t)(p-cl))return 0;
        list[i]=p;
        if((p[4]&1)&&p[5]==DEVICE_SINK){
            if(size<0x140||++sinks>1)return 0;unsigned channels=u32(p+0x130);
            if(channels!=1&&channels!=2&&channels!=6)return 0;
            // Exactly the audible output's 6 -> 2 coefficients (hle_audren.c).
            const float left[6]={1,0,23167.f/32768,8224.f/32768,23167.f/32768,0};
            const float right[6]={0,1,23167.f/32768,8224.f/32768,0,23167.f/32768};
            for(unsigned j=0;j<channels;j++){
                unsigned index=u16(p+0x134+2*j);if(!valid_buffer(index))return 0;
                tap.route[index][0]+=channels==1?1:left[j];tap.route[index][1]+=channels==1?1:right[j];
            }
        }
        p+=size;
    }
    if(!sinks)return 0;
    // Find the direct path from the voice output buses to the actual DeviceSink.
    // Auxiliary sends are processed by game callbacks and share other sounds'
    // history. Capture the spatial dry signal, not an invented reverb contribution.
    for(unsigned i=count;i-- >0;){
        p=list[i];if(!(p[4]&1))continue;
        if(u32(p+12)>>28==1)break; // SDK emits voices before downstream mixes.
        unsigned kind=p[5],size=u16(p+6);
        switch(kind){
        case DEVICE_SINK:case DEPOP_MIX:break;
        case VOLUME:
            if(size<0x28||p[0x1f]>30||!transfer(u16(p+0x20),u16(p+0x22),ldexpf((int32_t)u32(p+0x24),-(int)p[0x1f]),1))return 0;
            break;
        case MIX:
            if(size<0x28||!transfer(u16(p+0x20),u16(p+0x22),f32(p+0x24),0))return 0;
            break;
        case COPY:
            if(size<0x24||!transfer(u16(p+0x20),u16(p+0x22),1,1))return 0;
            break;
        case AUX:{
            if(size<0x24)return 0;unsigned dst=u16(p+0x22);if(!valid_buffer(dst))return 0;
            tap.route[dst][0]=tap.route[dst][1]=0;break;
        }
        case CLEAR:memset(tap.route,0,sizeof tap.route);break;
        default:return 0; // A different downstream graph needs its own validated transfer.
        }
    }
    tap.start=cl+32;tap.end=cl+bytes;tap.mix=(int32_t*)(uintptr_t)u64(cl+8);return 1;
}
void dm_audio_haptics_begin(const uint8_t *commands,size_t bytes){
    in_frame=0;tap.current=NULL;tap.nselected=0;
    tap.epoch=dm_audio_sources_begin();if(!tap.epoch)return;
    memset(tap.route,0,sizeof tap.route);memset(tap.stereo,0,sizeof tap.stereo);
    if(!routes(commands,bytes)){
        static int reported;if(!reported++){LOG("Audio haptics: unsupported downstream DSP graph; capture disabled");}
        tap.epoch=0;return;
    }
    in_frame=1;
}
void dm_audio_haptics_end(void){
    if(in_frame)dm_audio_sources_finish(tap.epoch,tap.stereo,tap.frames);
    in_frame=0;tap.current=NULL;
}
static unsigned destinations(const uint8_t *c,unsigned *out){
    unsigned kind=c[5],size=u16(c+6),n=0;
    if((kind==MIX||kind==MIX_RAMP)&&size>=0x28){unsigned dst=u16(c+0x22);if(has_route(dst))out[n++]=dst;}
    else if(kind==MIX_GROUP&&size>=0x150){
        unsigned count=u32(c+0x20);if(count>MAX_ROUTES)return 0;
        for(unsigned i=0;i<count;i++){
            unsigned dst=u16(c+0x54+2*i),j=0;
            for(;j<n;j++)if(out[j]==dst)break;
            if(j==n&&has_route(dst))out[n++]=dst;
        }
    }
    return n;
}
HLE_FORCE("_ZN2nn5audio3dsp20CommandListProcessor15DispatchCommandEPKNS0_13CommandHeaderE",
          "observe original spatial voice mix contributions for Mac USB haptics",void,h_haptic_dispatch,void *processor,const uint8_t *command){
    static void(*orig)(void*,const void*);if(!orig)orig=guest_sym("_ZN2nn5audio3dsp20CommandListProcessor15DispatchCommandEPKNS0_13CommandHeaderE");
    if(!in_frame){orig(processor,command);return;}
    uintptr_t at=(uintptr_t)command,first=(uintptr_t)tap.start,end=(uintptr_t)tap.end;
    if(at<first||at>end||end-at<32||u16(command+6)>end-at){orig(processor,command);return;}
    tap.current=command;unsigned output[MAX_ROUTES],n=selected(u32(command+12))?destinations(command,output):0;
    for(unsigned i=0;i<n;i++)memcpy(tap.before[i],tap.mix+(size_t)output[i]*tap.frames,tap.frames*4);
    orig(processor,command);
    for(unsigned i=0;i<n;i++){
        unsigned dst=output[i];const int32_t *after=tap.mix+(size_t)dst*tap.frames;
        for(unsigned j=0;j<tap.frames;j++){
            float contribution=(float)((int64_t)after[j]-tap.before[i][j])/32768.f;
            tap.stereo[2*j]+=contribution*tap.route[dst][0];tap.stereo[2*j+1]+=contribution*tap.route[dst][1];
        }
    }
    tap.current=NULL;
}
HLE_FORCE("_ZN2nn5audio3dsp21DecodeFromWaveBuffersERKNS1_25DecodeFromWaveBuffersArgsE",
          "identify selected footstep voices while preserving SDK decoding",void,h_haptic_decode,const uint8_t *args){
    static void(*orig)(const void*);if(!orig)orig=guest_sym("_ZN2nn5audio3dsp21DecodeFromWaveBuffersERKNS1_25DecodeFromWaveBuffersArgsE");
    orig(args);
    if(!in_frame||!tap.current||tap.current[5]<1||tap.current[5]>6)return;
    uint32_t node=u32(tap.current+12);if(selected(node)||tap.nselected>=MAX_VOICES)return;
    const uint8_t *buffers=(const uint8_t*)(uintptr_t)u64(args+0x18);if(!buffers)return;
    for(unsigned i=0;i<4;i++)if(dm_audio_sources_source(u64(buffers+48*i))){tap.selected[tap.nselected++]=node;break;}
}
