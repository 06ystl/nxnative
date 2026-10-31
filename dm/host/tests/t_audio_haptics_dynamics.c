#include "../audio_haptics_dynamics.h"
#include <math.h>
#include <stdio.h>
static int checks,failed;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
int main(void){
    dm_haptic_dynamics state;float out[2];dm_haptic_dynamics_reset(&state);int exact=1;
    for(unsigned i=0;i<2400;i++){
        double x=.4*sin(2*3.141592653589793*120*i/48000.);
        dm_haptic_dynamics_process(&state,x,-x*.25,out);
        double wanted=i<DM_HAPTIC_LOOKAHEAD?0:.4*sin(2*3.141592653589793*120*(i-DM_HAPTIC_LOOKAHEAD)/48000.);
        if(fabs(out[0]-wanted)>1e-7||fabs(out[1]+wanted*.25)>1e-7)exact=0;
    }
    CHECK(exact,"signals below full scale keep their waveform, gain and stereo ratio after the documented 2 ms delay");
    dm_haptic_dynamics_reset(&state);double limited_error=0,clipped_error=0,peak=0;int bounded=1,linked=1;
    for(unsigned i=0;i<24000;i++){
        double x=4*sin(2*3.141592653589793*160*i/48000.);dm_haptic_dynamics_process(&state,x,x*.25,out);
        if(fabs(out[0])>1||fabs(out[1])>1)bounded=0;
        if(fabs(out[1]-out[0]*.25)>1e-7)linked=0;
        peak=fmax(peak,fabs(out[0]));
        if(i>4800){double original=sin(2*3.141592653589793*160*(i-DM_HAPTIC_LOOKAHEAD)/48000.);
            limited_error+=fabs(out[0]-original);clipped_error+=fabs(fmax(-1,fmin(1,4*original))-original);}
    }
    CHECK(bounded&&peak>.99,"overdriven waveforms use full scale without overshoot or an extra half-scale cap");
    CHECK(linked,"peak control applies one gain to both actuator channels");
    CHECK(limited_error<clipped_error*.2,"strong periodic textures retain their shape more closely than hard clipping");
    dm_haptic_dynamics_reset(&state);double extreme_peak=0;
    for(unsigned i=0;i<DM_HAPTIC_DELAY_SIZE*2;i++){
        dm_haptic_dynamics_process(&state,i==0?1e70:0,i==0?-1e70:0,out);
        extreme_peak=fmax(extreme_peak,fabs(out[0]));if(!isfinite(out[0])||fabs(out[0])>1)bounded=0;
    }
    CHECK(bounded&&extreme_peak>.99,"large finite gain remains finite and reaches full scale");
    dm_haptic_dynamics_process(&state,NAN,INFINITY,out);dm_haptic_dynamics_reset(&state);int silent=1;
    for(unsigned i=0;i<240;i++){dm_haptic_dynamics_process(&state,0,0,out);if(out[0]!=0||out[1]!=0)silent=0;}
    CHECK(silent,"pause/reset discards every delayed sample and invalid input cannot revive an effect");
    printf("Audio haptics dynamics: %d checks, %d failures\n",checks,failed);return !!failed;
}
