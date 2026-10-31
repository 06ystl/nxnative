// Real source selection, 1P adapter and HID path; only sensor endpoints and time
// are replaced so known physical rotations can run without a gyro controller.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
static uint64_t test_now = 1000000000ull;
static uint64_t sensor_clock(clockid_t clock) { (void)clock; return test_now; }
#define clock_gettime_nsec_np sensor_clock
#include "../motion_controller_mac.m"
#undef clock_gettime_nsec_np
#include "../motion_dsu_mac.c"
#include "../motion_mac.m"
#include "../gamepad_mac.m"
#include "../hle_hid.c"

static int checks, failures;
#define CHECK(c,msg) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL %d: %s\n",__LINE__,msg); } } while(0)
#define NEAR(a,b) (fabs((double)(a)-(double)(b)) < .00001)
uint64_t dm_guest_frame(void) { return 0; }
int dm_opmode(void) { return 1; }
void hle_bind_system_event(void *event, int clear) { (void)event; (void)clear; }
void hle_signal_system_event(void *event) { (void)event; }

@interface Sensor : NSObject
@property (copy) GCMotionValueChangedHandler valueChangedHandler;
@property BOOL hasRotationRate, hasGravityAndUserAcceleration, sensorsRequireManualActivation, sensorsActive;
@property GCAcceleration acceleration, gravity, userAcceleration;
@property GCRotationRate rotationRate;
@end
@implementation Sensor
@end
@interface MotionPad : NSObject
@property Sensor *motion;
@property GCExtendedGamepad *extendedGamepad;
@property NSString *vendorName, *productCategory;
@property dispatch_queue_t handlerQueue;
@property GCDeviceHaptics *haptics;
@end
@implementation MotionPad
@end
static NSArray *devices;
static NSArray *registry(id cls, SEL sel) { (void)cls; (void)sel; return devices; }
static MotionPad *make_pad(void) {
    MotionPad *p=[MotionPad new];p.vendorName=@"sensor fixture";p.productCategory=@"test";
    p.extendedGamepad=[GCController controllerWithExtendedGamepad].extendedGamepad;
    p.motion=[Sensor new];p.motion.hasRotationRate=YES;p.motion.sensorsRequireManualActivation=YES;
    return p;
}
static void emit(Sensor *s) {
    test_now+=10000000ull;
    if(s.valueChangedHandler)s.valueChangedHandler((id)s);
}
static void rest(Sensor *s) {
    s.rotationRate=(GCRotationRate){0,0,0};s.acceleration=s.gravity=(GCAcceleration){0,0,-1};
    s.userAcceleration=(GCAcceleration){0,0,0};
    for(int i=0;i<110;i++)emit(s);
}
static int read_state(dm_sixaxis_state *state) { uint32_t h=six_handle(0);return h_hid_SixStates(state,1,&h); }

