#pragma once
#include <stdint.h>
#include <string.h>
static void put16(void *p,uint16_t v){memcpy(p,&v,2);}
static void put32(void *p,uint32_t v){memcpy(p,&v,4);}
// One mono, nonlooping FWAV, with a channel reference and DSP context.
static inline void wave_fixture(uint8_t *b,size_t size,unsigned fmt,unsigned n){
    memset(b,0,size);memcpy(b,"FWAV",4);put16(b+4,0xfeff);put32(b+12,(uint32_t)size);put16(b+16,2);
    put32(b+0x18,0x40);put32(b+0x24,0xc0);memcpy(b+0x40,"INFO",4);b[0x48]=fmt;
    put32(b+0x4c,48000);put32(b+0x54,n);put32(b+0x5c,1);put32(b+0x64,0x14);
    put32(b+0x74,0x38);put32(b+0x7c,0x10);memcpy(b+0xc0,"DATA",4);
}
