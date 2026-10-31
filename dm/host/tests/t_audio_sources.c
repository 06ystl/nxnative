// Synthetic guest memory only: no game or controller is opened.
#include "../audio_sources_mac.c"
#include "audio_wave_fixture.h"
static int checks,failed,gate=1;static unsigned calls;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
void gate_obs_set(int id,void(*fn)(const uint64_t*)){(void)id;(void)fn;}
int gate_obs_present(int id){return gate&&id==OBS_AUDIO_EVENT;}
static void ptr(void *p,void *v){uint64_t a=(uintptr_t)v;memcpy(p,&a,8);}
static void output(const float *p,unsigned n){(void)p;(void)n;calls++;}
int main(void){
    CHECK(event_matches("Shoot", "Shoot")&&!event_matches("Shoot", "ShootVoice"),"plain event names match exactly");
    CHECK(event_matches("FirstLand_*", "FirstLand_Small")&&!event_matches("FirstLand_*", "NpcFirstLand_Small"),"prefix selection stays anchored");
    CHECK(event_matches("*FootStep", "NpcFootStep")&&!event_matches("*FootStep", "NpcFootStepVoice"),"suffix selection stays anchored");
    CHECK(event_matches("Shoot,*FootStep*,PlayerHit", "NpcFootStep_Left")&&event_matches("Shoot,*FootStep*,PlayerHit", "PlayerHit"),"comma lists combine exact and substring selection");
    CHECK(!event_matches("Shoot,*FootStep*", "shoot")&&!event_matches("Shoot,*FootStep*", "BattleBgm"),"selection is case-sensitive and excludes unrelated events");
    if(!layouts[0].build)return 0;
    const dm_audio_source_layout *l=layouts;uint8_t *image=calloc(1,0x2000000);
    uint8_t info[256]={0},player[256]={0},event[256]={0},resource[64]={0},node[256]={0},sound[512]={0},wp[256]={0},wave[2048];
    char name[96]="PlayerFootStep";uint64_t regs[31]={0};
    module_t m={0};strcpy(m.name,"main");strcpy(m.build_id,l->build);m.base=image;m.size=0x2000000;
    setenv("DM_AUDIO_HAPTICS","1",1);CHECK(dm_audio_sources_prepare(&m,1),"verified build with new common-event gate");
    ptr(image+l->info_global,info);ptr(info+l->player_field,player);player[l->life_field]=l->live;put32(image+l->mode_global,l->playing);
    put32(event+l->event_gen,9);ptr(event+l->event_resource,resource);ptr(resource+l->resource_name,name);
    ptr(event+l->head_field,node);ptr(node,event+l->head_field);ptr(node+l->node_parent,event);put32(node+l->node_phase,2);
    ptr(node+l->handle_field,sound);put32(node+l->handle_gen,13);put32(sound+l->sound_gen,13);put32(sound+l->sound_state,1);
    ptr(sound+l->sound_player,wp);ptr(wp,image+l->player_vtable);ptr(wp+l->wave_field,wave);
    wave_fixture(wave,sizeof wave,1,480);uint64_t data=(uintptr_t)(wave+0x100);
    regs[l->event_reg]=(uintptr_t)event;dm_audio_sources_submit=output;dm_audio_sources_set_active(1);
    dm_audio_sources_observe(regs);unsigned e=dm_audio_sources_begin();CHECK(e&&!dm_audio_sources_source(data),"delayed toe waits for activation");
    put32(node+l->node_phase,l->phase_first);dm_audio_sources_begin();CHECK(dm_audio_sources_source(data),"player footstep selects original SDK source");
    CHECK(calls==0,"identification never synthesizes or plays an independent recording");
    CHECK(!dm_audio_sources_source(data+8),"unrelated buffer is not selected");
    put32(event+l->event_gen,10);CHECK(!dm_audio_sources_source(data),"retired event cannot select a reused source");
    strcpy(name,"NpcFootStep");dm_audio_sources_observe(regs);dm_audio_sources_begin();CHECK(dm_audio_sources_source(data),"NPC footsteps accepted without actor identity filtering");
    const char *selected_names[]={"PlayerAttackNormal1","FirstLand_Small","PlayerHit","Shoot","Release1","ShieldEquip","EquipNoise_Call","ReactionWaterHitPuddle",
        "ParashawlEquip","ParashawlGlideMove","ParashawlGlideAscendant","ParashawlUnEquip",
        "SwimWaitHand","SwimWaitKick","SwimMoveHand","SwimMoveKick","SwimDashKickWaterHit","SwimWaterfallUp",
        "PlayerClimbWeakHandL","PlayerClimbStrongFootR","PlayerLadderStep_FootL","PlayerDragSlip","FallFlapBig","PlayerJumpKick_InWater"};
    uint32_t generation=10;
    for(unsigned i=0;i<sizeof selected_names/sizeof *selected_names;i++){
        put32(event+l->event_gen,++generation);strcpy(name,selected_names[i]);dm_audio_sources_observe(regs);dm_audio_sources_begin();
        CHECK(dm_audio_sources_source(data),"verified action, landing and impact events select original SDK sources");
    }
    const char *excluded_names[]={"Blank_SknMiddle","Voice","PV405","PV000_00","RiverWide","Pa_LocationNameS_00_open","BattleBgm","GameParasailBgm","ParashawlDucking","SwimAngry","HorseNushi_Vo_CryStrong"};
    for(unsigned i=0;i<sizeof excluded_names/sizeof *excluded_names;i++){
        put32(event+l->event_gen,++generation);strcpy(name,excluded_names[i]);dm_audio_sources_observe(regs);dm_audio_sources_begin();
        CHECK(!dm_audio_sources_source(data),"voice, music, UI and unselected ambient events never enter the selected stream");
    }
    put32(event+l->event_gen,++generation);strcpy(name,"PlayerFootStep");dm_audio_sources_observe(regs);dm_audio_sources_begin();
    put32(sound+l->sound_gen,14);CHECK(!dm_audio_sources_source(data),"reused sound generation rejected");put32(node+l->handle_gen,14);
    memcpy(wave,"WAIT",4);dm_audio_sources_observe(regs);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"unfinished wave ignored");
    memcpy(wave,"FWAV",4);dm_audio_sources_begin();CHECK(dm_audio_sources_source(data),"unfinished wave can become ready");
    float pcm[4]={.1f,.2f,0,0};dm_audio_sources_finish(e,pcm,2);CHECK(calls==1,"processed PCM reaches selected output");
    put32(image+l->mode_global,1);CHECK(!dm_audio_sources_begin()&&!dm_audio_sources_source(data),"menu suppresses selected sources");
    put32(image+l->mode_global,l->playing);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"menu exit cannot revive old events");
    strcpy(name,"Voice");dm_audio_sources_observe(regs);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"dialogue is not a footstep");
    strcpy(name,"PlayerFootStep");dm_audio_sources_observe(regs);e=dm_audio_sources_begin();CHECK(dm_audio_sources_source(data),"fresh event resumes");
    dm_audio_sources_set_active(0);dm_audio_sources_set_active(1);dm_audio_sources_finish(e,pcm,2);CHECK(calls==1,"pause/resume rejects an in-flight old block");
    dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"resume invalidates source identities");
    wave[0x49]=1;strcpy(name,"ParashawlGlideMove");dm_audio_sources_observe(regs);e=dm_audio_sources_begin();
    CHECK(dm_audio_sources_source(data),"glider loop registers");
    put32(image+l->mode_global,1);dm_audio_sources_finish(e,pcm,2);
    CHECK(calls==1,"menu rejects an in-flight playing block");
    CHECK(!dm_audio_sources_begin()&&!dm_audio_sources_source(data),"live loop is silent in menu");
    put32(image+l->mode_global,l->playing);e=dm_audio_sources_begin();
    CHECK(dm_audio_sources_source(data),"same live glider loop resumes without another event");
    dm_audio_sources_finish(e,pcm,2);CHECK(calls==2,"resumed loop can submit processed PCM");
    put32(image+l->mode_global,1);dm_audio_sources_begin();put32(sound+l->sound_state,l->inactive_state);dm_audio_sources_begin();
    put32(image+l->mode_global,l->playing);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"loop retired during pause never resumes");
    put32(sound+l->sound_state,1);dm_audio_sources_observe(regs);dm_audio_sources_begin();
    put32(image+l->mode_global,1);dm_audio_sources_begin();put32(event+l->event_gen,++generation);
    put32(image+l->mode_global,l->playing);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"reused event generation cannot revive a loop");
    dm_audio_sources_observe(regs);dm_audio_sources_begin();put32(image+l->mode_global,1);dm_audio_sources_begin();
    player[l->life_field]=l->live+1;dm_audio_sources_begin();player[l->life_field]=l->live;
    put32(image+l->mode_global,l->playing);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"player teardown clears paused loops");
    dm_audio_sources_observe(regs);dm_audio_sources_begin();put32(image+l->mode_global,1);dm_audio_sources_begin();
    uint8_t other_player[256]={0};other_player[l->life_field]=l->live;ptr(info+l->player_field,other_player);
    put32(image+l->mode_global,l->playing);dm_audio_sources_begin();CHECK(!dm_audio_sources_source(data),"another player cannot inherit a paused loop");
    ptr(info+l->player_field,player);dm_audio_sources_begin();wave[0x49]=0;
    uint8_t held_event[256]={0},held_sound[512]={0},held_wave[2048];
    put32(held_event+l->event_gen,1);put32(held_sound+l->sound_gen,1);put32(held_sound+l->sound_state,1);
    wave_fixture(held_wave,sizeof held_wave,1,480);clear_sources();
    sound_key held={(uintptr_t)held_event,(uintptr_t)held_sound,1,1};
    CHECK(register_wave(held,(uintptr_t)held_wave),"long-running source registers");
    int retained=1;
    for(unsigned i=0;i<SOURCES*2;i++){
        put32(event+l->event_gen,++generation);
        sound_key short_voice={(uintptr_t)event,(uintptr_t)sound,generation,14};
        if(!register_wave(short_voice,(uintptr_t)wave)||!dm_audio_sources_source((uintptr_t)held_wave+0x100))retained=0;
    }
    CHECK(retained,"a continuous glide/water voice survives more short effects than the source-table size");
    for(unsigned i=0;i<SOURCES;i++)sources[i]=sources[0];
    put32(event+l->event_gen,++generation);sound_key fresh={(uintptr_t)event,(uintptr_t)sound,generation,14};
    CHECK(!register_wave(fresh,(uintptr_t)wave)&&dm_audio_sources_source((uintptr_t)held_wave+0x100),"full live table retains ongoing effects while a new voice waits");
    sources[17].channels=0;CHECK(register_wave(fresh,(uintptr_t)wave),"pending voice registers when a slot becomes available");
    gate=0;CHECK(!dm_audio_sources_prepare(&m,1),"old player-only rewritten gate is insufficient");gate=1;strcpy(m.build_id,"unknown");CHECK(!dm_audio_sources_prepare(&m,1),"unknown build rejected");
    free(image);printf("Audio event sources: %d checks, %d failures\n",checks,failed);return !!failed;
}
