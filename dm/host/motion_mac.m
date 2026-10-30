// env.txt chooses controller (default) or phone. Phone connection details stay
// in app preferences. Both sources publish snapshots independently of rendering.
#import <Cocoa/Cocoa.h>
#include "motion_mac.h"
#include "motion_dsu_mac.h"
#include "motion_controller_mac.h"

static dm_dsu_client *g_motion;
static int g_phone_mode;
static int read_phone(dm_sixaxis_state *state, int fusion) {
    if (g_motion) return dm_dsu_read(g_motion,state,fusion);
    memset(state,0,sizeof *state); return 0;
}
static int motion_uses_phone(void) {
    const char *source = getenv("DM_MOTION_SOURCE");
    if (!source || !*source || !strcmp(source,"controller")) return 0;
    if (!strcmp(source,"phone")) return 1;
    fprintf(stderr,"【红】DM_MOTION_SOURCE=%s: must be controller or phone; using controller\n",source);
    return 0;
}
static void motion_source_start(void) {
    g_phone_mode = motion_uses_phone();
    dm_controller_motion_enable(!g_phone_mode);
    dm_motion_read = g_phone_mode ? read_phone : dm_controller_motion_read;
    if (g_phone_mode) {
        g_motion = dm_dsu_create();
        if (!g_motion) fprintf(stderr,"【红】Could not start phone motion worker\n");
    }
    fprintf(stderr,"[dm] Motion source: %s (DM_MOTION_SOURCE)\n",g_phone_mode ? "phone" : "controller");
}

@interface DmMotionMenu : NSObject
@property NSMenuItem *statusItem;
@property NSMenuItem *connectItem;
@property NSMenuItem *calibrateItem;
@property NSMenuItem *disconnectItem;
- (void)refresh;
- (void)connectPhone:(id)sender;
- (void)calibratePhone:(id)sender;
- (void)disconnectPhone:(id)sender;
- (void)downloadSource:(id)sender;
@end

@implementation DmMotionMenu
- (void)refresh {
    if (!g_phone_mode) {
        dm_controller_motion_status status = dm_controller_motion_get_status();
        self.statusItem.title = @(status.message);
        self.calibrateItem.enabled = status.can_calibrate;
        self.connectItem.enabled = self.disconnectItem.enabled = NO;
        return;
    }
    self.connectItem.enabled = g_motion != NULL;
    if (!g_motion) { self.statusItem.title = @"Phone motion unavailable"; self.calibrateItem.enabled = self.disconnectItem.enabled = NO; return; }
    dm_dsu_status status = dm_dsu_get_status(g_motion);
    self.statusItem.title = status.phase == DM_DSU_OFF ? @"Phone motion off" : @(status.message);
    self.calibrateItem.enabled = status.phase == DM_DSU_READY || status.phase == DM_DSU_CALIBRATING;
    self.disconnectItem.enabled = status.phase != DM_DSU_OFF;
}
- (void)connectPhone:(id)sender {
    (void)sender;
    if (!g_phone_mode || !g_motion) return;
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    NSTextField *host = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 38, 340, 24)];
    host.placeholderString = @"Phone IP address shown in MotionSource";
    host.stringValue = [prefs stringForKey:@"MotionSourceHost"] ?: @"";
    NSTextField *port = [[NSTextField alloc] initWithFrame:NSMakeRect(250, 0, 90, 24)];
    NSInteger savedPort = [prefs integerForKey:@"MotionSourcePort"];
    port.stringValue = [NSString stringWithFormat:@"%ld", (long)(savedPort ?: 26760)];
    NSTextField *label = [NSTextField labelWithString:@"Port"];
    label.frame = NSMakeRect(205, 2, 40, 20);
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 66)];
    [fields addSubview:host]; [fields addSubview:port]; [fields addSubview:label];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Connect phone motion";
    alert.informativeText = @"Open MotionSource on your iPhone, allow Local Network access and tap Start Server. Keep both devices on the same local network. Select Portrait, enable the accelerometer, then leave the phone still for one second after connecting. Keep the app open and the screen awake while playing.";
    alert.accessoryView = fields;
    [alert addButtonWithTitle:@"Connect"]; [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = host;
    for (;;) {
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        NSString *address = [host.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner = [NSScanner scannerWithString:port.stringValue]; int number = 0;
        if (address.length && strlen(address.UTF8String) < 256 &&
            [scanner scanInt:&number] && scanner.isAtEnd && number > 0 && number <= 65535) {
            [prefs setObject:address forKey:@"MotionSourceHost"];
            [prefs setInteger:number forKey:@"MotionSourcePort"];
            [prefs setBool:YES forKey:@"MotionSourceEnabled"];
            dm_dsu_configure(g_motion,address.UTF8String,(unsigned)number); [self refresh]; return;
        }
        alert.informativeText = @"Enter the phone's IP address and a port from 1 to 65535 (MotionSource defaults to 26760).";
    }
}
- (void)calibratePhone:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = g_phone_mode ? @"Calibrate phone motion" : @"Calibrate controller motion";
    alert.informativeText = g_phone_mode ? @"Lay the phone flat with the screen facing up, then keep it still for one second after pressing Calibrate. This measures gyro drift and resets the heading. The Motion menu shows when calibration is complete." : @"Lay the controller still, buttons facing up, for one second after pressing Calibrate. This measures gyro drift and resets the heading.";
    [alert addButtonWithTitle:@"Calibrate"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        if (g_phone_mode && g_motion) dm_dsu_calibrate(g_motion);
        else if (!g_phone_mode) dm_controller_motion_calibrate();
    }
    [self refresh];
}
- (void)disconnectPhone:(id)sender {
    (void)sender;
    if (!g_phone_mode || !g_motion) return;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"MotionSourceEnabled"];
    dm_dsu_configure(g_motion,"",0); [self refresh];
}
- (void)downloadSource:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/shiftinv/MotionSourceiOS/releases/tag/v1.1.0"]];
}
@end

