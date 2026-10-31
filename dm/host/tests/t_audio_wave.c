#include "../audio_wave.h"
#include "audio_wave_fixture.h"
#include <stdio.h>
static int checks,failed;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
int main(void){
    uint8_t b[512];dm_wave_source s;
    wave_fixture(b,sizeof b,1,3);
    CHECK(dm_fwav_source(b,sizeof b,&s)&&s.channels==1&&s.frames==3&&s.rate==48000&&s.data_offset[0]==0x100&&s.data_bytes==6&&!s.loop,"PCM16 nonlooping buffer identity");
    wave_fixture(b,sizeof b,0,2);CHECK(dm_fwav_source(b,sizeof b,&s)&&s.data_bytes==2,"PCM8 encoded span");
    wave_fixture(b,sizeof b,2,15);CHECK(dm_fwav_source(b,sizeof b,&s)&&s.data_bytes==16,"ADPCM partial final block");
    b[0x49]=1;CHECK(dm_fwav_source(b,sizeof b,&s)&&s.loop,"loop identity retained; SDK still owns playback");
    wave_fixture(b,sizeof b,1,3);
    for(size_t i=0;i<0x106;i++)CHECK(!dm_fwav_source(b,i,&s),"truncated input rejected");
    put32(b+0x5c,2);put32(b+0x6c,0x54);put32(b+0xb4,0x58);
    CHECK(dm_fwav_source(b,sizeof b,&s)&&s.channels==2&&s.data_offset[1]==0x120,"separate channel buffers retained");
    put32(b+0x64,0xffffffff);CHECK(!dm_fwav_source(b,sizeof b,&s)&&!s.channels,"overflowing channel reference rejected");
    wave_fixture(b,sizeof b,1,3);put32(b+0x5c,7);CHECK(!dm_fwav_source(b,sizeof b,&s),"unsupported channel count rejected");
    wave_fixture(b,sizeof b,3,3);CHECK(!dm_fwav_source(b,sizeof b,&s),"unknown encoding rejected");
    printf("FWAV source: %d checks, %d failures\n",checks,failed);return !!failed;
}
