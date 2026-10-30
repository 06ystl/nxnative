#include "audio_wave.h"
#include <string.h>
static uint16_t u16(const uint8_t *p){uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t u32(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return v;}
static int span(size_t offset,size_t count,size_t size){return offset<=size&&count<=size-offset;}
int dm_fwav_source(const uint8_t *b,size_t size,dm_wave_source *out){
    memset(out,0,sizeof *out);
    if(!b||size<0x2c||memcmp(b,"FWAV",4)||u16(b+4)!=0xfeff||u32(b+12)>size||u16(b+16)!=2)return 0;
    size=u32(b+12);size_t inf=u32(b+0x18),dat=u32(b+0x24);
    if(!span(inf,0x20,size)||!span(dat,8,size)||memcmp(b+inf,"INFO",4)||memcmp(b+dat,"DATA",4))return 0;
    unsigned fmt=b[inf+8];uint32_t n=u32(b+inf+0x14),hz=u32(b+inf+0xc),channels=u32(b+inf+0x1c);
    if(!n||n>480000||hz<8000||hz>96000||!channels||channels>DM_WAVE_CHANNELS||fmt>2||!span(inf+0x20,8*channels,size))return 0;
    uint32_t bytes=fmt==2?(n+13)/14*8:fmt==1?n*2:n;
    dm_wave_source result={.channels=channels,.frames=n,.rate=hz,.data_bytes=bytes};
    for(unsigned i=0;i<channels;i++){
        size_t ci=inf+0x1c+(uint64_t)u32(b+inf+0x24+8*i);
        if(!span(ci,16,size))return 0;
        size_t data=dat+8+(uint64_t)u32(b+ci+4);
        if(!span(data,bytes,size))return 0;
        result.data_offset[i]=(uint32_t)data;
    }
    *out=result;return 1;
}