void dm_motion_mac_start(void) {
    static DmMotionMenu *owner;
    if (owner) return;
    motion_source_start();
    owner = [DmMotionMenu new];
    NSMenu *bar = NSApp.mainMenu;
    if (!bar) { bar = [NSMenu new]; NSApp.mainMenu = bar; }
    NSMenuItem *item = [NSMenuItem new]; [bar addItem:item];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Motion"]; menu.autoenablesItems = NO;
    item.submenu = menu;
    owner.statusItem = [menu addItemWithTitle:@"Phone motion off" action:nil keyEquivalent:@""];
    owner.statusItem.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *connect = [menu addItemWithTitle:@"Connect Phone…" action:@selector(connectPhone:) keyEquivalent:@""];
    connect.target = owner; owner.connectItem = connect;
    if (!g_phone_mode) {
        NSMenuItem *hint = [menu addItemWithTitle:@"For phone: set DM_MOTION_SOURCE=phone and restart" action:nil keyEquivalent:@""];
        hint.enabled = NO;
    }
    owner.calibrateItem = [menu addItemWithTitle:@"Calibrate…" action:@selector(calibratePhone:) keyEquivalent:@""];
    owner.calibrateItem.target = owner;
    owner.disconnectItem = [menu addItemWithTitle:@"Disconnect Phone" action:@selector(disconnectPhone:) keyEquivalent:@""];
    owner.disconnectItem.target = owner;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *download = [menu addItemWithTitle:@"Get MotionSource…" action:@selector(downloadSource:) keyEquivalent:@""];
    download.target = owner;
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    NSString *host = [prefs stringForKey:@"MotionSourceHost"];
    NSInteger port = [prefs integerForKey:@"MotionSourcePort"];
    if (g_phone_mode && g_motion && [prefs boolForKey:@"MotionSourceEnabled"] && host.length && port > 0 && port <= 65535)
        dm_dsu_configure(g_motion,host.UTF8String,(unsigned)port);
    [owner refresh];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; [owner refresh]; }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
void dm_motion_mac_set_active(int active) {
    dm_controller_motion_set_active(active);
    if (g_motion) dm_dsu_set_active(g_motion,active);
}
