// Native panel and real atomic env-file persistence; feedback and sensor endpoints are synthetic.
#include "../settings_mac.m"
#include "../front.h"
#import <objc/runtime.h>
static int checks,failed,previewCount,sourcePhone,calibrations;
static double responseH=1,responseV=1;
static dm_feedback_mac_status feedback={20,10,1,1,1,1,0,"DualSense Wireless Controller"};
module_t *g_mod;int g_nmod;
dm_feedback_mac_status dm_rumble_mac_get_status(void){return feedback;}
void dm_rumble_mac_set_levels(float r,float a,float t){feedback.rumble=r;feedback.audio=a;feedback.trigger=t;}
int dm_rumble_mac_preview(void){previewCount++;return 1;}
void dm_rumble_mac_stop_preview(void){}
dm_motion_mac_status dm_motion_mac_get_status(void){dm_motion_mac_status s={sourcePhone,1,{0}};strcpy(s.message,sourcePhone?"Phone motion connected":"Controller motion connected");return s;}
void dm_motion_mac_select_phone(int p){sourcePhone=p;}
void dm_motion_mac_set_response(double h,double v){responseH=h;responseV=v;}
void dm_motion_mac_calibrate_now(void){calibrations++;}
void dm_motion_mac_connect_phone(void){}
int dm_game_frame_target(void){return 60;}
int dm_resolution_mac_has_presets(const char *b){(void)b;return 1;}
void dm_mac_input_settings_window(NSWindow *w){(void)w;}
@interface FixturePreferences : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation FixturePreferences
- (NSDictionary *)dictionaryForKey:(NSString *)key{return self.values[key];}
- (void)setObject:(id)value forKey:(NSString *)key{self.values[key]=value;}
@end
static FixturePreferences *preferences;
static id fixture_defaults(id cls,SEL sel){(void)cls;(void)sel;return preferences;}
#define CHECK(c,msg) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL %s (line %d)\n",msg,__LINE__);}}while(0)
static NSString *read_text(NSString *path){return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];}
int main(int argc,char **argv){@autoreleasepool{
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    preferences=[[FixturePreferences alloc] initWithSuiteName:[@"org.nxnative.settings-test." stringByAppendingString:NSUUID.UUID.UUIDString]];preferences.values=[NSMutableDictionary dictionary];
    Method method=class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults));IMP original=method_setImplementation(method,(IMP)fixture_defaults);
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[root stringByAppendingPathComponent:@"env.txt"];
    NSString *initial=@"# My settings\nDM_LANG=zh-Hans\nDM_RUMBLE_GAIN=20\nDM_RUMBLE_GAIN=7\nDM_AUDIO_HAPTICS_GAIN=10\nDM_CUSTOM=a=b\n";
    [initial writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    setenv("DM_APP_SUPPORT",root.UTF8String,1);setenv("DM_LANG","zh-Hans",1);setenv("DM_GAME_RES","1920x1080",1);setenv("DM_FPS","60",1);setenv("DM_METAL_HUD","1",1);
    unsetenv("MTL_HUD_ENABLED");front_hud_env();CHECK(getenv("MTL_HUD_ENABLED")&&!strcmp(getenv("MTL_HUD_ENABLED"),"1"),"loaded HUD preference reaches Metal before device creation");
    unsetenv("MTL_HUD_ENABLED");setenv("DM_METAL_HUD","0",1);front_hud_env();CHECK(!getenv("MTL_HUD_ENABLED"),"a fresh launch with HUD off leaves Metal disabled");setenv("DM_METAL_HUD","1",1);
    NSMenu *bar=[NSMenu new];NSMenuItem *item=[NSMenuItem new];item.submenu=[NSMenu new];[bar addItem:item];NSApp.mainMenu=bar;
    dm_settings_mac_start(nil);[settings build];[settings refresh];
    CHECK([bar.itemArray.firstObject.submenu.itemArray.firstObject.keyEquivalent isEqual:@","],"Command-comma opens settings through the app menu");
    CHECK(settings.rumble==20&&settings.audio==10&&settings.numbers[0].doubleValue==20,"panel preserves effective user multipliers when opened");
    CHECK([read_text(path) isEqual:initial],"opening settings does not rewrite user configuration");
    [settings setLevel:35 index:0];
    NSString *saved=read_text(path);
    CHECK(feedback.rumble==35&&[saved containsString:@"DM_RUMBLE_GAIN=35\n"],"rumble changes apply and persist");
    CHECK(![saved containsString:@"DM_RUMBLE_GAIN=7"]&&[saved containsString:@"# My settings"]&&[saved containsString:@"DM_CUSTOM=a=b"],"duplicate owned keys are removed while comments and unrelated values survive");
    [settings setLevel:70 index:1];CHECK(feedback.audio==70&&settings.sliders[1].maxValue>=70,"typed gains can exceed the slider's initial range");
    [settings setLevel:NAN index:1];CHECK(feedback.audio==70,"invalid input cannot corrupt live output");
    [settings setLevel:1.5 index:2];[settings setLevel:2 index:3];[settings setLevel:.5 index:4];
    settings.invertH.state=NSControlStateValueOn;[settings invertChanged:nil];
    CHECK(feedback.trigger==1.5&&responseH==-2&&responseV==.5,"trigger strength and signed axis response use their runtime owners");
    CHECK([preferences.values[responseKey][@"trigger"] doubleValue]==1.5,"new controller preferences persist separately from existing env values");
    [settings.source selectItemAtIndex:1];[settings sourceChanged:nil];
    CHECK(sourcePhone&&[read_text(path) containsString:@"DM_MOTION_SOURCE=phone"],"source switches live and persists");
    [settings.source selectItemAtIndex:0];[settings sourceChanged:nil];
    CHECK(!sourcePhone&&[read_text(path) containsString:@"DM_MOTION_SOURCE=controller"],"controller mode resumes without a restart");
    [settings calibratePressed:nil];[settings previewPressed:nil];CHECK(calibrations==1&&previewCount==1,"calibration and user-requested preview reach their endpoints");
    [settings.resolution selectItemWithTitle:@"1280 × 720"];[settings.fps selectItemWithTitle:@"120 FPS"];settings.hud.state=NSControlStateValueOff;[settings displayChanged:nil];
    CHECK([read_text(path) containsString:@"DM_GAME_RES=1280x720"]&&[read_text(path) containsString:@"DM_FPS=120"]&&[read_text(path) containsString:@"DM_METAL_HUD=0"],"display selections persist for the next launch");
    CHECK(!strcmp(getenv("DM_GAME_RES"),"1920x1080")&&!strcmp(getenv("DM_FPS"),"60")&&feedback.audio==70,"restart-only changes leave the running game and live controls intact");
    NSError *error=nil;CHECK(!dm_settings_env_write(root,@{@"DM_FPS":@"60"},&error)&&error,"unreadable configuration refuses replacement and reports the save error");
    for(NSInteger i=0;i<3;i++){settings.tabs.selectedSegment=i;[settings tabChanged:nil];for(NSInteger j=0;j<3;j++)CHECK(settings.pages[j].hidden==(i!=j),"tab switch shows exactly its own controls");}
    [settings.panel orderOut:nil];settings=nil;dm_settings_mac_start(nil);
    CHECK(settings.trigger==1.5&&settings.horizontal==2&&settings.vertical==.5&&responseH==-2,"next settings instance restores trigger and gyro preferences");
    if(argc>1&&!strcmp(argv[1],"--show")){
        feedback=(dm_feedback_mac_status){20,10,1,1,1,1,0,"DualSense Wireless Controller"};
        preferences.values=[NSMutableDictionary dictionary];settings=nil;dm_settings_mac_start(nil);[settings show:nil];
        [NSApp activateIgnoringOtherApps:YES];fprintf(stderr,"PREVIEW_READY\n");[NSApp run];
    }
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];method_setImplementation(method,original);
    printf("SETTINGS_MAC checks=%d failed=%d\n",checks,failed);return failed!=0;
}}
