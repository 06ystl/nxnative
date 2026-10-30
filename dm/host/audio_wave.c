#include "audio_wave.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static uint16_t u16(const uint8_t *p){uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t u32(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return v;}
static int span(size_t offset,size_t count,size_t size){return offset<=size&&count<=size-offset;}
int dm_fwav_decode(const uint8_t *b,size_t size,float **pcm,uint32_t *frames,uint32_t *rate){
    *pcm=NULL;*frames=*rate=0;
    if(!b||size<0x2c||memcmp(b,"FWAV",4)||u16(b+4)!=0xfeff||u32(b+12)>size||u16(b+16)!=2)return 0;
    size=u32(b+12);size_t inf=u32(b+0x18),dat=u32(b+0x24);
    if(!span(inf,0x28,size)||!span(dat,8,size)||memcmp(b+inf,"INFO",4)||memcmp(b+dat,"DATA",4))return 0;
    if(b[inf+9]||u32(b+inf+0x1c)!=1)return 0; // Footstep one-shots are mono; never replay a loop.
    uint32_t n=u32(b+inf+0x14),hz=u32(b+inf+0xc);
    if(!n||n>480000||hz<8000||hz>96000)return 0;
    size_t ci=inf+0x1c+(uint64_t)u32(b+inf+0x24);
    if(!span(ci,16,size))return 0;
    size_t ptr=dat+8+(uint64_t)u32(b+ci+4);unsigned fmt=b[inf+8];
    uint64_t bytes=fmt==2?((uint64_t)n+13)/14*8:fmt==1?(uint64_t)n*2:fmt==0?n:UINT64_MAX;
    if(!span(ptr,bytes,size))return 0;
    int16_t coef[16]={0};int y1=0,y2=0;
    if(fmt==2){size_t co=ci+(uint64_t)u32(b+ci+12);if(!span(co,38,size))return 0;memcpy(coef,b+co,32);y1=(int16_t)u16(b+co+34);y2=(int16_t)u16(b+co+36);}
    float *out=malloc((size_t)n*sizeof(float));if(!out)return 0;
    if(fmt==0)for(uint32_t i=0;i<n;i++)out[i]=(int8_t)b[ptr+i]/128.f;
    else if(fmt==1)for(uint32_t i=0;i<n;i++)out[i]=(int16_t)u16(b+ptr+2*i)/32768.f;
    else {
        uint32_t i=0;
        while(i<n){unsigned header=b[ptr++],pred=header>>4,scale=1u<<(header&15);
            if(pred>=8){free(out);return 0;}
            for(unsigned j=0;j<14&&i<n;j++,i++){
                int nibble=(b[ptr+j/2]>>(j%2?0:4))&15;if(nibble>=8)nibble-=16;
                int64_t value=((int64_t)nibble*scale*2048+1024+(int64_t)coef[2*pred]*y1+(int64_t)coef[2*pred+1]*y2)>>11;
                int sample=value>32767?32767:value< -32768?-32768:(int)value;y2=y1;y1=sample;out[i]=sample/32768.f;
            }
            ptr+=7;
        }
    }
    *pcm=out;*frames=n;*rate=hz;return 1;
}
