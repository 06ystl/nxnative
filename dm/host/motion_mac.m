// Phone gyro settings belong to the app's preferences, not env.txt. The DSU
// worker publishes snapshots independently of GameController and the renderer.
#import <Cocoa/Cocoa.h>
#include "motion_mac.h"
#include "motion_dsu_mac.h"

static dm_dsu_client *g_motion;
static int read_phone(dm_sixaxis_state *state, int fusion) { return dm_dsu_read(g_motion, state, fusion); }

@interface DmMotionMenu : NSObject
@property NSMenuItem *statusItem;
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
    dm_dsu_status status = dm_dsu_get_status(g_motion);
    self.statusItem.title = status.phase == DM_DSU_OFF ? @"Phone motion off" : @(status.message);
    self.calibrateItem.enabled = status.phase == DM_DSU_READY || status.phase == DM_DSU_CALIBRATING;
    self.disconnectItem.enabled = status.phase != DM_DSU_OFF;
}
- (void)connectPhone:(id)sender {
    (void)sender;
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
    alert.messageText = @"Calibrate phone motion";
    alert.informativeText = @"Lay the phone flat with the screen facing up, then keep it still for one second after pressing Calibrate. This measures gyro drift and resets the heading. The Motion menu shows when calibration is complete.";
    [alert addButtonWithTitle:@"Calibrate"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) dm_dsu_calibrate(g_motion);
    [self refresh];
}
- (void)disconnectPhone:(id)sender {
    (void)sender;
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
    g_motion = dm_dsu_create();
    if (!g_motion) { fprintf(stderr,"【红】Could not start phone motion worker\n"); return; }
    dm_motion_read = read_phone;
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
    connect.target = owner;
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
    if ([prefs boolForKey:@"MotionSourceEnabled"] && host.length && port > 0 && port <= 65535)
        dm_dsu_configure(g_motion,host.UTF8String,(unsigned)port);
    [owner refresh];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; [owner refresh]; }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
void dm_motion_mac_set_active(int active) { if (g_motion) dm_dsu_set_active(g_motion,active); }
