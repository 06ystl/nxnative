#include "../dm.h"
#undef DM_GAME_MAC_RESOLUTION_PATCHES
#define DM_GAME_MAC_RESOLUTION_PATCHES \
    {"11111111111111111111111111111111", 8, 0xd2a89408, 0xd2a89408, 0xd2a89e08}, \
    {"11111111111111111111111111111111", 20, 0x52805a04, 0x52805a04, 0x52808704}, \
    {"22222222222222222222222222222222", 12, 0x52808704, 0x52805a04, 0x52808704}
#include "../resolution_mac.c"
static unsigned checks, failed;
#define CHECK(condition) do { checks++; if (!(condition)) { failed++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#condition); } } while (0)
static uint8_t image[32], original[32];
static module_t module;
static void reset(const char *request) {
    memset(image,0xa5,sizeof image);uint32_t a=0xd2a89408,b=0x52805a04,c=0x52808704;
    memcpy(image+8,&a,4);memcpy(image+20,&b,4);memcpy(image+12,&c,4);memcpy(original,image,sizeof image);
    memset(&module,0,sizeof module);strcpy(module.name,"main");strcpy(module.build_id,"11111111111111111111111111111111");
    if(request)setenv("DM_GAME_RES",request,1);else unsetenv("DM_GAME_RES");
}
static uint32_t word(size_t offset) { uint32_t w;memcpy(&w,image+offset,4);return w; }
int main(void) {
    reset(NULL);CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==0);CHECK(!memcmp(image,original,sizeof image));
    reset("");CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==0);CHECK(!memcmp(image,original,sizeof image));
    reset("1280x720");CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==1);CHECK(!memcmp(image,original,sizeof image));
    reset("1920x1080");CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==1);
    CHECK(word(8)==0xd2a89e08);CHECK(word(20)==0x52808704);CHECK(word(12)==0x52808704);
    for(size_t i=0;i<sizeof image;i++)if(!(i>=8&&i<12)&&!(i>=20&&i<24))CHECK(image[i]==original[i]);
    reset("1280x720");strcpy(module.build_id,"22222222222222222222222222222222");
    CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==1);CHECK(word(12)==0x52805a04);CHECK(word(8)==0xd2a89408);
    reset("1920x1080");strcpy(module.name,"sdk");CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==0);CHECK(!memcmp(image,original,sizeof image));
    reset("1920x1080");strcpy(module.build_id,"33333333333333333333333333333333");CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==-1);CHECK(!memcmp(image,original,sizeof image));
    reset("1920x1080");image[20]^=1;memcpy(original,image,sizeof image);
    CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==-1);CHECK(!memcmp(image,original,sizeof image));
    reset("1920x1080");CHECK(dm_resolution_mac_patch(&module,image,22)==-1);CHECK(!memcmp(image,original,sizeof image));
    reset("1920x1080");CHECK(dm_resolution_mac_patch(&module,image,4)==-1);CHECK(!memcmp(image,original,sizeof image));
    const char *invalid[]={"1920x1080junk","1920X1080","1200x675","0x0","3840x2160"};
    for(size_t i=0;i<sizeof invalid/sizeof invalid[0];i++){
        reset(invalid[i]);CHECK(dm_resolution_mac_patch(&module,image,sizeof image)==-1);CHECK(!memcmp(image,original,sizeof image));
    }
    printf("MAC_RESOLUTION checks=%u failed=%u\n",checks,failed);return failed!=0;
}
