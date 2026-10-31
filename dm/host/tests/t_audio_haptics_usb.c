// Exercises the PCM queue/callback only; never opens a device or sends HID reports.
#include "../audio_haptics_usb_mac.c"
#include <float.h>
static int checks,failed;
static uint8_t report_bytes[63];static unsigned report_writes;static IOReturn report_error;
static IOReturn fake_report(const uint8_t *p,size_t n){if(n==sizeof report_bytes)memcpy(report_bytes,p,n);report_writes++;return report_error;}
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
static void pull(float *out,unsigned n){
    float delay[DM_HAPTIC_LOOKAHEAD*4];AudioBufferList b={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=4,.mDataByteSize=sizeof delay,.mData=delay}}};
    render(NULL,NULL,NULL,0,DM_HAPTIC_LOOKAHEAD,&b); // Align assertions with the queued source after its 2 ms output delay.
    b.mBuffers[0].mData=out;b.mBuffers[0].mDataByteSize=n*16;render(NULL,NULL,NULL,0,n,&b);
}
static void reset(void){reset_stats();dm_haptic_dynamics_reset(&dynamics);atomic_store(&write_pos,0);atomic_store(&read_pos,0);atomic_store(&ready,1);atomic_store(&active,1);last[0]=last[1]=0;atomic_store(&flush_serial,0);atomic_store(&flush_pos,0);consumed_flush=0;dm_haptic_usb_set_gain(1);}
int main(void){
    float pcm[]={.1f,-.2f,.3f,-.3f,NAN,INFINITY},out[24];reset();
    CHECK(dm_haptic_usb_enqueue(pcm,3)==3,"stereo block accepted");pull(out,3);
    CHECK(out[0]==0&&out[1]==0&&out[4]==0&&out[5]==0,"audible channels always silent");
    CHECK(out[2]==.1f&&out[3]==-.2f,"left/right map to USB channels 3/4");
    CHECK(out[6]==.3f&&out[7]==-.3f,"in-range waveform is unchanged");CHECK(out[10]==0&&out[11]==0,"nonfinite input becomes silence");
    dm_haptic_usb_stats stats=dm_haptic_usb_get_stats();
    CHECK(stats.callbacks==2&&stats.queued_frames==3&&stats.signal_frames==2&&stats.input_peak==.3f&&stats.output_peak==.3f&&!stats.layout_errors,"diagnostics distinguish queued PCM from nonzero samples written by the callback");
    AudioBufferList wrong={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=8,.mData=out}}};
    render(NULL,NULL,NULL,0,1,&wrong);CHECK(dm_haptic_usb_get_stats().layout_errors==1,"unexpected hardware callback layout is visible instead of silently losing haptics");
    reset();dm_haptic_usb_set_gain(.5);dm_haptic_usb_enqueue(pcm,1);pull(out,1);CHECK(out[2]==.05f&&out[3]==-.1f,"gain preserves original waveform ratio");
    float soft[]={.02f,-.04f};
    reset();dm_haptic_usb_set_gain(6);dm_haptic_usb_enqueue(soft,1);pull(out,1);
    CHECK(fabsf(out[2]-.12f)<1e-6&&fabsf(out[3]+.24f)<1e-6,"sixfold gain amplifies quiet footsteps without changing stereo ratio");
    reset();dm_haptic_usb_set_gain(20);dm_haptic_usb_enqueue(soft,1);pull(out,1);
    CHECK(fabsf(out[2]-.4f)<1e-6&&fabsf(out[3]+.8f)<1e-6,"higher gain uses the full PCM range without the old half-scale clamp");
    float footsteps[]={.075f,-.09f};
    reset();dm_haptic_usb_set_gain(10);dm_haptic_usb_enqueue(footsteps,1);pull(out,1);
    CHECK(fabsf(out[2]-.75f)<1e-6&&fabsf(out[3]+.9f)<1e-6,"tenfold footsteps retain amplitude and stereo ratio above half scale");
    reset();dm_haptic_usb_set_gain(FLT_MAX);dm_haptic_usb_enqueue(pcm+2,1);pull(out,1);
    CHECK(out[2]>.99f&&out[3]<-.99f,"large finite gain cannot turn a strong effect into silence");
    reset();
    dm_haptic_usb_enqueue(pcm,1);dm_haptic_usb_set_active(0);pull(out,1);CHECK(out[2]==0&&atomic_load(&read_pos)==atomic_load(&write_pos),"pause discards queued waveform");
    dm_haptic_usb_set_active(1);pull(out,1);CHECK(out[2]==0,"resume cannot replay old sound");
    reset();dm_haptic_usb_enqueue(pcm,1);dm_haptic_usb_set_active(0);dm_haptic_usb_set_active(1);pull(out,1);CHECK(out[2]==0,"rapid pause/resume before callback discards queued sound");
    reset();dm_haptic_usb_enqueue(pcm,1);pull(out,2);CHECK(out[6]>0&&out[6]<out[2],"underrun fades to zero");
    reset();atomic_store(&write_pos,UINT_MAX-1);atomic_store(&read_pos,UINT_MAX-1);dm_haptic_usb_enqueue(pcm,3);pull(out,3);CHECK(out[2]==.1f&&out[6]==.3f&&out[10]==0,"queue indices wrap correctly");
    reset();float large[CAPACITY*2]={0};CHECK(dm_haptic_usb_enqueue(large,CAPACITY)==CAPACITY,"bounded maximum block");CHECK(!dm_haptic_usb_enqueue(pcm,1),"overflow never overwrites unread samples");
    atomic_store(&ready,0);CHECK(!dm_haptic_usb_enqueue(pcm,1),"closed stream rejects writes");
    dm_haptic_usb_set_gain(NAN);CHECK(atomic_load(&gain)==0,"invalid gain mutes");
    uint8_t full[11];dm_trigger_slope slope={1,0,1,1,1};encode_slope(full,&slope);
    const uint8_t known[11]={0x21,0xff,3,0xff,0xff,0xff,0x3f,0,0,0,0};
    CHECK(!memcmp(full,known,11),"ten-zone maximum feedback matches the documented wire vector");
    reset();hid=(IOHIDDeviceRef)(uintptr_t)1;write_report=fake_report;trigger_owned=0;
    slope=(dm_trigger_slope){1,0,1,.10f,.35f};dm_haptic_usb_set_trigger(1,&slope);
    uint8_t right[11];memcpy(right,report_bytes+11,11);
    CHECK(report_bytes[0]==2&&report_bytes[1]==0x0c&&!(report_bytes[1]&3)&&report_bytes[2]==0,"shared report updates both triggers without disabling audio or touching audio-volume flags");
    CHECK(right[0]==0x21&&right[1]==0xff&&right[2]==3&&report_bytes[22]==5,"R2 slope spans full travel while L2 is off");
    uint32_t strengths=0;memcpy(&strengths,right+3,4);int previous=-1,monotonic=1;
    for(unsigned zone=0;zone<10;zone++){int value=(strengths>>(3*zone))&7;if(value<previous)monotonic=0;previous=value;}
    CHECK(monotonic&&(strengths&7)==0&&previous==2,"normalized slope maps to increasing one-to-three strength zones");
    slope=(dm_trigger_slope){1,0,1,.10f,.28f};dm_haptic_usb_set_trigger(0,&slope);
    CHECK(!memcmp(right,report_bytes+11,11)&&report_bytes[22]==0x21,"shield update preserves the bow effect and audio mode");
    unsigned writes=report_writes;dm_haptic_usb_set_trigger(0,&slope);CHECK(report_writes==writes,"unchanged quantized zones do not resend reports");
    dm_haptic_usb_set_trigger(0,NULL);CHECK(report_bytes[22]==5&&!memcmp(right,report_bytes+11,11),"releasing L2 preserves R2 and audio haptics");
    slope=(dm_trigger_slope){1,0,1,.15f,.55f};report_error=kIOReturnError;dm_haptic_usb_set_trigger(1,&slope);
    CHECK(!dm_haptic_usb_ready()&&!atomic_load(&active),"failed shared report retires audio ownership for existing recovery");
    hid=NULL;write_report=native_report;report_error=0;
    printf("USB audio haptics: %d checks, %d failures\n",checks,failed);return !!failed;
}
