#include "audio_footsteps_mac.h"
#include "audio_wave.h"
#include <mach/mach.h>
#include <stdatomic.h>
#include <math.h>

enum { EVENTS=32, VOICES=32, SEEN=128, FRAME_LIMIT=960, WAVE_LIMIT=1024*1024 };
static const dm_foot_layout layouts[]={DM_GAME_MAC_AUDIO_FOOTSTEPS};
static const dm_foot_layout *layout;
static uint64_t base;
static int configured;
static _Atomic int active;
static _Atomic unsigned epoch;
static unsigned rendered_epoch, next_event, next_seen;
static pthread_mutex_t event_lock=PTHREAD_MUTEX_INITIALIZER;
typedef struct {uint64_t event,player;uint32_t generation,epoch;} foot_event;
static foot_event events[EVENTS];
typedef struct {uint64_t event,sound;uint32_t event_gen,sound_gen;} sound_key;
static sound_key seen[SEEN];
typedef struct {float *pcm;uint32_t frames,rate;double position;} foot_voice;
static foot_voice voices[VOICES];
void (*dm_footsteps_submit)(const float*,unsigned);
static unsigned wave_starts;
static uint64_t rendered_player;

static int guest_read(void *ctx,uint64_t at,void *out,size_t n){
    (void)ctx;if(!at||at>UINT64_MAX-n)return 0;vm_size_t got=0;
    return !vm_read_overwrite(mach_task_self(),at,n,(vm_address_t)out,&got)&&got==n;
}
static dm_foot_read_fn read_memory=guest_read;
static void *read_context;
#define RD(at,v) read_memory(read_context,(at),&(v),sizeof(v))
static uint64_t current_player(void){
    uint32_t mode;uint64_t info,p;uint8_t life;
    if(!layout||!RD(base+layout->mode_global,mode)||mode!=layout->playing||
       !RD(base+layout->info_global,info)||!info||!RD(info+layout->player_field,p)||!p||
       !RD(p+layout->life_field,life)||life!=layout->live)return 0;
    return p;
}
static void clear_render(void){
    for(unsigned i=0;i<VOICES;i++){free(voices[i].pcm);voices[i]=(foot_voice){0};}
    memset(seen,0,sizeof seen);next_seen=0;
}
void dm_footsteps_set_active(int on){
    int value=!!on&&configured;
    if(atomic_exchange(&active,value)!=value)atomic_fetch_add(&epoch,1);
}
int dm_footsteps_configured(void){return configured;}
void dm_footsteps_observe(const uint64_t *regs){
    if(!atomic_load(&active))return;
    unsigned generation_epoch=atomic_load(&epoch);
    uint64_t player=current_player(),actor,event,res,name;
    uint32_t gen,handle_gen;
    if(!player||!RD(regs[layout->actor_reg]+layout->actor_field,actor)||actor!=player||
       !RD(regs[layout->result_reg],event)||!event||!RD(event+layout->event_gen,gen)||
       !RD(regs[layout->result_reg]+8,handle_gen)||handle_gen!=gen||
       !RD(event+layout->event_resource,res)||!res||!RD(res+layout->resource_name,name)||!name)return;
    char text[64];if(!read_memory(read_context,name,text,sizeof text))return;text[sizeof text-1]=0;
    if(strncmp(text,layout->event_prefix,strlen(layout->event_prefix)))return;
    if(current_player()!=player)return;
    pthread_mutex_lock(&event_lock);
    events[next_event++%EVENTS]=(foot_event){event,player,gen,generation_epoch};
    pthread_mutex_unlock(&event_lock);
}
static int already_seen(sound_key key){
    for(unsigned i=0;i<SEEN;i++)if(seen[i].event==key.event&&seen[i].sound==key.sound&&
        seen[i].event_gen==key.event_gen&&seen[i].sound_gen==key.sound_gen)return 1;
    return 0;
}
static int begin_wave(sound_key key,uint64_t wave){
    uint8_t header[0x40];uint32_t bytes;
    if(!read_memory(read_context,wave,header,sizeof header)||memcmp(header,"FWAV",4))return 0;
    memcpy(&bytes,header+12,4);if(bytes<sizeof header||bytes>WAVE_LIMIT)return 0;
    uint8_t *copy=malloc(bytes);if(!copy)return 0;
    float *pcm=NULL;uint32_t n=0,hz=0,gen;
    int ok=read_memory(read_context,wave,copy,bytes)&&RD(key.sound+layout->sound_gen,gen)&&gen==key.sound_gen&&
           dm_fwav_decode(copy,bytes,&pcm,&n,&hz);
    free(copy);if(!ok)return 0;
    for(unsigned i=0;i<VOICES;i++)if(!voices[i].pcm){voices[i]=(foot_voice){pcm,n,hz,0};wave_starts++;return 1;}
    free(pcm);return 0;
}
static int collect_event(foot_event e,uint64_t player,unsigned current_epoch){
    uint32_t gen;uint64_t node;
    if(!e.event||e.epoch!=current_epoch||e.player!=player||!RD(e.event+layout->event_gen,gen)||gen!=e.generation||
       !RD(e.event+layout->head_field,node))return 0;
    uint64_t head=e.event+layout->head_field;int pending=0;
    for(unsigned count=0;node&&node!=head&&count<32;count++){
        uint64_t parent,next,sound,wave_player,vtable,wave;uint32_t phase,id,actual_id,state;
        if(!RD(node,next)||!RD(node+layout->node_parent,parent)||parent!=e.event||!RD(node+layout->node_phase,phase))return 0;
        if(phase<layout->phase_first)pending=1; // A delayed child has no sound handle yet.
        if(phase>=layout->phase_first&&phase<=layout->phase_last&&
           RD(node+layout->handle_field,sound)&&sound&&RD(node+layout->handle_gen,id)&&
           RD(sound+layout->sound_gen,actual_id)&&actual_id==id&&RD(sound+layout->sound_state,state)&&state&&state!=layout->inactive_state){
            sound_key key={e.event,sound,e.generation,id};
            if(!already_seen(key)){
                int started=0;uint32_t check;uint64_t again;
                if(RD(sound+layout->sound_player,wave_player)&&wave_player&&RD(wave_player,vtable)&&
                   vtable==base+layout->player_vtable&&RD(wave_player+layout->wave_field,wave)&&wave&&
                   RD(e.event+layout->event_gen,check)&&check==e.generation&&RD(node+layout->handle_field,again)&&again==sound)
                    started=begin_wave(key,wave);
                if(started)seen[next_seen++%SEEN]=key;
                else pending=1;
            }
        }
        if(next==node)return 0;node=next;
    }
    return pending;
}
void dm_footsteps_render(unsigned frames,unsigned rate){
    if(!configured||!dm_footsteps_submit||!frames||frames>FRAME_LIMIT||rate!=48000)return;
    unsigned current_epoch=atomic_load(&epoch);
    if(rendered_epoch!=current_epoch){clear_render();rendered_epoch=current_epoch;}
    if(!atomic_load(&active))return;
    float stereo[FRAME_LIMIT*2]={0};uint64_t player=current_player();
    if(player!=rendered_player){clear_render();rendered_player=player;}
    if(!player){clear_render();pthread_mutex_lock(&event_lock);memset(events,0,sizeof events);pthread_mutex_unlock(&event_lock);}
    else {
        foot_event copy[EVENTS];pthread_mutex_lock(&event_lock);memcpy(copy,events,sizeof copy);pthread_mutex_unlock(&event_lock);
        for(unsigned i=0;i<EVENTS;i++)if(copy[i].event&&!collect_event(copy[i],player,current_epoch)){
            // Retire consumed events instead of walking old sound graphs at 200 Hz.
            pthread_mutex_lock(&event_lock);
            if(events[i].event==copy[i].event&&events[i].generation==copy[i].generation&&events[i].epoch==copy[i].epoch)
                events[i]=(foot_event){0};
            pthread_mutex_unlock(&event_lock);
        }
        for(unsigned i=0;i<VOICES;i++)if(voices[i].pcm){
            foot_voice *v=&voices[i];double step=(double)v->rate/rate;
            for(unsigned j=0;j<frames&&v->position<v->frames;j++,v->position+=step){
                uint32_t k=(uint32_t)v->position;float a=v->pcm[k],b=k+1<v->frames?v->pcm[k+1]:a;
                float sample=a+(b-a)*(float)(v->position-k);stereo[j*2]+=sample;stereo[j*2+1]+=sample;
            }
            if(v->position>=v->frames){free(v->pcm);*v=(foot_voice){0};}
        }
    }
    if(atomic_load(&active)&&atomic_load(&epoch)==current_epoch)dm_footsteps_submit(stereo,frames);
}
int dm_footsteps_prepare(const module_t *modules,int count){
    configured=0;layout=NULL;base=0;
    const char *enable=getenv("DM_AUDIO_HAPTICS");if(!enable||strcmp(enable,"1"))return 0;
    for(int i=0;i<count;i++)if(!strcmp(modules[i].name,"main"))for(size_t k=0;k<sizeof layouts/sizeof *layouts;k++){
        const dm_foot_layout *l=&layouts[k];const module_t *m=&modules[i];
        if(!l->build||strcmp(l->build,m->build_id))continue;
        uint32_t offsets[]={l->mode_global,l->info_global,l->player_vtable};int valid=1;
        for(unsigned j=0;j<3;j++)if(offsets[j]>m->size||m->size-offsets[j]<8)valid=0;
        if(!valid||!gate_obs_present(OBS_PLAYER_FOOTSTEP))break;
        layout=l;base=(uint64_t)m->base;configured=1;gate_obs_set(OBS_PLAYER_FOOTSTEP,dm_footsteps_observe);
        LOG("Audio haptics: player footstep source enabled for main %s",m->build_id);return 1;
    }
    LOG("Audio haptics: this build has no verified footstep observation gate; using game rumble");return 0;
}
