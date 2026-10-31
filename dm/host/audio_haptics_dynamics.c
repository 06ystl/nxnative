#include "audio_haptics_dynamics.h"
#include <math.h>
#include <string.h>

void dm_haptic_dynamics_reset(dm_haptic_dynamics *s){
    memset(s,0,sizeof *s);s->gain=1;s->release=exp(-1.0/(48000*.050));
    for(unsigned i=0;i<DM_HAPTIC_DELAY_SIZE;i++)s->bound[i]=1;
}
void dm_haptic_dynamics_process(dm_haptic_dynamics *s,double left,double right,float out[2]){
    unsigned current=s->position,oldest=(current+1)%DM_HAPTIC_DELAY_SIZE;
    s->samples[current][0]=isfinite(left)?left:0;s->samples[current][1]=isfinite(right)?right:0;s->bound[current]=1;
    double peak=fmax(fabs(s->samples[current][0]),fabs(s->samples[current][1]));
    if(peak>1){
        double required=1/peak;
        // Anticipate this peak with a linear gain ramp across the pending audio.
        // Scale both channels together, retaining direction and the waveform.
        for(unsigned i=0;i<DM_HAPTIC_DELAY_SIZE;i++){
            unsigned at=(oldest+i)%DM_HAPTIC_DELAY_SIZE;
            double bound=((DM_HAPTIC_LOOKAHEAD-i)+required*i)/DM_HAPTIC_LOOKAHEAD;
            s->bound[at]=fmin(s->bound[at],bound);
        }
    }
    double released=1-(1-s->gain)*s->release;
    s->gain=fmin(s->bound[oldest],released);
    for(unsigned c=0;c<2;c++)out[c]=(float)fmax(-1,fmin(1,s->samples[oldest][c]*s->gain));
    s->position=oldest;
}
