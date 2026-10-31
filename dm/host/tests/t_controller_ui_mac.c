// Synthetic files exercise actual startup selection and RomFS reads, without UI,
// a game process, controller discovery or feedback engines.
#include "../hle_fs.c"
#include "../controller_ui_mac.c"
struct dm_flags g_flag;
uint64_t g_t0_ns;
uint64_t now_ns(void) { return 0; }
void dm_guest_write_prepare(void *p, size_t n) { (void)p; (void)n; }
static int checks, failed;
#define CHECK(c,msg) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",msg); } } while (0)
static void put(const char *p, const char *s) { FILE *f=fopen(p,"w"); if(!f)abort(); fputs(s,f); fclose(f); }
static int reads(const char *p, const char *want) {
    uint64_t fd; char b[64]={0}; size_t got=0;
    if(h_fs_OpenFile(&fd,p,MODE_READ))return 0;
    int ok=!h_fs_ReadFile(&got,fd,0,b,sizeof b-1);h_fs_CloseFile(fd);
    return ok&&!strcmp(b,want);
}
int main(void) {
    char root[]="/private/tmp/t_controller_ui.XXXXXX";CHECK(mkdtemp(root)!=NULL,"temporary resource root");
    char rom[1024],folder[1024],pack[1024],marker[1024],file[1024],user[1024],app[1024];
    snprintf(app,sizeof app,"%s/Game.app",root);mkdir(app,0755);
    dm_controller_ui_mac_set_app_bundle(app);
    snprintf(rom,sizeof rom,"%s/romfs",root);mkdir(rom,0755);
    snprintf(folder,sizeof folder,"%s/patches",root);mkdir(folder,0755);
    snprintf(pack,sizeof pack,"%s/patches/dualsense-ui",root);mkdir(pack,0755);
    snprintf(folder,sizeof folder,"%s/romfs",pack);mkdir(folder,0755);
    snprintf(marker,sizeof marker,"%s/manifest.tsv",pack);
    snprintf(file,sizeof file,"%s/button",rom);put(file,"original");
    snprintf(file,sizeof file,"%s/button",folder);put(file,"PS5");
    snprintf(file,sizeof file,"%s/untouched",rom);put(file,"base-only");
    setenv("DM_ROMFS",rom,1);unsetenv("DM_ROMFS_OVERLAY");
    CHECK(!dm_controller_ui_mac_available(),"missing optional pack does not delay discovery");
    CHECK(!dm_controller_ui_mac_select(0)&&!getenv("DM_ROMFS_OVERLAY"),"non-DualSense retains original resources");
    CHECK(!dm_controller_ui_mac_select(1)&&!getenv("DM_ROMFS_OVERLAY"),"missing pack keeps original resources");
    put(marker,"game\t0000000000000000\n");
    CHECK(!dm_controller_ui_mac_select(1),"another game's pack is rejected");
    put(marker,"game\t" DM_GAME_ID "\n");
    CHECK(dm_controller_ui_mac_available(),"matching optional pack enables startup discovery");
    CHECK(!dm_controller_ui_mac_select(0)&&!getenv("DM_ROMFS_OVERLAY"),"an installed patch stays inactive for other controllers");
    CHECK(dm_controller_ui_mac_select(1),"matching pack activates before RomFS mounts");
    CHECK(!h_fs_MountRom("rom",NULL,0)&&reads("rom:/button","PS5"),"game reads PS5 overlay through existing read-only FS");
    uint64_t fd;CHECK(h_fs_OpenFile(&fd,"rom:/button",MODE_WRITE)==RES_FAIL,"UI overlay remains read-only");
    // Use a fresh mount: read-only directory indices are immutable after loading.
    g_nmnt=0;CHECK(!h_fs_MountRom("other",NULL,0)&&reads("other:/untouched","base-only"),"unmodified game assets fall through to original RomFS");
    snprintf(user,sizeof user,"%s/user",root);mkdir(user,0755);snprintf(file,sizeof file,"%s/button",user);put(file,"user-mod");
    setenv("DM_ROMFS_OVERLAY",user,1);CHECK(dm_controller_ui_mac_select(1),"explicit user overlay coexists with automatic UI");
    CHECK(!strncmp(getenv("DM_ROMFS_OVERLAY"),user,strlen(user)),"explicit overlay keeps first priority");
    g_nmnt=0;CHECK(!h_fs_MountRom("user",NULL,0)&&reads("user:/button","user-mod"),"explicit override wins for the same resource");
    unsetenv("DM_ROMFS_OVERLAY");char trailing[1030];snprintf(trailing,sizeof trailing,"%s/",rom);setenv("DM_ROMFS",trailing,1);
    CHECK(dm_controller_ui_mac_select(1),"external patch lookup is independent of the RomFS path");
    unsetenv("DM_ROMFS_OVERLAY");unlink(marker);
    CHECK(!dm_controller_ui_mac_select(1)&&!getenv("DM_ROMFS_OVERLAY"),"removing the patch marker restores original UI even for DualSense");
    dm_controller_ui_mac_set_app_bundle(NULL);
    CHECK(!dm_controller_ui_mac_available(),"command-line tools do not discover unrelated neighbouring patches");
    CHECK(!rm_tree(root),"remove synthetic fixture");
    printf("Controller UI: %d checks, %d failures\n",checks,failed);return !!failed;
}
