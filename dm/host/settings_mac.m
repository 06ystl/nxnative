#include "settings_mac.h"
#include "settings_store_mac.h"
#include "input_focus_mac.h"
#include "gamepad_mac.h"
#include "rumble_mac.h"
#include "motion_mac.h"
#include "timing_mac.h"
#include "resolution_mac.h"
#include <math.h>
#include <float.h>

static NSString *text(NSString *en,NSString *zh) {
    const char *language=getenv("DM_LANG");return language && !strncmp(language,"zh",2) ? zh : en;
}
static NSTextField *label(NSString *value,CGFloat size,BOOL secondary) {
    NSTextField *v=[NSTextField wrappingLabelWithString:value];
    v.font=[NSFont systemFontOfSize:size];v.textColor=secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    return v;
}
static NSStackView *vertical(NSArray<NSView *> *views,CGFloat gap) {
    NSStackView *s=[NSStackView stackViewWithViews:views];s.orientation=NSUserInterfaceLayoutOrientationVertical;
    s.alignment=NSLayoutAttributeLeading;s.spacing=gap;return s;
}
static NSStackView *horizontal(NSArray<NSView *> *views) {
    NSStackView *s=[NSStackView stackViewWithViews:views];s.orientation=NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment=NSLayoutAttributeCenterY;s.spacing=12;return s;
}
static NSButton *button(NSString *title,id target,SEL action) {return [NSButton buttonWithTitle:title target:target action:action];}
static NSString *const responseKey=@"MacControllerResponse";

@interface DmQuickSettings : NSObject <NSWindowDelegate,NSTextFieldDelegate>
@property (weak) NSWindow *game;
@property NSPanel *panel;
@property NSTimer *timer;
@property NSTextField *controller,*route,*motion,*saveState;
@property NSMutableArray<NSSlider *> *sliders;
@property NSMutableArray<NSTextField *> *numbers;
@property NSButton *preview,*calibrate,*connect,*invertH,*invertV,*hud;
@property NSPopUpButton *source,*resolution,*fps;
@property NSSegmentedControl *tabs;
@property NSArray<NSView *> *pages;
@property NSString *envPath;
@property double rumble,audio,trigger,horizontal,vertical;
@property int currentFPS;
@property NSString *currentResolution;
@property BOOL savingFailed;
- (void)show:(id)sender;
- (void)refresh;
@end
static DmQuickSettings *settings;

