// Synthetic guest memory only: no game or controller is opened.
#include "../audio_footsteps_mac.c"
#include "audio_wave_fixture.h"
static int checks,failed,gate=1;static unsigned calls;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
void gate_obs_set(int id,void(*fn)(const uint64_t*)){(void)id;(void)fn;}
int gate_obs_present(int id){return gate&&id==OBS_AUDIO_EVENT;}
static void ptr(void *p,void *v){uint64_t a=(uintptr_t)v;memcpy(p,&a,8);}
static void output(const float *p,unsigned n){(void)p;(void)n;calls++;}
int main(void){
    if(!layouts[0].build)return 0;
    const dm_foot_layout *l=layouts;uint8_t *image=calloc(1,0x2000000);
    uint8_t info[256]={0},player[256]={0},event[256]={0},resource[64]={0},node[256]={0},sound[512]={0},wp[256]={0},wave[2048];
    char name[96]="PlayerFootStep";uint64_t regs[31]={0};
    module_t m={0};strcpy(m.name,"main");strcpy(m.build_id,l->build);m.base=image;m.size=0x2000000;
    setenv("DM_AUDIO_HAPTICS","1",1);CHECK(dm_footsteps_prepare(&m,1),"verified build with new common-event gate");
    ptr(image+l->info_global,info);ptr(info+l->player_field,player);player[l->life_field]=l->live;put32(image+l->mode_global,l->playing);
    put32(event+l->event_gen,9);ptr(event+l->event_resource,resource);ptr(resource+l->resource_name,name);
    ptr(event+l->head_field,node);ptr(node,event+l->head_field);ptr(node+l->node_parent,event);put32(node+l->node_phase,2);
    ptr(node+l->handle_field,sound);put32(node+l->handle_gen,13);put32(sound+l->sound_gen,13);put32(sound+l->sound_state,1);
    ptr(sound+l->sound_player,wp);ptr(wp,image+l->player_vtable);ptr(wp+l->wave_field,wave);
    wave_fixture(wave,sizeof wave,1,480);uint64_t data=(uintptr_t)(wave+0x100);
    regs[l->event_reg]=(uintptr_t)event;dm_footsteps_submit=output;dm_footsteps_set_active(1);
    dm_footsteps_observe(regs);unsigned e=dm_footsteps_begin();CHECK(e&&!dm_footsteps_source(data),"delayed toe waits for activation");
    put32(node+l->node_phase,l->phase_first);dm_footsteps_begin();CHECK(dm_footsteps_source(data),"player footstep selects original SDK source");
    CHECK(calls==0,"identification never synthesizes or plays an independent recording");
    CHECK(!dm_footsteps_source(data+8),"unrelated buffer is not selected");
    put32(event+l->event_gen,10);CHECK(!dm_footsteps_source(data),"retired event cannot select a reused source");
    strcpy(name,"NpcFootStep");dm_footsteps_observe(regs);dm_footsteps_begin();CHECK(dm_footsteps_source(data),"NPC footsteps accepted without actor identity filtering");
    put32(sound+l->sound_gen,14);CHECK(!dm_footsteps_source(data),"reused sound generation rejected");put32(node+l->handle_gen,14);
    memcpy(wave,"WAIT",4);dm_footsteps_observe(regs);dm_footsteps_begin();CHECK(!dm_footsteps_source(data),"unfinished wave ignored");
    memcpy(wave,"FWAV",4);dm_footsteps_begin();CHECK(dm_footsteps_source(data),"unfinished wave can become ready");
    float pcm[4]={.1f,.2f,0,0};dm_footsteps_finish(e,pcm,2);CHECK(calls==1,"processed PCM reaches selected output");
    put32(image+l->mode_global,1);CHECK(!dm_footsteps_begin()&&!dm_footsteps_source(data),"menu clears all selected sources");
    put32(image+l->mode_global,l->playing);dm_footsteps_begin();CHECK(!dm_footsteps_source(data),"menu exit cannot revive old events");
    strcpy(name,"Voice");dm_footsteps_observe(regs);dm_footsteps_begin();CHECK(!dm_footsteps_source(data),"dialogue is not a footstep");
    strcpy(name,"PlayerFootStep");dm_footsteps_observe(regs);e=dm_footsteps_begin();CHECK(dm_footsteps_source(data),"fresh event resumes");
    dm_footsteps_set_active(0);dm_footsteps_set_active(1);dm_footsteps_finish(e,pcm,2);CHECK(calls==1,"pause/resume rejects an in-flight old block");
    dm_footsteps_begin();CHECK(!dm_footsteps_source(data),"resume invalidates source identities");
    gate=0;CHECK(!dm_footsteps_prepare(&m,1),"old player-only rewritten gate is insufficient");gate=1;strcpy(m.build_id,"unknown");CHECK(!dm_footsteps_prepare(&m,1),"unknown build rejected");
    free(image);printf("Footstep sources: %d checks, %d failures\n",checks,failed);return !!failed;
}
