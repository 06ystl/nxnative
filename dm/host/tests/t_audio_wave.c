#include "../audio_wave.h"
#include "audio_wave_fixture.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static int checks,failed;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
int main(void){
    uint8_t b[512];float *p;uint32_t n,hz;
    wave_fixture(b,sizeof b,1,3);put16(b+0x100,32767);put16(b+0x102,0x8000);put16(b+0x104,8192);
    CHECK(dm_fwav_decode(b,sizeof b,&p,&n,&hz)&&n==3&&hz==48000,"PCM16 metadata");
    CHECK(p&&p[0]==32767/32768.f&&p[1]==-1&&p[2]==.25f,"PCM16 signed scale");free(p);
    wave_fixture(b,sizeof b,0,2);b[0x100]=128;b[0x101]=64;
    CHECK(dm_fwav_decode(b,sizeof b,&p,&n,&hz)&&p[0]==-1&&p[1]==.5f,"PCM8 signed scale");free(p);
    wave_fixture(b,sizeof b,2,15);b[0x100]=0x01;b[0x101]=0x7f;b[0x108]=0x02;b[0x109]=0x80;
    CHECK(dm_fwav_decode(b,sizeof b,&p,&n,&hz)&&p[0]==14/32768.f&&p[1]==-2/32768.f&&p[14]==-32/32768.f,"ADPCM signed nibbles and partial final block");free(p);
    wave_fixture(b,sizeof b,2,1);put16(b+0x80,2048);put16(b+0xa2,1234);
    CHECK(dm_fwav_decode(b,sizeof b,&p,&n,&hz)&&p[0]==1234/32768.f,"ADPCM initial history");free(p);
    b[0x100]=0x80;CHECK(!dm_fwav_decode(b,sizeof b,&p,&n,&hz)&&!p,"invalid predictor rejected");
    wave_fixture(b,sizeof b,1,3);
    for(size_t i=0;i<0x106;i++)CHECK(!dm_fwav_decode(b,i,&p,&n,&hz),"truncated wave rejected");
    b[0x49]=1;CHECK(!dm_fwav_decode(b,sizeof b,&p,&n,&hz),"loops rejected");b[0x49]=0;
    put32(b+0x5c,2);CHECK(!dm_fwav_decode(b,sizeof b,&p,&n,&hz),"multichannel rejected");put32(b+0x5c,1);
    put32(b+0x64,0xffffffff);CHECK(!dm_fwav_decode(b,sizeof b,&p,&n,&hz),"overflowing channel reference rejected");
    printf("FWAV: %d checks, %d failures\n",checks,failed);return !!failed;
}
