// Exercises the PCM queue/callback only; never opens a device or sends HID reports.
#include "../audio_haptics_usb_mac.c"
static int checks,failed;
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
static void pull(float *out,unsigned n){AudioBufferList b={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=4,.mDataByteSize=n*16,.mData=out}}};render(NULL,NULL,NULL,0,n,&b);}
static void reset(void){atomic_store(&write_pos,0);atomic_store(&read_pos,0);atomic_store(&ready,1);atomic_store(&active,1);last[0]=last[1]=0;atomic_store(&flush_serial,0);atomic_store(&flush_pos,0);consumed_flush=0;dm_haptic_usb_set_gain(1);}
int main(void){
    float pcm[]={.1f,-.2f,3.f,-3.f,NAN,INFINITY},out[24];reset();
    CHECK(dm_haptic_usb_enqueue(pcm,3)==3,"stereo block accepted");pull(out,3);
    CHECK(out[0]==0&&out[1]==0&&out[4]==0&&out[5]==0,"audible channels always silent");
    CHECK(out[2]==.1f&&out[3]==-.2f,"left/right map to USB channels 3/4");
    CHECK(out[6]==.5f&&out[7]==-.5f,"peak limiting");CHECK(out[10]==0&&out[11]==0,"nonfinite input becomes silence");
    reset();dm_haptic_usb_set_gain(.5);dm_haptic_usb_enqueue(pcm,1);pull(out,1);CHECK(out[2]==.05f&&out[3]==-.1f,"gain preserves original waveform ratio");
    dm_haptic_usb_enqueue(pcm,1);dm_haptic_usb_set_active(0);pull(out,1);CHECK(out[2]==0&&atomic_load(&read_pos)==atomic_load(&write_pos),"pause discards queued waveform");
    dm_haptic_usb_set_active(1);pull(out,1);CHECK(out[2]==0,"resume cannot replay old sound");
    reset();dm_haptic_usb_enqueue(pcm,1);dm_haptic_usb_set_active(0);dm_haptic_usb_set_active(1);pull(out,1);CHECK(out[2]==0,"rapid pause/resume before callback discards queued sound");
    reset();dm_haptic_usb_enqueue(pcm,1);pull(out,2);CHECK(out[6]>0&&out[6]<out[2],"underrun fades to zero");
    reset();atomic_store(&write_pos,UINT_MAX-1);atomic_store(&read_pos,UINT_MAX-1);dm_haptic_usb_enqueue(pcm,3);pull(out,3);CHECK(out[2]==.1f&&out[6]==.5f&&out[10]==0,"queue indices wrap correctly");
    reset();float large[CAPACITY*2]={0};CHECK(dm_haptic_usb_enqueue(large,CAPACITY)==CAPACITY,"bounded maximum block");CHECK(!dm_haptic_usb_enqueue(pcm,1),"overflow never overwrites unread samples");
    atomic_store(&ready,0);CHECK(!dm_haptic_usb_enqueue(pcm,1),"closed stream rejects writes");
    dm_haptic_usb_set_gain(NAN);CHECK(atomic_load(&gain)==0,"invalid gain mutes");
    printf("USB audio haptics: %d checks, %d failures\n",checks,failed);return !!failed;
}
