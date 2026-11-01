#include "../bow_state_mac.h"
#include <math.h>

static int checks, failed, calls, fail_at, interrupt;
#define CHECK(c, msg) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",msg); } } while (0)
static const dm_bow_layout layouts[] = {DM_GAME_MAC_BOW_STATE};
static const dm_bow_layout fallback = {"fixture",0x100,0x108,0x60,0x110,0xa0,0x1f8c,0x64,1,2,0,0xbc8,8,0x40,0x48,0,1,31,0,0,0,0,0,0,0,0};
static int shot_gate=1; static void (*shot_observer)(uint64_t*,int);
int gate_obs_present(int id) { return shot_gate && id==OBS_BOW_SHOT; }
void gate_obs_set(int id,void(*fn)(uint64_t*,int)) { if(id==OBS_BOW_SHOT)shot_observer=fn; }
static const dm_bow_layout *l;
static uint8_t *image, info[256], player[0x3000], owner[256], bow[256], charge_owner[256];
static uint8_t inventory[0x45000], bow_item[128], ammo[128], other_ammo[128];
static uint64_t category_head;
static void put32(void *p, uint32_t n) { memcpy(p,&n,4); }
static void pointer(void *p, void *value) { uint64_t n=(uintptr_t)value;memcpy(p,&n,8); }
static void progress(float q) { memcpy(charge_owner+l->charge_field,&q,4); }
static int read_copy(void *ctx, uint64_t a, void *out, size_t n) {
    (void)ctx; calls++;
    if (calls==fail_at) return 0;
    struct {void *p;size_t n;} regions[]={{image,0x2000000},{info,sizeof info},{player,sizeof player},{owner,sizeof owner},{bow,sizeof bow},{charge_owner,sizeof charge_owner},{inventory,sizeof inventory},{bow_item,sizeof bow_item},{ammo,sizeof ammo},{other_ammo,sizeof other_ammo},{&category_head,sizeof category_head}};
    for (size_t i=0;i<sizeof regions/sizeof *regions;i++) {
        uint64_t start=(uintptr_t)regions[i].p;
        if (a>=start && a-start<=regions[i].n && n<=regions[i].n-(a-start)) {
            memcpy(out,(void *)(uintptr_t)a,n);
            if (interrupt==9 && l->ammo_global && a==(uintptr_t)(ammo+l->ammo_count_field))
                put32(ammo+l->ammo_count_field,0);
            if (a==(uintptr_t)(charge_owner+l->charge_field) && interrupt) {
                switch(interrupt) {
                case 1: put32(image+l->mode_global,1);break;
                case 2: player[l->life_field]=2;break;
                case 3: put32(player+l->bow_link_field+l->link_generation_field,UINT32_MAX);break;
                case 4: pointer(info+l->player_field,NULL);break;
                case 5: put32(owner+l->owner_generation_field,10);break;
                case 6: bow[l->life_field]=2;break;
                case 7: put32(player+l->state_field,0);break;
                case 8: pointer(image+l->charge_global,NULL);break;
                }
            }
            return 1;
        }
    }
    return 0;
}
static void reset(void) {
    calls=0;fail_at=0;interrupt=0;
    memset(info,0,sizeof info);memset(player,0,sizeof player);memset(owner,0,sizeof owner);memset(bow,0,sizeof bow);
    pointer(image+l->player_info_global,info);pointer(info+l->player_field,player);
    pointer(image+l->charge_global,charge_owner);progress(1);
    put32(image+l->mode_global,l->playing_mode);player[l->life_field]=bow[l->life_field]=l->active_life;
    put32(player+l->state_field,l->drawing_state);pointer(player+l->bow_link_field,owner);
    put32(player+l->bow_link_field+l->link_generation_field,9);put32(owner+l->owner_generation_field,9);
    pointer(owner+l->owner_actor_field,bow);
    if (l->ammo_global) {
        memset(inventory,0,sizeof inventory);memset(bow_item,0,sizeof bow_item);memset(ammo,0,sizeof ammo);memset(other_ammo,0,sizeof other_ammo);
        pointer(image+l->ammo_global,inventory);pointer(inventory+l->ammo_head_field,&category_head);
        category_head=(uintptr_t)bow_item;
        pointer(inventory+l->ammo_list_field,ammo+8);pointer(inventory+l->ammo_list_field+8,bow_item+8);
        put32(inventory+l->ammo_list_field+16,2);put32(inventory+l->ammo_list_field+20,8);
        put32(bow_item+l->ammo_type_field,l->ammo_type-1);pointer(bow_item+16,ammo+8);
        put32(ammo+l->ammo_type_field,l->ammo_type);put32(ammo+l->ammo_count_field,10);
        ammo[l->ammo_flags_field]=ammo[l->ammo_flags_field+1]=1;
        pointer(ammo+16,inventory+l->ammo_list_field);
    }
}
static dm_bow_snapshot snapshot(void) { return dm_bow_sample(l,(uintptr_t)image,read_copy,NULL); }
static float sample(void) { dm_bow_snapshot s=snapshot(); return s.phase == DM_BOW_DRAW ? s.charge : -1; }
int main(void) {
    l=layouts[0].build?&layouts[0]:&fallback;
    image=calloc(1,0x2000000);if(!image)return 2;
    reset();CHECK(sample()==1,"full draw");int count=calls;
    progress(.25f);CHECK(sample()==.25f,"fractional charge");progress(0);CHECK(sample()==0,"start of draw remains valid");
    float invalid[]={NAN,INFINITY,-.1f,1.1f};
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++){reset();progress(invalid[i]);CHECK(sample()<0,"invalid charge disables feedback");}
    reset();put32(image+l->mode_global,1);CHECK(sample()<0,"inventory/map freezes full charge but disables resistance");
    reset();put32(player+l->state_field,0);CHECK(sample()<0,"damage leaves charge at one, but no draw");
    reset();put32(player+l->bow_link_field+l->link_generation_field,UINT32_MAX);CHECK(sample()<0,"unequip leaves stale state and charge");
    reset();bow[l->life_field]=2;CHECK(sample()<0,"broken bow actor still has a pointer");
    reset();player[l->life_field]=2;CHECK(sample()<0,"title retains old player pointer and state");
    reset();put32(owner+l->owner_generation_field,10);CHECK(sample()<0,"reused equipment owner rejected");
    for(int i=1;i<=count;i++){reset();fail_at=i;CHECK(sample()<0,"every failed memory copy disables output");}
    for(int i=1;i<=8;i++){reset();interrupt=i;CHECK(sample()<0,"mid-sample lifecycle changes reject snapshot");}
    reset();put32(player+l->state_field,l->ready_state);progress(NAN);
    dm_bow_snapshot ready=snapshot();
    CHECK(ready.phase==DM_BOW_READY&&ready.charge==0,"ready preloads without stale charge");
    CHECK(ready.player==(uintptr_t)player&&ready.bow==(uintptr_t)bow&&ready.generation==9,"equipment identity reaches pull lifecycle");
    put32(player+l->state_field,l->reload_state);CHECK(snapshot().phase==DM_BOW_RELOAD,"reload supplies early baseline");
    put32(player+l->state_field,UINT32_MAX);CHECK(snapshot().phase==DM_BOW_UNAVAILABLE,"unclassified state never preloads");
    reset();put32(player+l->state_field,l->ready_state);bow[l->life_field]=2;CHECK(!snapshot().phase,"ready still validates bow lifecycle");
    if (l->ammo_global) {
        reset();put32(player+l->state_field,l->ready_state);CHECK(snapshot().phase==DM_BOW_READY,"selected ammunition arms slope before any draw");
        put32(ammo+l->ammo_count_field,0);CHECK(!snapshot().phase,"zero selected arrows disables idle preload");
        put32(player+l->state_field,l->drawing_state);CHECK(!snapshot().phase,"empty-bow charge animation never arms resistance");
        put32(inventory+l->ammo_list_field+16,3);pointer(ammo+16,other_ammo+8);
        put32(other_ammo+l->ammo_type_field,l->ammo_type);put32(other_ammo+l->ammo_count_field,100);
        other_ammo[l->ammo_flags_field+1]=1;pointer(other_ammo+16,inventory+l->ammo_list_field);
        CHECK(!snapshot().phase,"arrows of an unselected type do not load an empty selected type");
        ammo[l->ammo_flags_field]=0;other_ammo[l->ammo_flags_field]=1;
        CHECK(snapshot().phase==DM_BOW_DRAW,"switching to a stocked arrow type enables resistance");
        ammo[l->ammo_flags_field]=1;other_ammo[l->ammo_flags_field]=0;
        put32(ammo+l->ammo_count_field,1);CHECK(snapshot().phase==DM_BOW_DRAW,"last arrow still allows full resistance");
        put32(ammo+l->ammo_count_field,-1);CHECK(!snapshot().phase,"invalid negative arrow count is unavailable");
        reset();ammo[l->ammo_flags_field]=0;CHECK(!snapshot().phase,"other arrow stacks do not count as the selected ammunition");
        ammo[l->ammo_flags_field]=1;ammo[l->ammo_flags_field+1]=0;CHECK(!snapshot().phase,"quest/removed inventory entries cannot arm bow");
        reset();pointer(image+l->ammo_global,NULL);CHECK(!snapshot().phase,"missing inventory disables resistance");
        reset();pointer(inventory+l->ammo_head_field,NULL);CHECK(!snapshot().phase,"missing category disables resistance");
        reset();pointer(bow_item+16,bow_item+8);CHECK(!snapshot().phase,"cycle in inventory remains bounded by category capacity");
        reset();interrupt=9;CHECK(!snapshot().phase,"arrow consumed during sample cannot leave resistance armed");
        reset();dm_bow_layout legacy=*l;legacy.ammo_global=0;put32(ammo+l->ammo_count_field,0);
        CHECK(dm_bow_sample(&legacy,(uintptr_t)image,read_copy,NULL).phase==DM_BOW_DRAW,"older layouts keep their original input contract");
    }
    reset();module_t m={0};strcpy(m.name,"main");strcpy(m.build_id,l->build);m.base=image;m.size=0x2000000;m.data_off=0x1b7a000;
    if(layouts[0].build) CHECK(dm_bow_mac_bind(&m,1)&&dm_bow_mac_sample().charge==1,"verified image binds actual Mach reader");
    else CHECK(!dm_bow_mac_bind(&m,1),"profile without a bow layout has no reader");
    if(layouts[0].build && l->shot_bow_reg<=30) {
        uint64_t regs[31]={0};regs[l->shot_bow_reg]=(uintptr_t)bow;
        CHECK(shot_observer!=NULL,"verified successful-shot gate registered");
        shot_observer(regs,0);dm_bow_shot shot=dm_bow_mac_shot_sample();
        CHECK(shot.sequence==1&&shot.player==(uintptr_t)player&&shot.time_ns&&shot.live,"successful shot publishes live player and timestamp");
        regs[l->shot_bow_reg]++;shot_observer(regs,0);CHECK(dm_bow_mac_shot_sample().sequence==1,"other actors cannot trigger player bow recoil");
        regs[l->shot_bow_reg]=(uintptr_t)bow;put32(image+l->mode_global,1);shot_observer(regs,0);
        CHECK(!dm_bow_mac_shot_sample().live&&dm_bow_mac_shot_sample().sequence==1,"menu invalidates a shot and rejects new notifications");
        put32(image+l->mode_global,0);bow[l->life_field]=2;shot_observer(regs,0);
        CHECK(dm_bow_mac_shot_sample().sequence==2,"arrow fired on the bow-breaking shot is still a real shot");
        player[l->life_field]=2;CHECK(!dm_bow_mac_shot_sample().live,"scene teardown invalidates recoil independently of retained pointer");
        reset();shot_gate=0;shot_observer=NULL;dm_bow_mac_bind(&m,1);
        CHECK(!shot_observer&&!dm_bow_mac_shot_sample().sequence,"old rewritten modules retain progressive resistance without shot notifications");shot_gate=1;
    }
    strcpy(m.build_id,"unverified");CHECK(!dm_bow_mac_bind(&m,1)&&dm_bow_mac_sample().phase==DM_BOW_UNAVAILABLE,"unknown build has no fixed-address reads");
    strcpy(m.build_id,l->build);m.size=1024;CHECK(!dm_bow_mac_bind(&m,1),"layout outside image rejected");
    CHECK(!dm_bow_mac_bind(NULL,0),"no modules supported");
    free(image);printf("Bow state: %d checks, %d failures\n",checks,failed);return !!failed;
}