@implementation DmQuickSettings
- (void)pinWidth:(NSView *)view {
    [view.widthAnchor constraintEqualToConstant:532].active=YES;
}
- (void)saveEnv:(NSDictionary *)changes {
    NSError *error=nil;BOOL ok=dm_settings_env_write(self.envPath,changes,&error);
    self.savingFailed=!ok;
    self.saveState.textColor=ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
    self.saveState.stringValue=ok ? text(@"Changes saved automatically",@"更改已自动保存") :
        [NSString stringWithFormat:text(@"Could not save settings: %@",@"无法保存设置：%@"),error.localizedDescription];
}
- (void)saveResponse {
    self.savingFailed=NO;self.saveState.textColor=NSColor.secondaryLabelColor;
    self.saveState.stringValue=text(@"Changes saved automatically",@"更改已自动保存");
    [NSUserDefaults.standardUserDefaults setObject:@{@"trigger":@(self.trigger),@"horizontal":@(self.horizontal),@"vertical":@(self.vertical),
        @"invertH":@(self.invertH.state==NSControlStateValueOn),@"invertV":@(self.invertV.state==NSControlStateValueOn)} forKey:responseKey];
    dm_motion_mac_set_response(self.horizontal*(self.invertH.state ? -1 : 1),self.vertical*(self.invertV.state ? -1 : 1));
}
- (NSView *)level:(NSString *)title index:(NSInteger)index value:(double)value range:(double)range {
    NSTextField *name=label(title,13,NO);[name.widthAnchor constraintEqualToConstant:126].active=YES;
    NSSlider *slider=[NSSlider sliderWithValue:value minValue:0 maxValue:fmax(range,value) target:self action:@selector(levelChanged:)];
    slider.tag=index;slider.continuous=YES;slider.accessibilityLabel=title;[slider.widthAnchor constraintEqualToConstant:280].active=YES;
    NSTextField *number=[NSTextField textFieldWithString:[NSString stringWithFormat:@"%.6g",value]];
    number.tag=index;number.delegate=self;number.accessibilityLabel=title;number.alignment=NSTextAlignmentRight;
    [number.widthAnchor constraintEqualToConstant:72].active=YES;
    [self.sliders addObject:slider];[self.numbers addObject:number];
    return horizontal(@[name,slider,number,label(@"×",13,YES)]);
}
- (void)setLevel:(double)value index:(NSInteger)index {
    if (!isfinite(value) || value<0 || value>FLT_MAX) {
        self.saveState.stringValue=text(@"Enter a finite number of zero or greater",@"请输入大于或等于 0 的有效数字");return;
    }
    NSSlider *slider=self.sliders[index];slider.maxValue=fmax(slider.maxValue,value);slider.doubleValue=value;
    self.numbers[index].stringValue=[NSString stringWithFormat:@"%.6g",value];
    if(index==0)self.rumble=value;if(index==1)self.audio=value;if(index==2)self.trigger=value;
    if(index==3)self.horizontal=value;if(index==4)self.vertical=value;
    if(index<3)dm_rumble_mac_set_levels(self.rumble,self.audio,self.trigger);
    if(index<2)[self saveEnv:@{index==0 ? @"DM_RUMBLE_GAIN" : @"DM_AUDIO_HAPTICS_GAIN":[NSString stringWithFormat:@"%.8g",value]}];
    else [self saveResponse];
}
- (void)levelChanged:(NSSlider *)sender { [self setLevel:round(sender.doubleValue*100)/100 index:sender.tag]; }
- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSTextField *field=note.object;NSScanner *scanner=[NSScanner scannerWithString:field.stringValue];double value;
    if([scanner scanDouble:&value] && scanner.isAtEnd)[self setLevel:value index:field.tag];
    else self.saveState.stringValue=text(@"Enter a valid multiplier",@"请输入有效的倍率");
}
- (void)invertChanged:(id)sender { (void)sender;[self saveResponse]; }
- (void)sourceChanged:(id)sender {
    (void)sender;int phone=self.source.indexOfSelectedItem==1;
    dm_motion_mac_select_phone(phone);[self saveEnv:@{@"DM_MOTION_SOURCE":phone ? @"phone" : @"controller"}];[self refresh];
}
- (void)displayChanged:(id)sender {
    (void)sender;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    if(self.resolution.selectedItem.representedObject)values[@"DM_GAME_RES"]=self.resolution.selectedItem.representedObject;
    if(self.fps.selectedItem.representedObject)values[@"DM_FPS"]=self.fps.selectedItem.representedObject;
    values[@"DM_METAL_HUD"]=self.hud.state==NSControlStateValueOn ? @"1" : @"0";
    [self saveEnv:values];
    if(!self.savingFailed)self.saveState.stringValue=text(@"Saved · display changes apply after restarting the game",@"已保存 · 画面设置将在重启游戏后生效");
}
- (void)previewPressed:(id)sender {
    (void)sender;
    if(!dm_rumble_mac_preview())self.saveState.stringValue=text(@"Connect a controller with vibration support",@"请连接支持震动的手柄");
    [self refresh];
}
- (void)calibratePressed:(id)sender { (void)sender;dm_motion_mac_calibrate_now();[self refresh]; }
- (void)connectPressed:(id)sender { (void)sender;dm_motion_mac_connect_phone();[self refresh]; }
- (void)tabChanged:(id)sender {
    (void)sender;for(NSUInteger i=0;i<self.pages.count;i++)self.pages[i].hidden=i!=self.tabs.selectedSegment;
}
- (void)popup:(NSPopUpButton *)popup title:(NSString *)title value:(NSString *)value {
    [popup addItemWithTitle:title];popup.lastItem.representedObject=value;
}
- (void)build {
    self.sliders=[NSMutableArray array];self.numbers=[NSMutableArray array];
    self.panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,596,592) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.panel.title=text(@"Game Settings",@"游戏设置");self.panel.releasedWhenClosed=NO;self.panel.delegate=self;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorMoveToActiveSpace;
    self.panel.level=NSFloatingWindowLevel;[self.panel setFrameAutosaveName:@"QuickSettings"];
    dm_mac_input_settings_window(self.panel);
    NSView *content=self.panel.contentView;
    self.controller=label(text(@"Controller",@"手柄"),17,NO);self.controller.font=[NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.route=label(@"",12,YES);
    self.tabs=[NSSegmentedControl segmentedControlWithLabels:@[text(@"Controller",@"手柄"),text(@"Motion",@"体感"),text(@"Display",@"画面")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(tabChanged:)];
    self.tabs.selectedSegment=0;
    NSStackView *head=vertical(@[self.controller,self.route,self.tabs],10);head.translatesAutoresizingMaskIntoConstraints=NO;
    [content addSubview:head];[head.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32].active=YES;
    [head.topAnchor constraintEqualToAnchor:content.topAnchor constant:24].active=YES;
    [self pinWidth:head];[self pinWidth:self.tabs];
    self.preview=button(text(@"Test vibration",@"预览震动"),self,@selector(previewPressed:));
    NSStackView *feedback=vertical(@[
        label(text(@"Vibration & triggers",@"震动与扳机"),15,NO),
        [self level:text(@"Game rumble",@"普通震动") index:0 value:self.rumble range:40],
        [self level:text(@"Audio haptics",@"音频触觉") index:1 value:self.audio range:40],
        [self level:text(@"Trigger resistance",@"扳机阻力") index:2 value:self.trigger range:2],
        label(text(@"USB DualSense uses audio haptics when available. Other connections use game rumble. Trigger resistance is independent.",@"DualSense 通过 USB 连接时使用音频触觉，其他连接使用普通震动。扳机阻力独立调节。"),13,YES),
        self.preview,label(text(@"A short preview uses the current output and multiplier. Changes take effect immediately.",@"短促预览会使用当前输出方式和倍率。调节即时生效。"),12,YES)],20);
    for(NSView *v in feedback.arrangedSubviews)if([v isKindOfClass:NSTextField.class])[self pinWidth:v];
    self.source=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.source addItemsWithTitles:@[text(@"Controller gyroscope",@"手柄陀螺仪"),text(@"Phone (MotionSource)",@"手机（MotionSource）")]];
    [self.source selectItemAtIndex:dm_motion_mac_get_status().phone];self.source.target=self;self.source.action=@selector(sourceChanged:);
    self.motion=label(@"",13,YES);[self pinWidth:self.motion];
    self.calibrate=button(text(@"Calibrate",@"重新校准"),self,@selector(calibratePressed:));
    self.connect=button(text(@"Connect phone…",@"连接手机…"),self,@selector(connectPressed:));
    self.invertH=[NSButton checkboxWithTitle:text(@"Invert horizontal",@"反转水平") target:self action:@selector(invertChanged:)];
    self.invertV=[NSButton checkboxWithTitle:text(@"Invert vertical",@"反转垂直") target:self action:@selector(invertChanged:)];
    NSDictionary *response=[NSUserDefaults.standardUserDefaults dictionaryForKey:responseKey];
    self.invertH.state=[response[@"invertH"] boolValue];self.invertV.state=[response[@"invertV"] boolValue];
    NSStackView *motion=vertical(@[horizontal(@[label(text(@"Motion source",@"体感来源"),13,NO),self.source]),self.motion,
        horizontal(@[self.calibrate,self.connect]),
        label(text(@"Keep the controller or phone still for one second to calibrate.",@"校准时，请让手柄或手机保持静止约 1 秒。"),12,YES),
        [self level:text(@"Horizontal",@"水平灵敏度") index:3 value:self.horizontal range:3],
        [self level:text(@"Vertical",@"垂直灵敏度") index:4 value:self.vertical range:3],
        horizontal(@[self.invertH,self.invertV]),
        label(text(@"Also enable motion aiming in the game's own settings. Buttons and sticks are paused while this panel has focus.",@"还需在游戏自身设置中开启体感瞄准。此面板获得焦点时，手柄按键与摇杆暂停传给游戏。"),12,YES)],18);
    for(NSView *v in motion.arrangedSubviews)if([v isKindOfClass:NSTextField.class])[self pinWidth:v];
    self.resolution=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    if(dm_resolution_mac_has_presets(dm_main_build())) {
        [self popup:self.resolution title:text(@"Game default",@"游戏默认") value:@""];
        [self popup:self.resolution title:@"1920 × 1080" value:@"1920x1080"];
        [self popup:self.resolution title:@"1280 × 720" value:@"1280x720"];
    } else [self popup:self.resolution title:text(@"Game default",@"游戏默认") value:nil];
    self.currentResolution=getenv("DM_GAME_RES") ? @(getenv("DM_GAME_RES")) : @"";
    for(NSMenuItem *item in self.resolution.itemArray)if([item.representedObject isEqual:self.currentResolution])[self.resolution selectItem:item];
    self.resolution.enabled=dm_resolution_mac_has_presets(dm_main_build());self.resolution.target=self;self.resolution.action=@selector(displayChanged:);
    self.fps=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];self.currentFPS=dm_game_frame_target();
    NSArray *rates=self.currentFPS>0 ? @[@30,@60,@90,@120] : @[@30,@60];
    for(NSNumber *rate in rates)[self popup:self.fps title:[NSString stringWithFormat:@"%@ FPS",rate] value:rate.stringValue];
    NSString *fpsValue=getenv("DM_FPS") ? @(getenv("DM_FPS")) : [NSString stringWithFormat:@"%d",self.currentFPS>0 ? self.currentFPS : (DM_GAME_FPS_TARGET>0 ? DM_GAME_FPS_TARGET : 60)];
    for(NSMenuItem *item in self.fps.itemArray)if([item.representedObject isEqual:fpsValue])[self.fps selectItem:item];
    self.fps.target=self;self.fps.action=@selector(displayChanged:);
    self.hud=[NSButton checkboxWithTitle:text(@"Show FPS and Metal performance HUD",@"显示 FPS 与 Metal 性能信息") target:self action:@selector(displayChanged:)];
    self.hud.state=(getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) ? NSControlStateValueOn : NSControlStateValueOff;
    NSStackView *display=vertical(@[label(text(@"Applies after restarting the game",@"以下设置在重启游戏后生效"),15,NO),
        horizontal(@[label(text(@"Resolution",@"渲染分辨率"),13,NO),self.resolution]),
        horizontal(@[label(text(@"Frame-rate target",@"帧率目标"),13,NO),self.fps]),self.hud,
        label(text(@"Your current game keeps running with its existing display settings. A higher target needs headroom from both the Mac and display.",@"当前游戏会继续使用启动时的画面设置。更高的帧率目标需要电脑性能与显示器刷新率支持。"),13,YES)],22);
    for(NSView *v in display.arrangedSubviews)if([v isKindOfClass:NSTextField.class])[self pinWidth:v];
    self.pages=@[feedback,motion,display];
    for(NSView *page in self.pages) {
        page.translatesAutoresizingMaskIntoConstraints=NO;[content addSubview:page];
        [page.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:28].active=YES;
        [page.leadingAnchor constraintEqualToAnchor:head.leadingAnchor].active=YES;[self pinWidth:page];
    }
    self.saveState=label(text(@"Changes saved automatically",@"更改已自动保存"),12,YES);self.saveState.translatesAutoresizingMaskIntoConstraints=NO;
    [content addSubview:self.saveState];[self.saveState.leadingAnchor constraintEqualToAnchor:head.leadingAnchor].active=YES;
    [self.saveState.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-22].active=YES;[self pinWidth:self.saveState];
    [self tabChanged:nil];
}
- (void)refresh {
    dm_feedback_mac_status f=dm_rumble_mac_get_status();
    self.controller.stringValue=f.connected ? @(f.controller) : text(@"No controller connected",@"尚未连接手柄");
    self.route.stringValue=f.audio_ready ? text(@"USB · audio haptics",@"USB · 音频触觉") :
        f.connected ? text(@"Controller · game rumble",@"手柄 · 普通震动") : text(@"Connect over USB or Bluetooth",@"可通过 USB 或蓝牙连接");
    self.preview.enabled=f.connected && !f.previewing;
    self.preview.title=f.previewing ? text(@"Playing…",@"正在预览…") : text(@"Test vibration",@"预览震动");
    self.sliders[2].enabled=f.triggers;self.numbers[2].enabled=f.triggers;
    dm_motion_mac_status m=dm_motion_mac_get_status();NSString *status=@(m.message);
    NSDictionary *translations=@{@"Controller gyro unavailable":@"当前手柄或连接方式不提供陀螺仪",@"Controller motion paused":@"手柄体感已暂停",@"Waiting for controller motion":@"等待手柄体感数据",@"Waiting for usable controller motion data":@"等待有效的手柄体感数据",@"Controller motion connected":@"手柄体感已连接",@"Calibrating: hold the controller still for one second":@"正在校准：请保持手柄静止约 1 秒",@"Phone motion off":@"手机体感未连接",@"Phone motion connected":@"手机体感已连接",@"Phone motion unavailable":@"手机体感暂不可用",@"Calibrating: hold the phone still for one second":@"正在校准：请保持手机静止约 1 秒",@"Connecting to phone":@"正在连接手机",@"Phone motion lost; reconnecting automatically":@"手机体感连接中断，正在重连"};
    self.motion.stringValue=text(status,translations[status] ?: status);
    self.calibrate.enabled=m.can_calibrate;self.connect.hidden=!m.phone;
    [self.source selectItemAtIndex:m.phone];
}
- (void)show:(id)sender {
    (void)sender;if(!self.panel)[self build];[self refresh];
    if(!self.panel.visible)[self.panel center];[self.panel makeKeyAndOrderFront:nil];
    if(!self.timer){__weak DmQuickSettings *weak=self;self.timer=[NSTimer timerWithTimeInterval:.5 repeats:YES block:^(NSTimer *t){(void)t;[weak refresh];}];[NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];}
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    (void)window;[self.panel makeFirstResponder:nil];[self.timer invalidate];self.timer=nil;
    dm_rumble_mac_stop_preview();[self.panel orderOut:nil];[self.game makeKeyWindow];return NO;
}
@end