int main(void) { @autoreleasepool {
    unsetenv("DM_KEYS");unsetenv("DM_MOTION_SOURCE");unsetenv("DM_RUMBLE_GAIN");
    CHECK(!motion_uses_phone(),"omitted source selects controller");
    setenv("DM_MOTION_SOURCE","",1);CHECK(!motion_uses_phone(),"empty source selects controller");
    setenv("DM_MOTION_SOURCE","controller",1);CHECK(!motion_uses_phone(),"explicit controller accepted");
    setenv("DM_MOTION_SOURCE","invalid",1);CHECK(!motion_uses_phone(),"invalid source selects the documented controller default");
    unsetenv("DM_MOTION_SOURCE");motion_source_start();
    CHECK(dm_motion_read==dm_controller_motion_read&&!g_phone_client,"default installs controller reads without creating a phone worker");
    DmMotionMenu *menu=[DmMotionMenu new];
    menu.statusItem=[NSMenuItem new];menu.connectItem=[NSMenuItem new];
    menu.calibrateItem=[NSMenuItem new];menu.disconnectItem=[NSMenuItem new];[menu refresh];
    CHECK(!menu.connectItem.enabled&&!menu.disconnectItem.enabled&&!menu.calibrateItem.enabled,"controller mode disables phone controls and unavailable calibration");
    Method method=class_getClassMethod(GCController.class,@selector(controllers));
    IMP original=method_setImplementation(method,(IMP)registry);
    MotionPad *pad=make_pad();devices=@[pad];
    dm_gamepad_mac_set_active(1);dm_motion_mac_set_active(1);
    CHECK((id)g_motion_controller==pad&&pad.motion.sensorsActive&&pad.motion.valueChangedHandler,"selected 1P controller activates its sensors and handler");
    uint32_t h=six_handle(0);h_hid_SixStart(&h);
    dm_sixaxis_state state;
    CHECK(!read_state(&state),"uncalibrated controller is not advertised as usable motion");
    for(int axis=0;axis<3;axis++) {
        dm_controller_motion_calibrate();pad.motion.hasGravityAndUserAcceleration=axis==0;rest(pad.motion);
        CHECK(read_state(&state)&&state.attributes==1,"one second at rest calibrates native controller data");
        for(int i=1;i<=100;i++) {
            double angle=i*M_PI/200;
            GCAcceleration a={0,0,-1};GCRotationRate rate={0,0,0};
            if(axis==0){a.y=-sin(angle);a.z=-cos(angle);rate.x=M_PI/2;}
            if(axis==1){a.x=sin(angle);a.z=-cos(angle);rate.y=M_PI/2;}
            if(axis==2)rate.z=M_PI/2;
            pad.motion.acceleration=pad.motion.gravity=a;pad.motion.rotationRate=rate;emit(pad.motion);
        }
        CHECK(read_state(&state)&&NEAR(state.angular_velocity[axis],.25)&&NEAR(state.angle[axis],.25),"native rad/s becomes signed Switch revolutions/s and angle on each axis");
        CHECK(state.delta_time==10000000,"native timestamps report nanosecond sample intervals");
        int row=(axis+1)%3,col=(axis+2)%3;
        CHECK(fabs(state.direction[row][col]-1)<.02&&fabs(state.direction[col][row]+1)<.02,"native positive quarter-turn has the expected Switch basis");
        h_hid_SixFusionOn(&h,0);dm_sixaxis_state raw;read_state(&raw);h_hid_SixFusionOn(&h,1);
        CHECK(fabs(raw.direction[row][col]-1)<.02&&NEAR(raw.angle[axis],.25),"fusion-off reads the native gyro-only orientation through HID");
        dm_sixaxis_state again;read_state(&again);
        CHECK(again.sampling==state.sampling&&again.angle[axis]==state.angle[axis],"game reads do not integrate native samples twice");
    }
    dm_controller_motion_calibrate();pad.motion.hasGravityAndUserAcceleration=NO;
    pad.motion.rotationRate=(GCRotationRate){0,0,0};
    for(int i=0;i<110;i++){pad.motion.acceleration=(GCAcceleration){0,0,-.492691};emit(pad.motion);}
    CHECK(!read_state(&state)&&!strcmp(dm_controller_motion_get_status().message,"Waiting for usable controller motion data"),"Nova Lite compatibility values are not normalized into a connected physical sensor");
    dm_controller_motion_calibrate();rest(pad.motion);
    pad.motion.rotationRate=(GCRotationRate){0,0,0};
    pad.motion.userAcceleration=(GCAcceleration){.2,0,0};pad.motion.hasGravityAndUserAcceleration=YES;
    emit(pad.motion);read_state(&state);
    CHECK(NEAR(state.acceleration[0],.2),"split gravity and user acceleration are recombined in g");
    uint64_t sample=state.sampling;pad.motion.rotationRate=(GCRotationRate){NAN,0,0};emit(pad.motion);read_state(&state);
    CHECK(state.sampling==sample,"nonfinite native values cannot poison the shared filter");
    test_now+=600000000ull;CHECK(!read_state(&state)&&!state.angular_velocity[2],"stale native data returns no sensor or stale velocity");
    rest(pad.motion);CHECK(read_state(&state),"returning native samples recalibrate after a gap");
    GCMotionValueChangedHandler stale=pad.motion.valueChangedHandler;
    dm_motion_mac_set_active(0);
    CHECK(!pad.motion.sensorsActive&&!pad.motion.valueChangedHandler&&!read_state(&state),"ineligible window disables sensors and clears output");
    stale((id)pad.motion);CHECK(!read_state(&state),"late callback while suspended cannot restore motion");
    dm_motion_mac_set_active(1);CHECK(pad.motion.sensorsActive&&!read_state(&state),"resume requests fresh calibration instead of stale motion");
    rest(pad.motion);CHECK(read_state(&state),"motion resumes from fresh data");
    pad.motion.valueChangedHandler=nil;dm_gamepad_mac_set_active(1);
    CHECK(pad.motion.valueChangedHandler!=nil,"eligible same-controller refresh repairs lost motion callbacks");
    [pad.extendedGamepad.buttonA setValue:1];pad_read(pad.extendedGamepad);
    NpadState buttons;uint32_t npad_id=0;h_hid_StateFullKey(&buttons,&npad_id);
    CHECK(buttons.buttons&DM_BTN_A,"native motion preserves the button channel");
    MotionPad *other=make_pad();devices=@[pad,other];pad_select(devices);
    CHECK((id)g_motion_controller==pad,"a second controller does not take over 1P motion");
    stale=pad.motion.valueChangedHandler;devices=@[other];pad_select(devices);
    CHECK(!pad.motion.sensorsActive&&!pad.motion.valueChangedHandler&&other.motion.sensorsActive&&!read_state(&state),"replacement stops the old sensor and starts fresh on the new 1P pad");
    stale((id)pad.motion);CHECK(!read_state(&state),"late callback from a replaced pad is ignored");
    other.motion.hasRotationRate=NO;pad_select(devices);
    CHECK(!other.motion.sensorsActive&&!read_state(&state)&&!g_phone_client,"a gyro-less pad does not fall back to a phone");
    other.motion.hasRotationRate=YES;pad_select(devices);rest(other.motion);CHECK(read_state(&state),"capable controller can recover after refresh");
    [menu refresh];CHECK(menu.calibrateItem.enabled&&[menu.statusItem.title isEqualToString:@"Controller motion connected"],"menu reports native readiness and enables native calibration");
    setenv("DM_MOTION_SOURCE","phone",1);motion_source_start();
    CHECK(dm_motion_read==read_phone&&g_phone_client&&!other.motion.sensorsActive&&!other.motion.valueChangedHandler,"explicit phone mode exclusively selects the DSU worker and stops native sensors");
    [menu refresh];CHECK(menu.connectItem.enabled&&!menu.calibrateItem.enabled&&[menu.statusItem.title isEqualToString:@"Phone motion off"],"phone mode enables its connection control with the correct status");
    CHECK(!read_state(&state),"an unconnected phone does not fall back to a native controller");
    dm_dsu_destroy(g_phone_client);g_phone_client=NULL;unsetenv("DM_MOTION_SOURCE");motion_source_start();
    CHECK(dm_motion_read==dm_controller_motion_read&&!g_phone_client&&other.motion.sensorsActive,"removing the setting restores native controller mode");
    devices=@[];pad_select(devices);
    CHECK(!other.motion.sensorsActive&&!read_state(&state),"disconnect clears native motion immediately");
    dm_controller_motion_enable(0);dm_rumble_mac_shutdown();
    method_setImplementation(method,original);
    printf("MOTION_MAC checks=%d failed=%d\n",checks,failures);return failures!=0;
} }
