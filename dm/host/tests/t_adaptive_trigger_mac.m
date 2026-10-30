// Only simulated endpoints: this test never enumerates physical controllers.
#include "../adaptive_trigger_mac.m"
static int checks,failed,reads;
static dm_bow_snapshot sample;
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
    dm_adaptive_trigger_attach((id)c);tick();dm_adaptive_trigger_shutdown();CHECK(!dm_adaptive_trigger_available()&&g_sent==-1,"shutdown releases effect");
    before=reads;tick();CHECK(reads==before,"no work after shutdown");
    printf("Adaptive trigger: %d checks, %d failures\n",checks,failed);return !!failed;
}}