int dm_settings_mac_interacting(void) {return NSApp.active && settings.panel.visible && settings.panel.keyWindow;}
void dm_settings_mac_start(NSWindow *game) {
    if(settings)return;settings=[DmQuickSettings new];settings.game=game;
    NSString *support=getenv("DM_APP_SUPPORT") ? @(getenv("DM_APP_SUPPORT")) :
        [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:
            NSBundle.mainBundle.bundleIdentifier ?: [@"org.nxnative." stringByAppendingString:[@DM_GAME_ID lowercaseString]]];
    settings.envPath=[support stringByAppendingPathComponent:@"env.txt"];
    dm_feedback_mac_status f=dm_rumble_mac_get_status();settings.rumble=f.rumble;settings.audio=f.audio;settings.trigger=1;settings.horizontal=settings.vertical=1;
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:responseKey];
    double t=[saved[@"trigger"] doubleValue],h=[saved[@"horizontal"] doubleValue],v=[saved[@"vertical"] doubleValue];
    if(saved[@"trigger"] && isfinite(t) && t>=0 && t<=FLT_MAX)settings.trigger=t;
    if(saved[@"horizontal"] && isfinite(h) && h>=0 && h<=FLT_MAX)settings.horizontal=h;
    if(saved[@"vertical"] && isfinite(v) && v>=0 && v<=FLT_MAX)settings.vertical=v;
    dm_rumble_mac_set_levels(settings.rumble,settings.audio,settings.trigger);
    dm_motion_mac_set_response(settings.horizontal*([saved[@"invertH"] boolValue] ? -1 : 1),settings.vertical*([saved[@"invertV"] boolValue] ? -1 : 1));
    // Native text fields need responder-chain editing shortcuts even when the
    // game frontend supplied only App/View menus.
    if (![NSApp.mainMenu itemWithTitle:@"Edit"] && ![NSApp.mainMenu itemWithTitle:@"编辑"]) {
        NSMenuItem *item=[NSMenuItem new];NSMenu *edit=[[NSMenu alloc] initWithTitle:text(@"Edit",@"编辑")];item.title=edit.title;item.submenu=edit;
        [edit addItemWithTitle:text(@"Cut",@"剪切") action:@selector(cut:) keyEquivalent:@"x"];
        [edit addItemWithTitle:text(@"Copy",@"复制") action:@selector(copy:) keyEquivalent:@"c"];
        [edit addItemWithTitle:text(@"Paste",@"粘贴") action:@selector(paste:) keyEquivalent:@"v"];
        [edit addItem:NSMenuItem.separatorItem];
        [edit addItemWithTitle:text(@"Select All",@"全选") action:@selector(selectAll:) keyEquivalent:@"a"];
        [NSApp.mainMenu insertItem:item atIndex:MIN(1,NSApp.mainMenu.numberOfItems)];
    }
    NSMenu *menu=NSApp.mainMenu.itemArray.firstObject.submenu;
    if(menu){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:text(@"Settings…",@"设置…") action:@selector(show:) keyEquivalent:@","];item.target=settings;
        [menu insertItem:item atIndex:0];[menu insertItem:NSMenuItem.separatorItem atIndex:1];}
}
