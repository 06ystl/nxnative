#include "audio_haptics_usb_mac.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

enum { CAPACITY=4096, QUEUE_LIMIT=1440 };
static float samples[CAPACITY][2];
static _Atomic unsigned write_pos,read_pos;
static _Atomic int active,ready;
static _Atomic float gain=.3f;
static AudioUnit unit;
static AudioDeviceID audio_device;
static _Atomic unsigned flush_serial,flush_pos;
static unsigned consumed_flush;
static const AudioObjectPropertyAddress alive_property={kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
static OSStatus device_changed(AudioObjectID object,UInt32 count,const AudioObjectPropertyAddress *addresses,void *context) {
    (void)count;(void)addresses;(void)context;UInt32 alive=0,n=sizeof alive;
    if(AudioObjectGetPropertyData(object,&alive_property,0,NULL,&n,&alive)||!alive){atomic_store(&active,0);atomic_store(&ready,0);}
    return noErr;
}
static IOHIDDeviceRef hid;
static char status[256]="USB audio haptics closed";
static float last[2];
static pthread_mutex_t producer_lock=PTHREAD_MUTEX_INITIALIZER;

static OSStatus render(void *ctx,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 count,AudioBufferList *out) {
    (void)ctx;(void)flags;(void)time;(void)bus;
    for(UInt32 i=0;i<out->mNumberBuffers;i++)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
    unsigned serial=atomic_load_explicit(&flush_serial,memory_order_acquire);
    unsigned r=atomic_load_explicit(&read_pos,memory_order_relaxed);
    if(serial!=consumed_flush){r=atomic_load(&flush_pos);last[0]=last[1]=0;consumed_flush=serial;}
    unsigned w=atomic_load_explicit(&write_pos,memory_order_acquire);
    if(!atomic_load(&active)){atomic_store_explicit(&read_pos,w,memory_order_release);last[0]=last[1]=0;return noErr;}
    if(out->mNumberBuffers!=1||out->mBuffers[0].mNumberChannels!=4||!out->mBuffers[0].mData||out->mBuffers[0].mDataByteSize<count*16)return noErr;
    float *dst=out->mBuffers[0].mData,g=atomic_load(&gain);
    for(UInt32 i=0;i<count;i++){
        if(r!=w){for(int c=0;c<2;c++){float v=samples[r%CAPACITY][c]*g;last[c]=isfinite(v)?fmaxf(-.5f,fminf(.5f,v)):0;}r++;}
        else {last[0]*=.85f;last[1]*=.85f;}
        // USB channels 1/2 are audible output; 3/4 drive the left/right actuators.
        dst[4*i+2]=last[0];dst[4*i+3]=last[1];
    }
    atomic_store_explicit(&read_pos,r,memory_order_release);return noErr;
}
static int number(IOHIDDeviceRef dev,CFStringRef key){CFTypeRef v=IOHIDDeviceGetProperty(dev,key);int n=0;if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&n);return n;}
static int sony_usb(IOHIDDeviceRef dev){
    int p=number(dev,CFSTR(kIOHIDProductIDKey));CFTypeRef t=IOHIDDeviceGetProperty(dev,CFSTR(kIOHIDTransportKey));
    return number(dev,CFSTR(kIOHIDVendorIDKey))==0x054c&&(p==0x0ce6||p==0x0df2)&&t&&CFEqual(t,CFSTR("USB"));
}
static AudioDeviceID find_audio(void){
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size)||!size)return kAudioObjectUnknown;
    AudioDeviceID *ids=malloc(size),found=kAudioObjectUnknown;unsigned matches=0;
    if(!ids)return kAudioObjectUnknown;
    if(!AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,ids))for(unsigned i=0;i<size/sizeof(*ids);i++){
        CFStringRef name=NULL;UInt32 n=sizeof name;
        AudioObjectPropertyAddress p={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(AudioObjectGetPropertyData(ids[i],&p,0,NULL,&n,&name)||!name)continue;
        int match=CFStringFind(name,CFSTR("DualSense"),0).location!=kCFNotFound;CFRelease(name);if(!match)continue;
        p.mSelector=kAudioDevicePropertyTransportType;UInt32 transport=0;n=sizeof transport;
        if(AudioObjectGetPropertyData(ids[i],&p,0,NULL,&n,&transport)||transport!=kAudioDeviceTransportTypeUSB)continue;
        p.mSelector=kAudioDevicePropertyStreamConfiguration;p.mScope=kAudioDevicePropertyScopeOutput;n=0;
        if(AudioObjectGetPropertyDataSize(ids[i],&p,0,NULL,&n)||!n)continue;
        AudioBufferList *list=malloc(n);if(!list)continue;unsigned ch=0;
        if(!AudioObjectGetPropertyData(ids[i],&p,0,NULL,&n,list))for(UInt32 j=0;j<list->mNumberBuffers;j++)ch+=list->mBuffers[j].mNumberChannels;
        free(list);if(ch==4){found=ids[i];matches++;}
    }
    free(ids);return matches==1?found:kAudioObjectUnknown;
}
void dm_haptic_usb_close(void){
    atomic_store(&active,0);atomic_store(&ready,0);
    if(audio_device){AudioObjectRemovePropertyListener(audio_device,&alive_property,device_changed,NULL);audio_device=0;}
    if(unit){AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);unit=NULL;}
    if(hid){IOHIDDeviceClose(hid,kIOHIDOptionsTypeNone);CFRelease(hid);hid=NULL;}
    pthread_mutex_lock(&producer_lock);
    atomic_store(&write_pos,0);atomic_store(&read_pos,0);last[0]=last[1]=0;
    atomic_store(&flush_serial,0);atomic_store(&flush_pos,0);consumed_flush=0;
    pthread_mutex_unlock(&producer_lock);
}
int dm_haptic_usb_open(void){
    if(atomic_load(&ready))return 1;
    AudioDeviceID device=find_audio();if(device==kAudioObjectUnknown){snprintf(status,sizeof status,"Exactly one four-channel DualSense USB audio device is required");return 0;}
    IOHIDManagerRef manager=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    if(!manager){snprintf(status,sizeof status,"Cannot enumerate USB controller");return 0;}
    CFMutableDictionaryRef match=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int page=1,usage=5;CFNumberRef pn=CFNumberCreate(NULL,kCFNumberIntType,&page),un=CFNumberCreate(NULL,kCFNumberIntType,&usage);
    CFDictionarySetValue(match,CFSTR(kIOHIDPrimaryUsagePageKey),pn);CFDictionarySetValue(match,CFSTR(kIOHIDPrimaryUsageKey),un);CFRelease(pn);CFRelease(un);
    IOHIDManagerSetDeviceMatching(manager,match);CFRelease(match);CFSetRef set=IOHIDManagerCopyDevices(manager);unsigned matches=0;
    if(set){CFIndex count=CFSetGetCount(set);const void **devices=calloc(count?count:1,sizeof(void*));if(devices){CFSetGetValues(set,devices);for(CFIndex i=0;i<count;i++)if(sony_usb((IOHIDDeviceRef)devices[i])){if(hid)CFRelease(hid);hid=(IOHIDDeviceRef)CFRetain(devices[i]);matches++;}free(devices);}CFRelease(set);}
    CFRelease(manager);
    if(matches!=1){snprintf(status,sizeof status,"Exactly one DualSense USB gamepad is required");dm_haptic_usb_close();return 0;}
    IOReturn io=IOHIDDeviceOpen(hid,kIOHIDOptionsTypeNone);
    if(io){snprintf(status,sizeof status,"USB controller open failed: %#x",io);dm_haptic_usb_close();return 0;}
    // No trigger/LED/audio-volume validity bits: preserve those states. Clearing
    // emulated-rumble flags restores audio haptics (SDL's PS5 output semantics).
    uint8_t report[63]={2};io=IOHIDDeviceSetReport(hid,kIOHIDReportTypeOutput,2,report,sizeof report);
    if(io){snprintf(status,sizeof status,"USB audio-haptics mode failed: %#x",io);dm_haptic_usb_close();return 0;}
    AudioComponentDescription desc={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent comp=AudioComponentFindNext(NULL,&desc);OSStatus err=comp?AudioComponentInstanceNew(comp,&unit):-1;
    if(!err)err=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof device);
    AudioStreamBasicDescription fmt={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=16,.mFramesPerPacket=1,.mBytesPerFrame=16,.mChannelsPerFrame=4,.mBitsPerChannel=32};
    if(!err)err=AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&fmt,sizeof fmt);
    AURenderCallbackStruct cb={render,NULL};
    if(!err)err=AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof cb);
    if(!err)err=AudioUnitInitialize(unit);
    if(!err)err=AudioOutputUnitStart(unit);
    if(err){snprintf(status,sizeof status,"DualSense audio stream failed: %d",(int)err);dm_haptic_usb_close();return 0;}
    audio_device=device;
    err=AudioObjectAddPropertyListener(device,&alive_property,device_changed,NULL);
    if(err){snprintf(status,sizeof status,"Cannot monitor USB audio device: %d",(int)err);dm_haptic_usb_close();return 0;}
    atomic_store(&ready,1);snprintf(status,sizeof status,"DualSense USB: 48 kHz, actuator channels 3/4");return 1;
}
void dm_haptic_usb_set_active(int on){
    pthread_mutex_lock(&producer_lock);
    int value=!!on&&atomic_load(&ready);
    if(atomic_exchange(&active,value)&&!value){
        atomic_store(&flush_pos,atomic_load(&write_pos));
        atomic_fetch_add_explicit(&flush_serial,1,memory_order_release);
    }
    pthread_mutex_unlock(&producer_lock);
}
int dm_haptic_usb_ready(void){return atomic_load(&ready);}
void dm_haptic_usb_set_gain(float g){atomic_store(&gain,isfinite(g)?fmaxf(0,fminf(2,g)):0);}
size_t dm_haptic_usb_enqueue(const float *stereo,size_t frames){
    if(!stereo||!atomic_load(&ready)||!atomic_load(&active)||frames>CAPACITY)return 0;
    pthread_mutex_lock(&producer_lock);
    if(!atomic_load(&ready)||!atomic_load(&active)){pthread_mutex_unlock(&producer_lock);return 0;}
    unsigned w=atomic_load_explicit(&write_pos,memory_order_relaxed),r=atomic_load_explicit(&read_pos,memory_order_acquire);
    if(w-r>QUEUE_LIMIT||frames>CAPACITY-(w-r)){pthread_mutex_unlock(&producer_lock);return 0;}
    for(size_t i=0;i<frames;i++){samples[(w+i)%CAPACITY][0]=stereo[2*i];samples[(w+i)%CAPACITY][1]=stereo[2*i+1];}
    atomic_store_explicit(&write_pos,w+(unsigned)frames,memory_order_release);pthread_mutex_unlock(&producer_lock);return frames;
}
const char *dm_haptic_usb_status(void){return status;}
