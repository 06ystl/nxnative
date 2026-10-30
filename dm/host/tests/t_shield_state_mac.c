#include "../shield_state_mac.h"
static int checks, failed, calls, fail_at, interrupt;
#define CHECK(c,msg) do {checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
static const dm_shield_layout layouts[]={DM_GAME_MAC_SHIELD_STATE};
static const dm_shield_layout fallback={"fixture",0x100,0x108,0x60,0x64,1,0,0xbb0,8,0x40,0x48,0xc40,0x10,0xd4c};
static const dm_shield_layout *l;
static uint8_t *image,info[256],player[0x3000],owner[256],shield[0x2000];
static void put32(void *p,uint32_t v){memcpy(p,&v,4);}
static void pointer(void *p,void *v){uint64_t n=(uintptr_t)v;memcpy(p,&n,8);}
static int read_copy(void *ctx,uint64_t a,void *out,size_t n){
    (void)ctx;if(++calls==fail_at)return 0;
    struct {void *p;size_t n;} regions[]={{image,0x2000000},{info,sizeof info},{player,sizeof player},{owner,sizeof owner},{shield,sizeof shield}};
    for(size_t i=0;i<sizeof regions/sizeof *regions;i++){
        uint64_t start=(uintptr_t)regions[i].p;
        if(a>=start&&a-start<=regions[i].n&&n<=regions[i].n-(a-start)){
            memcpy(out,(void *)(uintptr_t)a,n);
            if(a==(uintptr_t)(shield+l->durability_field))switch(interrupt){
                case 1:put32(image+l->mode_global,1);break;
                case 2:pointer(info+l->player_field,NULL);break;
                case 3:player[l->life_field]=2;break;
                case 4:put32(player+l->flags_field,0);break;
                case 5:put32(player+l->shield_link_field+l->link_generation_field,UINT32_MAX);break;
                case 6:put32(owner+l->owner_generation_field,10);break;
                case 7:pointer(owner+l->owner_actor_field,NULL);break;
                case 8:shield[l->life_field]=2;break;
            }
            return 1;
        }
    }
    return 0;
}
static void reset(void){
    calls=fail_at=interrupt=0;
    memset(info,0,sizeof info);memset(player,0,sizeof player);memset(owner,0,sizeof owner);memset(shield,0,sizeof shield);
    put32(image+l->mode_global,l->playing_mode);pointer(image+l->player_info_global,info);pointer(info+l->player_field,player);
    player[l->life_field]=shield[l->life_field]=l->active_life;
    put32(player+l->flags_field,l->guard_mask);pointer(player+l->shield_link_field,owner);
    put32(player+l->shield_link_field+l->link_generation_field,9);put32(owner+l->owner_generation_field,9);
    pointer(owner+l->owner_actor_field,shield);put32(shield+l->durability_field,10000);
}
static dm_shield_snapshot sample(void){return dm_shield_sample(l,(uintptr_t)image,read_copy,NULL);}
int main(void){
    l=layouts[0].build?&layouts[0]:&fallback;image=calloc(1,0x2000000);if(!image)return 2;
    reset();dm_shield_snapshot s=sample();int count=calls;
    CHECK(s.valid&&s.guarding&&s.durability==10000,"actual shield guard and durability");
    CHECK(s.player==(uintptr_t)player&&s.shield==(uintptr_t)shield&&s.generation==9,"equipment identity accompanies damage sample");
    put32(player+l->flags_field,0);s=sample();CHECK(s.valid&&!s.guarding,"equipped shield alone is not guarding");
    reset();put32(image+l->mode_global,1);CHECK(!sample().valid,"pause rejects frozen guard flag");
    reset();put32(player+l->shield_link_field+l->link_generation_field,UINT32_MAX);CHECK(!sample().valid,"lock-on with unequipped shield has no resistance");
    reset();shield[l->life_field]=2;CHECK(!sample().valid,"broken inactive actor rejected");
    reset();player[l->life_field]=2;CHECK(!sample().valid,"scene exit rejects old player");
    reset();put32(shield+l->durability_field,0);CHECK(!sample().valid,"zero durability clears before actor teardown");
    reset();put32(shield+l->durability_field,UINT32_MAX);CHECK(!sample().valid,"negative durability rejected");
    for(int i=1;i<=count;i++){reset();fail_at=i;CHECK(!sample().valid,"every failed copy disables shield feedback");}
    for(int i=1;i<=8;i++){reset();interrupt=i;CHECK(!sample().valid,"state changes during read reject sample");}
    reset();module_t m={0};strcpy(m.name,"main");strcpy(m.build_id,l->build);m.base=image;m.size=0x2000000;m.data_off=0x1b7a000;
    if(layouts[0].build)CHECK(dm_shield_mac_bind(&m,1)&&dm_shield_mac_sample().guarding,"verified build binds Mach reader");
    else CHECK(!dm_shield_mac_bind(&m,1),"other profile has no fixed address reader");
    strcpy(m.build_id,"unknown");CHECK(!dm_shield_mac_bind(&m,1)&&!dm_shield_mac_sample().valid,"unknown build rejected");
    strcpy(m.build_id,l->build);m.size=1024;CHECK(!dm_shield_mac_bind(&m,1),"layout outside image rejected");
    CHECK(!dm_shield_mac_bind(NULL,0),"no modules supported");
    free(image);printf("Shield state: %d checks, %d failures\n",checks,failed);return !!failed;
}
