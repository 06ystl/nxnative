#include "audio_footsteps_mac.h"
#include "audio_wave.h"
#include <mach/mach.h>
#include <stdatomic.h>

enum { EVENTS=64, SOURCES=128, WAVE_LIMIT=1024*1024 };
static const dm_foot_layout layouts[]={DM_GAME_MAC_AUDIO_FOOTSTEPS};
static const dm_foot_layout *layout;
static uint64_t base,rendered_player;
static int configured;
static _Atomic int active;
static _Atomic unsigned epoch=1;
static unsigned rendered_epoch,next_event,next_source;
static pthread_mutex_t event_lock=PTHREAD_MUTEX_INITIALIZER;
typedef struct {uint64_t event,player;uint32_t generation,epoch;} foot_event;
static foot_event events[EVENTS];
typedef struct {uint64_t event,sound;uint32_t event_gen,sound_gen;} sound_key;
typedef struct {sound_key key;uint64_t data[DM_WAVE_CHANNELS];unsigned channels;} foot_source;
static foot_source sources[SOURCES];
void (*dm_footsteps_submit)(const float*,unsigned);

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
static void clear_sources(void){memset(sources,0,sizeof sources);next_source=0;}
void dm_footsteps_set_active(int on){
    int value=!!on&&configured;
    if(atomic_exchange(&active,value)!=value)atomic_fetch_add(&epoch,1);
}
int dm_footsteps_configured(void){return configured;}
void dm_footsteps_observe(const uint64_t *regs){
    if(!atomic_load(&active))return;
    unsigned e=atomic_load(&epoch);uint64_t player=current_player(),event=regs[layout->event_reg],res,name;uint32_t gen;
    if(!player||!event||!RD(event+layout->event_gen,gen)||!RD(event+layout->event_resource,res)||!res||
       !RD(res+layout->resource_name,name)||!name)return;
    char text[96];if(!read_memory(read_context,name,text,sizeof text))return;text[sizeof text-1]=0;
    // The event names distinguish footsteps; source actor identity does not set strength.
    if(!strstr(text,layout->event_token)||current_player()!=player)return;
    pthread_mutex_lock(&event_lock);
    events[next_event++%EVENTS]=(foot_event){event,player,gen,e};
    pthread_mutex_unlock(&event_lock);
}
static int same_key(sound_key a,sound_key b){return a.event==b.event&&a.sound==b.sound&&a.event_gen==b.event_gen&&a.sound_gen==b.sound_gen;}
static int live_key(sound_key key){
    uint32_t gen,state;
    return RD(key.event+layout->event_gen,gen)&&gen==key.event_gen&&RD(key.sound+layout->sound_gen,gen)&&gen==key.sound_gen&&
           RD(key.sound+layout->sound_state,state)&&state&&state!=layout->inactive_state;
}
static int register_wave(sound_key key,uint64_t wave){
    uint8_t header[0x40];uint32_t bytes;
    if(!read_memory(read_context,wave,header,sizeof header)||memcmp(header,"FWAV",4))return 0;
    memcpy(&bytes,header+12,4);if(bytes<sizeof header||bytes>WAVE_LIMIT)return 0;
    uint8_t *copy=malloc(bytes);if(!copy)return 0;
    dm_wave_source info;
    int ok=read_memory(read_context,wave,copy,bytes)&&dm_fwav_source(copy,bytes,&info)&&live_key(key);
    free(copy);if(!ok)return 0;
    foot_source *s=&sources[next_source++%SOURCES];*s=(foot_source){.key=key,.channels=info.channels};
    for(unsigned i=0;i<info.channels;i++)s->data[i]=wave+info.data_offset[i];
    return 1;
}
static int collect_event(foot_event e,uint64_t player,unsigned current_epoch){
    uint32_t gen;uint64_t node;
    if(!e.event||e.epoch!=current_epoch||e.player!=player||!RD(e.event+layout->event_gen,gen)||gen!=e.generation||
       !RD(e.event+layout->head_field,node))return 0;
    uint64_t head=e.event+layout->head_field;int pending=0;
    for(unsigned count=0;node&&node!=head&&count<32;count++){
        uint64_t parent,next,sound,wave_player,vtable,wave;uint32_t phase,id;
        if(!RD(node,next)||!RD(node+layout->node_parent,parent)||parent!=e.event||!RD(node+layout->node_phase,phase))return 0;
        if(phase<layout->phase_first)pending=1;
        if(phase>=layout->phase_first&&phase<=layout->phase_last&&RD(node+layout->handle_field,sound)&&sound&&RD(node+layout->handle_gen,id)){
            sound_key key={e.event,sound,e.generation,id};int registered=0;
            for(unsigned i=0;i<SOURCES;i++)if(sources[i].channels&&same_key(sources[i].key,key)){registered=1;break;}
            if(!registered&&live_key(key)){
                if(RD(sound+layout->sound_player,wave_player)&&wave_player&&RD(wave_player,vtable)&&
                   vtable==base+layout->player_vtable&&RD(wave_player+layout->wave_field,wave)&&wave)
                    registered=register_wave(key,wave);
                if(!registered)pending=1;
            }
        }
        if(next==node)return 0;node=next;
    }
    return pending;
}
unsigned dm_footsteps_begin(void){
    if(!configured||!dm_footsteps_submit)return 0;
    unsigned e=atomic_load(&epoch);
    if(rendered_epoch!=e){clear_sources();rendered_epoch=e;}
    if(!atomic_load(&active))return 0;
    uint64_t player=current_player();
    if(player!=rendered_player){clear_sources();rendered_player=player;}
    if(!player){
        clear_sources();pthread_mutex_lock(&event_lock);memset(events,0,sizeof events);pthread_mutex_unlock(&event_lock);return 0;
    }
    foot_event copy[EVENTS];pthread_mutex_lock(&event_lock);memcpy(copy,events,sizeof copy);pthread_mutex_unlock(&event_lock);
    for(unsigned i=0;i<EVENTS;i++)if(copy[i].event&&!collect_event(copy[i],player,e)){
        pthread_mutex_lock(&event_lock);
        if(events[i].event==copy[i].event&&events[i].generation==copy[i].generation&&events[i].epoch==copy[i].epoch)events[i]=(foot_event){0};
        pthread_mutex_unlock(&event_lock);
    }
    return e;
}
int dm_footsteps_source(uint64_t data){
    if(!data||!atomic_load(&active)||atomic_load(&epoch)!=rendered_epoch||!rendered_player)return 0;
    for(unsigned i=0;i<SOURCES;i++)for(unsigned k=0;k<sources[i].channels;k++)if(sources[i].data[k]==data){
        if(live_key(sources[i].key))return 1;
        sources[i].channels=0;break;
    }
    return 0;
}
void dm_footsteps_finish(unsigned e,const float *stereo,unsigned frames){
    if(!e||!dm_footsteps_submit||!atomic_load(&active)||atomic_load(&epoch)!=e)return;
    if(current_player()!=rendered_player){clear_sources();return;}
    dm_footsteps_submit(stereo,frames);
}
int dm_footsteps_prepare(const module_t *modules,int count){
    configured=0;layout=NULL;base=0;
    const char *enable=getenv("DM_AUDIO_HAPTICS");if(!enable||strcmp(enable,"1"))return 0;
    for(int i=0;i<count;i++)if(!strcmp(modules[i].name,"main"))for(size_t k=0;k<sizeof layouts/sizeof *layouts;k++){
        const dm_foot_layout *l=&layouts[k];const module_t *m=&modules[i];if(!l->build||strcmp(l->build,m->build_id))continue;
        uint32_t offsets[]={l->mode_global,l->info_global,l->player_vtable};int valid=1;
        for(unsigned j=0;j<3;j++)if(offsets[j]>m->size||m->size-offsets[j]<8)valid=0;
        if(!valid||!gate_obs_present(OBS_AUDIO_EVENT))break;
        layout=l;base=(uint64_t)m->base;configured=1;gate_obs_set(OBS_AUDIO_EVENT,dm_footsteps_observe);
        LOG("Audio haptics: spatial player/NPC footsteps enabled for main %s",m->build_id);return 1;
    }
    LOG("Audio haptics: this build needs a verified sound-event observation gate; using game rumble");return 0;
}
