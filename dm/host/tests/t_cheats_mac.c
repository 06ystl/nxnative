// Production profile and loader patch contract, including atomic rejection.
#include "../cheats_mac.c"

static unsigned checks, failed;
#define CHECK(test) do { checks++; if (!(test)) { failed++; fprintf(stderr,"FAIL %d: %s\n",__LINE__,#test); } } while (0)

static int apply(int argc, char **argv) {
    if (argc != 8) return 2;
    FILE *f = fopen(argv[2],"rb"); if (!f) return 2;
    fseek(f,0,SEEK_END); size_t size = ftell(f); rewind(f);
    uint8_t *image = malloc(size); if (!image) return 2;
    if (fread(image,1,size,f) != size) return 2; fclose(f);
    module_t m = {.text_end=strtoull(argv[5],0,0), .ro_off=strtoull(argv[6],0,0)};
    strcpy(m.name,"main"); strlcpy(m.build_id,argv[4],sizeof m.build_id);
    setenv("DM_CHEATS",argv[7],1);
    if (dm_cheats_mac_patch(&m,image,size) < 0) return 1;
    f = fopen(argv[3],"wb"); if (!f) return 2;
    int ok = fwrite(image,1,size,f) == size && !ferror(f);
    fclose(f); free(image); return !ok;
}
int main(int argc, char **argv) {
    if (argc > 1) return apply(argc,argv);
    if (!patches[0].build) { puts("MAC_CHEATS: profile has no cheats"); return 0; }
    module_t m = {0}; strcpy(m.name,"main"); strlcpy(m.build_id,patches[0].build,sizeof m.build_id);
    size_t size = 0;
    for (size_t i=0;i<sizeof patches/sizeof *patches;i++) if(patches[i].offset+4>size) size=patches[i].offset+4;
    m.text_end=size; m.ro_off=size+0x4000;
    uint8_t *original=calloc(1,size), *image=calloc(1,size); CHECK(original&&image);
    for (size_t i=0;i<sizeof patches/sizeof *patches;i++) memcpy(original+patches[i].offset,&patches[i].original,4);
    const char *off[] = {NULL,"","none"};
    for (size_t k=0;k<3;k++) {
        memcpy(image,original,size); if(off[k])setenv("DM_CHEATS",off[k],1);else unsetenv("DM_CHEATS");
        CHECK(dm_cheats_mac_patch(&m,image,size)==0); CHECK(!memcmp(image,original,size));
    }
    const char *valid[]={"health","stamina","durability","arrows","health, stamina,arrows,durability","health,health"};
    for(size_t k=0;k<sizeof valid/sizeof *valid;k++) {
        memcpy(image,original,size);setenv("DM_CHEATS",valid[k],1);
        CHECK(dm_cheats_mac_patch(&m,image,size)==1);
        for(size_t i=0;i<sizeof patches/sizeof *patches;i++) {
            uint32_t word;memcpy(&word,image+patches[i].offset,4);
            CHECK(word==(strstr(valid[k],patches[i].name)?patches[i].replacement:patches[i].original));
        }
    }
    const char *bad[]={"Health","all","health,unknown","health,","health,,arrows",",health","none,health","   "};
    for(size_t k=0;k<sizeof bad/sizeof *bad;k++) {
        memcpy(image,original,size);setenv("DM_CHEATS",bad[k],1);
        CHECK(dm_cheats_mac_patch(&m,image,size)==-1);CHECK(!memcmp(image,original,size));
    }
    setenv("DM_CHEATS","health,stamina,durability,arrows",1);
    memcpy(image,original,size);m.build_id[0]='0';
    CHECK(dm_cheats_mac_patch(&m,image,size)==-1);CHECK(!memcmp(image,original,size));
    strlcpy(m.build_id,patches[0].build,sizeof m.build_id);
    // A late bad veneer word must not leave earlier health/stamina sites changed.
    image[patches[sizeof patches/sizeof *patches-1].offset]^=1;
    uint8_t *before=malloc(size);memcpy(before,image,size);
    CHECK(dm_cheats_mac_patch(&m,image,size)==-1);CHECK(!memcmp(image,before,size));
    memcpy(image,original,size);
    CHECK(dm_cheats_mac_patch(&m,image,size-1)==-1);CHECK(!memcmp(image,original,size));
    uint64_t ro=m.ro_off;m.ro_off=4;
    CHECK(dm_cheats_mac_patch(&m,image,size)==-1);CHECK(!memcmp(image,original,size));m.ro_off=ro;
    strcpy(m.name,"sdk");
    CHECK(dm_cheats_mac_patch(&m,image,size)==0);CHECK(!memcmp(image,original,size));
    free(before);free(image);free(original);
    printf("MAC_CHEATS checks=%u failed=%u\n",checks,failed);return failed!=0;
}
