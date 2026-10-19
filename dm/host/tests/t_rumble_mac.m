// Real HID -> Mac feedback state machine, with only physical haptic endpoints
// replaced. Core Haptics still builds/validates the continuous event pattern.
#define DM_RUMBLE_TEST 1
#include "../rumble_mac.m"
#include "../hle_hid.c"

static int checks, failed, opmode = 1;
uint64_t dm_guest_frame(void) { return 0; }
int dm_opmode(void) { return opmode; }
void hle_bind_system_event(void *event, int clear) { (void)event; (void)clear; }
void hle_signal_system_event(void *event) { (void)event; }
#define CHECK(c,msg) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,msg); } } while(0)

@interface RumblePlayer : NSObject
@property int starts, stops, updates;
@property float intensity, sharpness;
@property BOOL failParams, failPlay, failStop, configuredBeforeStart;
@end
@implementation RumblePlayer
- (BOOL)sendParameters:(NSArray<CHHapticDynamicParameter *> *)params atTime:(NSTimeInterval)t error:(NSError **)error {
    (void)t; (void)error;
    if (self.failParams) return NO;
    self.updates++;
    for (CHHapticDynamicParameter *p in params) {
        if ([p.parameterID isEqual:CHHapticDynamicParameterIDHapticIntensityControl]) self.intensity = p.value;
        if ([p.parameterID isEqual:CHHapticDynamicParameterIDHapticSharpnessControl]) self.sharpness = p.value;
    }
    return YES;
}
- (BOOL)startAtTime:(NSTimeInterval)t error:(NSError **)error {
    (void)t; (void)error; self.configuredBeforeStart = self.updates > 0;
    if (self.failPlay) return NO;
    self.starts++; return YES;
}
- (BOOL)stopAtTime:(NSTimeInterval)t error:(NSError **)error { (void)t; (void)error; self.stops++; return !self.failStop; }
@end
@interface RumbleEngine : NSObject
@property (copy) void (^resetHandler)(void);
@property (copy) void (^stoppedHandler)(CHHapticEngineStoppedReason);
@property NSMutableArray<RumblePlayer *> *players;
@property BOOL failStart, failCreate, failParams, failPlay;
@property int starts, stops;
@end
@implementation RumbleEngine
- (instancetype)init { if ((self=[super init])) self.players=[NSMutableArray array]; return self; }
- (BOOL)startAndReturnError:(NSError **)error { (void)error; self.starts++; return !self.failStart; }
- (id<CHHapticPatternPlayer>)createPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)error {
    (void)error; CHECK(pattern != nil,"production creates a real Core Haptics pattern");
    if (self.failCreate) return nil;
    RumblePlayer *p=[RumblePlayer new]; p.failParams=self.failParams; p.failPlay=self.failPlay;
    [self.players addObject:p]; return (id)p;
}
- (void)stopWithCompletionHandler:(void (^)(NSError *))handler { self.stops++; if(handler)handler(nil); }
@end
@interface RumbleHaptics : NSObject
@property NSSet *supportedLocalities;
@property NSMutableArray<RumbleEngine *> *engines;
@property NSMutableArray<NSString *> *routes;
@property BOOL failStart, failCreate, failParams, failPlay;
@end
@implementation RumbleHaptics
- (instancetype)init { if((self=[super init])) {self.engines=[NSMutableArray array];self.routes=[NSMutableArray array];}return self; }
- (CHHapticEngine *)createEngineWithLocality:(NSString *)locality {
    RumbleEngine *e=[RumbleEngine new]; e.failStart=self.failStart; e.failCreate=self.failCreate; e.failParams=self.failParams; e.failPlay=self.failPlay;
    [self.engines addObject:e]; [self.routes addObject:locality]; return (id)e;
}
@end
@interface RumblePad : NSObject
@property RumbleHaptics *haptics;
@property NSString *vendorName;
@end
@implementation RumblePad
@end
static RumblePad *pad(int split) {
    RumblePad *p=[RumblePad new];p.vendorName=@"test controller";p.haptics=[RumbleHaptics new];
    p.haptics.supportedLocalities=split?[NSSet setWithObjects:GCHapticsLocalityDefault,GCHapticsLocalityLeftHandle,GCHapticsLocalityRightHandle,nil]:[NSSet setWithObject:GCHapticsLocalityDefault];
    return p;
}
static void tick(uint64_t now) { rumble_sync(^{rumble_tick(now);}); }
static void flush(void) { rumble_sync(^{}); }
static void send_value(unsigned side, float low, float high, float lf, float hf) {
    uint32_t handle=vib_handle(connected_id(),side);dm_vibration_value v={low,lf,high,hf};h_hid_SendVib(&handle,&v);
}
static void attach(RumblePad *p) { dm_rumble_mac_attach((id)p); }
static _Atomic int concurrent_inflight, concurrent_peak, concurrent_calls;
static _Atomic float concurrent_last;
static void concurrent_sink(unsigned side, const dm_vibration_value *v) {
    (void)side;
    int n=atomic_fetch_add(&concurrent_inflight,1)+1, peak=atomic_load(&concurrent_peak);
    while(n>peak&&!atomic_compare_exchange_weak(&concurrent_peak,&peak,n)) {}
    usleep(100); // force simultaneous SDK callers to overlap unless publication is serialized
    atomic_store(&concurrent_last,v->amplitude_low);atomic_fetch_add(&concurrent_calls,1);
    atomic_fetch_sub(&concurrent_inflight,1);
}
static void *concurrent_sender(void *arg) {
    unsigned index=(unsigned)(uintptr_t)arg;
    for(unsigned i=0;i<40;i++)send_value(0,(index*40+i)/200.0f,0,160,320);
    return NULL;
}
static void test_concurrent_publication(void) {
    void (*sink)(unsigned,const dm_vibration_value *)=dm_vibration_send;
    dm_vibration_send=concurrent_sink;
    pthread_t threads[4];
    for(unsigned i=0;i<4;i++) { int e=pthread_create(&threads[i],NULL,concurrent_sender,(void *)(uintptr_t)i);CHECK(!e,"create concurrent SDK sender");if(e)abort(); }
    for(unsigned i=0;i<4;i++)pthread_join(threads[i],NULL);
    uint32_t handle=3;dm_vibration_value actual;h_hid_VibActual(&actual,&handle);
    CHECK(atomic_load(&concurrent_calls)==160&&atomic_load(&concurrent_peak)==1,"concurrent SDK calls publish in one order");
    CHECK(actual.amplitude_low==atomic_load(&concurrent_last),"actual-value snapshot matches the last published output");
    dm_vibration_send=sink;
}
static void test_hid(void) {
    uint32_t id=0, handles[3]={0xdeadbeef,0xdeadbeef,0xdeadbeef};
    CHECK(!h_hid_VibPermit(),"unimplemented frontends retain no-vibration behavior");
    CHECK(!h_hid_VibHandles(handles,2,&id,STYLE_FULLKEY),"no handles without frontend");
    dm_vibration_value actual;h_hid_VibActual(&actual,handles);
    CHECK(!memcmp(&actual,(uint8_t[16]){0},16),"unsupported actual-value ABI remains zeroed");
    dm_rumble_mac_start();
    CHECK(h_hid_VibPermit(),"Mac advertises rumble before physical hotplug");
    CHECK(h_hid_VibHandles(handles,1,&id,STYLE_FULLKEY)==1&&handles[0]==3&&handles[1]==0xdeadbeef,"one-entry output capacity");
    CHECK(h_hid_VibHandles(handles,3,&id,STYLE_FULLKEY)==2&&handles[1]==0x10003&&handles[2]==0xdeadbeef,"two full-key SDK handles and no overwrite");
    CHECK(!h_hid_VibHandles(handles,0,&id,STYLE_FULLKEY),"zero capacity");
    CHECK(!h_hid_VibHandles(handles,2,&id,STYLE_HANDHELD),"wrong style rejected");
    uint32_t other=1;CHECK(!h_hid_VibHandles(handles,2,&other,STYLE_FULLKEY),"other player rejected");
    uint32_t info[2];h_hid_VibInfo(info,&handles[1]);
    CHECK(info[0]==1&&info[1]==2,"SDK info identifies right linear actuator");
    uint8_t permission[2]={0,0x7e};CHECK(!h_hid_VibPermitDetail(permission)&&permission[0]==1&&permission[1]==0x7e,"detail Result/bool ABI writes one byte");
    CHECK(!h_hid_VibMountedDetail(permission,&handles[1])&&permission[0]==1,"detail mounted proxy avoids hid service");
    uint32_t invalid=0x20003;CHECK(!h_hid_VibMounted(&invalid),"six-axis device index is not a vibration handle");
    opmode=0;id=NPAD_HANDHELD;
    CHECK(h_hid_VibHandles(handles,2,&id,STYLE_HANDHELD)==2&&handles[0]==0x804&&handles[1]==0x10804,"handheld maps to SDK player index 8");
    invalid=3;CHECK(!h_hid_VibMounted(&invalid),"inactive full-key handle rejected in handheld mode");
    opmode=1;
}
static void test_split(void) {
    uint64_t now=clock_gettime_nsec_np(CLOCK_MONOTONIC);
    RumblePad *p=pad(1);attach(p);dm_rumble_mac_set_active(1);
    uint32_t handles[]={3,0x10003};dm_vibration_value values[]={{0.3f,40,0.4f,40},{0,160,0.25f,1250}};
    CHECK(!h_hid_SendVibs(handles,values,2),"vibration graph batch returns success");tick(now);
    CHECK(p.haptics.engines.count==2,"one engine per supported handle");
    CHECK([p.haptics.routes[0] isEqual:GCHapticsLocalityLeftHandle]&&[p.haptics.routes[1] isEqual:GCHapticsLocalityRightHandle],"left/right routing");
    RumbleEngine *left=p.haptics.engines[0],*right=p.haptics.engines[1];
    RumblePlayer *a=left.players.lastObject,*b=right.players.lastObject;
    CHECK(fabsf(a.intensity-.5f)<1e-6&&fabsf(b.intensity-.25f)<1e-6,"both bands combine without mixing controller sides");
    CHECK(a.sharpness==-.5f&&b.sharpness==.5f,"40 and 1250 Hz reach sharpness endpoints");
    CHECK(a.configuredBeforeStart&&b.configuredBeforeStart,"no full-strength pulse before first dynamic value");
    tick(now+500000000ull);
    CHECK(!a.stops&&!b.stops&&a.updates==1&&b.updates==1,"held values survive 250 ms and unchanged output avoids repeated API calls");
    tick(now+26000000000ull);
    CHECK(left.players.count==2&&right.players.count==2&&a.stops==1&&b.stops==1,"continuous output renews finite players");
    a=left.players.lastObject;b=right.players.lastObject;
    send_value(0,0,0,160,320);tick(now+27000000000ull);
    CHECK(a.stops==1&&!b.stops,"explicit zero stops only its own handle");
    dm_vibration_value actual;CHECK(!h_hid_VibActualDetail(&actual,&handles[1])&&actual.amplitude_high==.25f,"detail actual-value proxy preserves last accepted game value");
    values[1]=(dm_vibration_value){2,-100,-1,9000};h_hid_VibSendDetail(&handles[1],&values[1]);h_hid_VibActual(&actual,&handles[1]);
    CHECK(actual.amplitude_low==1&&actual.amplitude_high==0&&actual.frequency_low==0&&actual.frequency_high==1250,"invalid ranges are clamped at HID boundary");
    send_value(1,NAN,1,160,320);tick(now+28000000000ull);
    CHECK(b.stops==1,"nonfinite values become silence");
    send_value(0,.001f,0,160,320);tick(now+29000000000ull);
    CHECK(left.players.lastObject.intensity>0&&left.players.lastObject.intensity<.002f,"quiet valid vibration is retained");
    a=left.players.lastObject;
    dm_rumble_mac_set_active(0);
    CHECK(a.stops==1&&left.stops>0&&right.stops>0,"focus loss stops players and engines synchronously");
    send_value(0,1,1,160,320);dm_rumble_mac_set_active(1);tick(now+30000000000ull);
    CHECK(p.haptics.engines.count==2,"focus regain does not replay stale or background requests");
    send_value(0,.3f,0,160,320);tick(now+31000000000ull);
    RumbleEngine *old=p.haptics.engines.lastObject;
    void (^late)(void)=old.resetHandler;
    RumblePad *next=pad(1);attach(next);tick(now+32000000000ull);
    CHECK(old.players.lastObject.stops==1&&!next.haptics.engines.count,"controller change stops and clears output");
    send_value(0,.4f,0,160,320);tick(now+33000000000ull);
    late();flush();
    CHECK(next.haptics.engines.count==1&&!next.haptics.engines[0].players.lastObject.stops,"late callback cannot retire a replacement controller");
    RumbleEngine *engine=next.haptics.engines[0];engine.resetHandler();flush();tick(now+34000000000ull);
    CHECK(next.haptics.engines.count==2&&engine.players.lastObject.stops==1,"engine reset rebuilds feedback for the current value");
    attach(nil);CHECK(next.haptics.engines.lastObject.players.lastObject.stops==1,"disconnect stops rumble");
}
static void test_shared_and_errors(void) {
    uint64_t now=clock_gettime_nsec_np(CLOCK_MONOTONIC);
    RumblePad *p=pad(0);attach(p);
    send_value(0,.6f,0,160,320);send_value(1,0,.2f,160,320);tick(now);
    CHECK(p.haptics.engines.count==1&&[p.haptics.routes[0] isEqual:GCHapticsLocalityDefault],"default-only device uses one shared engine");
    RumblePlayer *a=p.haptics.engines[0].players.lastObject;
    CHECK(fabsf(a.intensity-.6f)<1e-6,"shared output chooses stronger side");
    send_value(1,0,0,160,320);tick(now+10000000);
    CHECK(!a.stops&&fabsf(a.intensity-.6f)<1e-6,"silent right side cannot cancel active left on shared motors");
    send_value(0,0,0,160,320);tick(now+20000000);CHECK(a.stops==1,"both silent stop shared output");
    send_value(0,.3f,0,160,320);tick(now+30000000);
    a=p.haptics.engines[0].players.lastObject;a.failStop=YES;
    send_value(0,0,0,160,320);tick(now+40000000);
    CHECK(p.haptics.engines[0].stops>0&&!g_rumble_engines[0],"failed player stop also stops and retires its engine");
    RumblePad *none=[RumblePad new];none.vendorName=@"no haptics";attach(none);send_value(0,1,1,160,320);tick(now);
    CHECK(!g_rumble_engines[0]&&!g_rumble_engines[1],"non-haptic controller stays usable without engine attempts");
    p=pad(1);p.haptics.failStart=YES;attach(p);send_value(0,.5f,0,160,320);tick(now);
    CHECK(p.haptics.engines.count==1&&!p.haptics.engines[0].players.count,"engine start failure creates no player");
    uint64_t retry=g_rumble_retry[0];tick(retry-1);
    CHECK(p.haptics.engines.count==1,"retry deadline prevents repeated failing API calls");
    p.haptics.failStart=NO;tick(retry+1);CHECK(p.haptics.engines.count==2&&p.haptics.engines.lastObject.players.lastObject.starts==1,"engine error recovers after backoff");
    RumbleEngine *engine=p.haptics.engines.lastObject;a=engine.players.lastObject;
    a.failParams=YES;send_value(0,.7f,0,160,320);tick(retry+20000000);
    CHECK(a.stops==1&&!g_rumble_engines[0],"parameter failure retires active player and engine");
    p=pad(1);p.haptics.failParams=YES;attach(p);send_value(0,1,0,160,320);tick(now);
    CHECK(!p.haptics.engines[0].players.lastObject.starts,"failed initial parameters never start a full-strength player");
    p=pad(1);p.haptics.failCreate=YES;attach(p);send_value(0,.4f,0,160,320);tick(now);
    CHECK(!g_rumble_engines[0]&&p.haptics.engines[0].stops>0,"player creation failure retires engine");
    p=pad(1);p.haptics.failPlay=YES;attach(p);send_value(0,.4f,0,160,320);tick(now);
    CHECK(!g_rumble_engines[0]&&!p.haptics.engines[0].players.lastObject.starts,"play failure cannot leave a tracked active player");
    p=pad(1);attach(p);send_value(0,.4f,0,160,320);tick(now);
    engine=p.haptics.engines[0];engine.players.lastObject.failStop=YES;tick(now+26000000000ull);
    CHECK(engine.players.count==1&&engine.stops>0&&!g_rumble_engines[0],"renewal stop failure cannot orphan an older player");
    p=pad(1);attach(p);send_value(1,.2f,0,160,320);tick(now);
    engine=p.haptics.engines[0];dm_vibration_shutdown();
    CHECK(engine.players.lastObject.stops==1&&engine.stops>0,"graceful exit callback stops output");
    send_value(1,1,1,160,320);tick(now+10000000);
    CHECK(p.haptics.engines.count==1,"shutdown cannot restart feedback");
}
int main(void) { @autoreleasepool {
    test_hid();test_concurrent_publication();test_split();test_shared_and_errors();
    printf("RUMBLE_MAC checks=%d failed=%d\n",checks,failed);return failed!=0;
} }
