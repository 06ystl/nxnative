// Only simulated endpoints: this test never enumerates physical controllers.
#include "../adaptive_trigger_mac.m"
static int checks,failed,reads;
static dm_trigger_slope usb_effect[2];static unsigned usb_writes[2];
static void usb_output(unsigned side,const dm_trigger_slope *effect){usb_effect[side]=*effect;usb_writes[side]++;}
static dm_bow_snapshot sample;
static dm_bow_shot shot;
static dm_bow_shot read_shot(void) { return shot; }
static dm_shield_snapshot shield;
static dm_shield_snapshot read_shield(void) { return shield; }
static uint64_t now=100000000;
#define CHECK(c,msg) do {checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",msg);}}while(0)
static dm_bow_snapshot read_bow(void) {reads++;return sample;}
static void tick(void) {now+=20000000;dm_adaptive_trigger_tick(now);}
@interface Trigger : NSObject
@property int writes,stops;
@property float start,end,low,high,value;
@end
@implementation Trigger
- (void)setModeOff {self.stops++;}
- (void)setModeSlopeFeedbackWithStartPosition:(float)s endPosition:(float)e startStrength:(float)l endStrength:(float)h {self.writes++;self.start=s;self.end=e;self.low=l;self.high=h;}
@end
@interface Profile : NSObject
@property Trigger *rightTrigger, *leftTrigger;
@end
@implementation Profile
- (BOOL)isKindOfClass:(Class)c {return c==GCDualSenseGamepad.class||[super isKindOfClass:c];}
@end
@interface Controller : NSObject
@property id extendedGamepad;
@end
@implementation Controller
@end
int main(void) {@autoreleasepool {
    Controller *c=[Controller new];Profile *p=[Profile new];Trigger *t=[Trigger new];p.rightTrigger=t;c.extendedGamepad=p;
    dm_adaptive_trigger_attach((id)c);dm_adaptive_trigger_set_active(1);tick();
    CHECK(!dm_adaptive_trigger_available()&&!t.writes,"unsupported game never drives triggers");
    dm_adaptive_trigger_sample=read_bow;sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};
    dm_adaptive_trigger_set_active(0);tick();CHECK(!reads&&!t.writes,"ineligible game does no work");
    dm_adaptive_trigger_set_active(1);tick();
    CHECK(t.writes==1&&t.low==.10f&&t.high==.35f,"baseline preloaded BEFORE R2 moves or game charge starts");
    CHECK(t.start==0&&t.end==1,"slope covers full physical travel");
    dm_adaptive_trigger_tick(now+1000000);CHECK(reads==1,"state reads limited to 50 Hz");
    t.value=.1;tick();t.value=.3;tick();t.value=.9;tick();
    CHECK(t.writes==1,"depth response stays on hardware with no per-position writes");
    sample.phase=DM_BOW_RELOAD;tick();CHECK(t.writes==1&&!t.stops,"reload keeps uninterrupted baseline");
    sample.phase=DM_BOW_DRAW;sample.charge=1;tick();
    CHECK(t.high>.35f&&t.high<.37f,"sudden full charge ramps from baseline");
    float last=t.high;
    for(int i=0;i<25;i++){tick();CHECK(t.high>=last&&t.high-last<=.013f,"bounded monotonic charge ramp");last=t.high;}
    CHECK(fabsf(t.high-.55f)<1e-6&&fabsf(t.low-.15f)<1e-6,"full draw holds plateau");
    int writes=t.writes;tick();tick();CHECK(t.writes==writes&&!t.stops,"steady charge sends no writes or stop/restart");
    t.value=0;tick();CHECK(t.high==.35f,"release immediately resets to light preload despite stale draw state");
    sample.phase=DM_BOW_READY;tick();t.value=1;sample.phase=DM_BOW_DRAW;tick();
    CHECK(t.high<.37f,"next pull starts light");
    now+=2000000000;tick();CHECK(t.high<.39f,"scheduler gap cannot jump to full force");
    int stops=t.stops;sample.phase=DM_BOW_READY;tick();CHECK(t.stops==stops+1,"damage/cancel removes load even with stale full charge");
    writes=t.writes;tick();sample.phase=DM_BOW_DRAW;tick();CHECK(t.writes==writes,"cancelled held pull cannot revive");
    t.value=0;tick();t.value=1;tick();CHECK(t.writes>writes,"release rearms pull");
    sample.phase=DM_BOW_UNAVAILABLE;tick();writes=t.writes;sample.phase=DM_BOW_DRAW;tick();
    CHECK(t.writes==writes,"pause-resume while held waits for release");
    t.value=0;tick();t.value=1;tick();sample.bow=4;tick();writes=t.writes;tick();CHECK(t.writes==writes,"new equipped bow cannot inherit held pull");
    t.value=0;sample.phase=DM_BOW_READY;tick();t.value=1;sample.phase=DM_BOW_RELOAD;tick();sample.phase=DM_BOW_READY;tick();
    writes=t.writes;tick();CHECK(t.writes==writes,"cancel during reload also waits for release");
    t.value=0;tick();sample.charge=NAN;tick();CHECK(g_sent==-1,"invalid sample clears output");
    sample.charge=0;tick();t.value=1;dm_adaptive_trigger_set_active(0);CHECK(g_sent==-1,"ineligibility clears synchronously");
    dm_adaptive_trigger_set_active(1);writes=t.writes;tick();CHECK(t.writes==writes,"focus resume cannot restore heavy held effect");
    t.value=0;tick();
    Controller *c2=[Controller new];Profile *p2=[Profile new];p2.rightTrigger=[Trigger new];c2.extendedGamepad=p2;
    stops=t.stops;dm_adaptive_trigger_attach((id)c2);CHECK(t.stops==stops+1,"switch clears old trigger");
    tick();CHECK(p2.rightTrigger.writes==1,"released replacement gets baseline");
    dm_adaptive_trigger_attach(nil);CHECK(p2.rightTrigger.stops==1&&!dm_adaptive_trigger_available(),"disconnect clears effect");
    Controller *generic=[Controller new];generic.extendedGamepad=[NSObject new];dm_adaptive_trigger_attach((id)generic);int before=reads;tick();CHECK(reads==before,"other controllers untouched");
    Trigger *left=[Trigger new];p.leftTrigger=left;dm_adaptive_shield_sample=read_shield;
    shield=(dm_shield_snapshot){1,0,10000,1,20,4};dm_adaptive_trigger_attach((id)c);left.value=1;tick();
    CHECK(!left.writes,"holding L2 while only locked on does not load trigger");
    shield.guarding=1;tick();CHECK(left.writes==1&&left.high==.28f,"actual shield guard enables moderate full-travel slope");
    CHECK(left.start==0&&left.end==1,"left slope covers full travel");
    writes=left.writes;tick();CHECK(left.writes==writes,"held shield sends no repeated report");
    int right_writes=t.writes;shield.durability=9800;tick();CHECK(fabsf(left.high-.43f)<1e-6,"shield damage produces short impact");
    CHECK(t.writes==right_writes,"shield impact leaves accepted bow output unchanged");
    shield.guarding=0;tick();CHECK(left.high>.28f,"impact survives brief guard recoil");
    for(int i=0;i<6;i++)tick();CHECK(g_left_sent==-1,"recoil effect expires without sticky resistance");
    shield.guarding=1;tick();CHECK(left.high==.28f,"guard resumes baseline after impact");
    shield.durability=10000;tick();CHECK(left.high==.28f,"repair is not a hit");
    shield.shield=21;shield.durability=400;tick();CHECK(left.high==.28f,"swap to weaker shield is not a hit");
    shield.generation++;shield.durability=300;tick();CHECK(left.high==.28f,"reused shield identity is not a hit");
    shield.guarding=0;tick();shield.durability=200;shield.guarding=1;tick();CHECK(left.high==.28f,"unguarded wear is not a block");
    shield.durability=190;now+=500000000;tick();CHECK(left.high==.28f,"old damage after scheduling gap is not replayed");
    shield.valid=0;tick();CHECK(g_left_sent==-1,"pause/unequip/break stops left effect");
    shield.valid=1;shield.durability=180;tick();CHECK(left.high==.28f,"resume does not replay damage while paused");
    shield.durability=170;tick();left.value=0;tick();CHECK(g_left_sent==-1,"physical release clears even during impact");
    left.value=1;tick();CHECK(left.high==.28f,"next shield pull has no leftover impact");
    dm_adaptive_trigger_set_active(0);CHECK(g_left_sent==-1,"window/session loss clears both triggers");
    dm_adaptive_trigger_set_active(1);tick();stops=left.stops;dm_adaptive_trigger_attach(nil);CHECK(left.stops==stops+1,"disconnect clears left trigger too");
    dm_adaptive_trigger_attach((id)c);sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;left.value=0;tick();
    int native_writes=t.writes,native_stops=t.stops;
    dm_adaptive_trigger_set_usb_output(usb_output);tick();
    CHECK(usb_writes[0]&&usb_writes[1]&&usb_effect[1].enabled&&usb_effect[1].high==.35f,"USB ownership receives the accepted bow preload parameters");
    CHECK(t.writes==native_writes&&t.stops==native_stops,"entering USB never emits conflicting native trigger reports");
    sample.phase=DM_BOW_DRAW;sample.charge=1;t.value=1;tick();
    CHECK(usb_effect[1].high>.35f&&t.writes==native_writes,"charge updates use only the shared USB report owner");
    dm_adaptive_trigger_set_active(0);CHECK(!usb_effect[0].enabled&&!usb_effect[1].enabled&&t.stops==native_stops,"pause releases USB effects without native writes");
    dm_adaptive_bow_shot_sample=read_shot;
    dm_adaptive_trigger_set_active(1);sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;tick();
    sample.phase=DM_BOW_DRAW;sample.charge=1;t.value=1;tick();
    unsigned left_writes=usb_writes[0];
    shot=(dm_bow_shot){1,1,now+20000000,1};sample=(dm_bow_snapshot){0};t.value=.1;tick();
    CHECK(usb_effect[1].enabled&&usb_effect[1].high>.55f,"actual shot briefly pushes R2 back, including a shot that breaks its bow");
    CHECK(usb_writes[0]==left_writes&&t.writes==native_writes,"rebound preserves L2 and USB audio output ownership");
    last=usb_effect[1].high;
    for(int i=0;i<3;i++){tick();CHECK(usb_effect[1].enabled&&usb_effect[1].high<last,"rebound unloads progressively over 80 ms");last=usb_effect[1].high;}
    tick();CHECK(!usb_effect[1].enabled&&!g_recoil_until,"rebound terminates with no sticky resistance");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;tick();
    CHECK(usb_effect[1].enabled&&usb_effect[1].high==.35f,"successful shot returns to the accepted light preload");
    unsigned count=usb_writes[1];tick();CHECK(usb_writes[1]==count,"one shot notification cannot retrigger the effect");
    t.value=1;sample.phase=DM_BOW_DRAW;tick();sample.phase=DM_BOW_READY;tick();
    CHECK(!usb_effect[1].enabled&&!g_recoil_until,"cancelled draw unloads directly without rebound");
    t.value=0;tick();CHECK(!usb_effect[1].enabled,"cancelled draw stays unloaded after release");
    t.value=.03;tick();CHECK(usb_effect[1].enabled&&usb_effect[1].high==.35f,"next slight press rearms preload before digital ZR");
    t.value=1;sample.phase=DM_BOW_DRAW;tick();sample=(dm_bow_snapshot){0};t.value=0;tick();
    CHECK(!usb_effect[1].enabled&&!g_recoil_until,"empty bow or interrupted draw without a committed shot never rebounds");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};tick();
    CHECK(!usb_effect[1].enabled,"empty release remains unloaded when idle returns");
    t.value=1;sample.phase=DM_BOW_DRAW;tick();
    shot=(dm_bow_shot){2,99,now+20000000,1};sample=(dm_bow_snapshot){0};tick();
    CHECK(!g_recoil_until,"another actor's projectile cannot trigger R2");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;tick();sample.phase=DM_BOW_DRAW;t.value=1;tick();
    shot=(dm_bow_shot){3,1,now-200000000,1};sample=(dm_bow_snapshot){0};tick();
    CHECK(!g_recoil_until,"an old shot after a scheduling gap is not replayed");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;tick();sample.phase=DM_BOW_DRAW;t.value=1;tick();
    shot=(dm_bow_shot){4,1,now+20000000,1};sample=(dm_bow_snapshot){0};tick();
    shot.live=0;tick();CHECK(!g_recoil_until&&!usb_effect[1].enabled,"menu or player teardown clears rebound immediately");
    shot.live=1;dm_adaptive_trigger_set_active(0);dm_adaptive_trigger_set_active(1);tick();
    CHECK(!g_recoil_until,"resume discards a pending shot notification");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;tick();sample.phase=DM_BOW_DRAW;t.value=1;tick();
    sample=(dm_bow_snapshot){0};t.value=0;tick();
    shot=(dm_bow_shot){5,1,now+20000000,1};tick();
    CHECK(g_recoil_until&&usb_effect[1].enabled,"release notification arriving after the post-shot state is still handled once");
    dm_adaptive_trigger_set_active(0);CHECK(!usb_effect[1].enabled&&!g_recoil_until,"ineligibility also clears an in-flight rebound");
    sample=(dm_bow_snapshot){DM_BOW_READY,0,1,2,3};t.value=0;
    dm_adaptive_trigger_set_active(0);
    dm_adaptive_trigger_set_usb_output(NULL);dm_adaptive_trigger_set_active(1);t.value=0;tick();
    CHECK(t.writes==native_writes+1&&t.high==.35f,"leaving USB restores native trigger output and invalidates its cached state");
    dm_adaptive_trigger_shutdown();CHECK(!dm_adaptive_trigger_available()&&g_sent==-1,"shutdown releases effect");
    before=reads;tick();CHECK(reads==before,"no work after shutdown");
    printf("Adaptive trigger: %d checks, %d failures\n",checks,failed);return !!failed;
}}
