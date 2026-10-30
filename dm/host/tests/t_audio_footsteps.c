// Synthetic guest memory only: no game or controller is opened.
#include "../audio_footsteps_mac.c"
#include "audio_wave_fixture.h"
static int checks,failed,gate=1;static float peak;static unsigned calls;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
void gate_obs_set(int id,void(*fn)(const uint64_t*)){(void)id;(void)fn;}
int gate_obs_present(int id){return gate&&id==OBS_PLAYER_FOOTSTEP;}
static void ptr(void *p,void *v){uint64_t a=(uintptr_t)v;memcpy(p,&a,8);}
static void output(const float *p,unsigned n){calls++;for(unsigned i=0;i<2*n;i++)peak=fmaxf(peak,fabsf(p[i]));}
int main(void){
    if(!layouts[0].build)return 0;
    const dm_foot_layout *l=layouts;uint8_t *image=calloc(1,0x2000000);
    uint8_t info[256]={0},player[256]={0},meta[256]={0},event[256]={0},resource[64]={0},node[256]={0},sound[512]={0},wp[256]={0},wave[2048],handle[16]={0};
    char name[64]="PlayerFootStepNormal";uint64_t regs[31]={0};
    module_t m={0};strcpy(m.name,"main");strcpy(m.build_id,l->build);m.base=image;m.size=0x2000000;
    setenv("DM_AUDIO_HAPTICS","1",1);CHECK(dm_footsteps_prepare(&m,1),"verified build with observation gate");
    ptr(image+l->info_global,info);ptr(info+l->player_field,player);player[l->life_field]=l->live;put32(image+l->mode_global,l->playing);
    ptr(meta+l->actor_field,player);ptr(handle,event);put32(handle+8,9);put32(event+l->event_gen,9);ptr(event+l->event_resource,resource);ptr(resource+l->resource_name,name);
    ptr(event+l->head_field,node);ptr(node,event+l->head_field);ptr(node+l->node_parent,event);put32(node+l->node_phase,l->phase_first);
    ptr(node+l->handle_field,sound);put32(node+l->handle_gen,13);put32(sound+l->sound_gen,13);put32(sound+l->sound_state,1);
    ptr(sound+l->sound_player,wp);ptr(wp,image+l->player_vtable);ptr(wp+l->wave_field,wave);
    wave_fixture(wave,sizeof wave,1,480);for(unsigned i=0;i<480;i++)put16(wave+0x100+2*i,8192);
    regs[l->actor_reg]=(uintptr_t)meta;regs[l->result_reg]=(uintptr_t)handle;dm_footsteps_submit=output;dm_footsteps_set_active(1);
    ptr(meta+l->actor_field,info);dm_footsteps_observe(regs);dm_footsteps_render(240,48000);CHECK(!wave_starts&&peak==0,"NPC using player sound excluded");ptr(meta+l->actor_field,player);
    put32(node+l->node_phase,2);dm_footsteps_observe(regs);dm_footsteps_render(240,48000);CHECK(!wave_starts,"delayed toe waits for activation");
    put32(node+l->node_phase,l->phase_first);dm_footsteps_render(240,48000);CHECK(wave_starts==1&&peak==.25f,"selected original waveform starts");
    dm_footsteps_render(240,48000);peak=0;dm_footsteps_observe(regs);dm_footsteps_render(240,48000);CHECK(wave_starts==1&&peak==0,"same sound never replayed");
    put32(node+l->handle_gen,14);dm_footsteps_render(240,48000);CHECK(wave_starts==1,"stale sound generation ignored");put32(sound+l->sound_gen,14);
    memcpy(wave,"WAIT",4);dm_footsteps_observe(regs);dm_footsteps_render(240,48000);CHECK(wave_starts==1,"unfinished wave ignored");memcpy(wave,"FWAV",4);
    dm_footsteps_render(240,48000);CHECK(wave_starts==2,"unfinished wave can become ready");
    put32(image+l->mode_global,1);peak=0;dm_footsteps_render(240,48000);CHECK(peak==0,"menu clears ongoing wave");put32(image+l->mode_global,l->playing);dm_footsteps_render(240,48000);CHECK(peak==0,"menu exit never replays stale event");
    dm_footsteps_observe(regs);dm_footsteps_render(240,48000);CHECK(peak>0,"new event after menu works");
    dm_footsteps_set_active(0);unsigned before=calls;dm_footsteps_render(240,48000);CHECK(calls==before,"inactive has no submission");
    dm_footsteps_set_active(1);peak=0;dm_footsteps_render(240,48000);CHECK(peak==0,"resume discards old events and voices");
    gate=0;CHECK(!dm_footsteps_prepare(&m,1),"missing rewritten gate disables feature");gate=1;strcpy(m.build_id,"unknown");CHECK(!dm_footsteps_prepare(&m,1),"unknown builds rejected");
    clear_render();free(image);printf("Footsteps: %d checks, %d failures\n",checks,failed);return !!failed;
}
