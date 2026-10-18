// Finder launch setup, following d2r-mobile's dm/host/app_mac.m approach.
// Resources are bundled; writable state belongs to the user's Library, never the app.
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "game_profile.h"

void dm_host_shutdown(const char *why);

static void env_default(const char *key, NSString *value) {
    setenv(key, value.fileSystemRepresentation, 0);
}

static void env_file(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length) setenv(key.UTF8String, [line substringFromIndex:eq.location + 1].UTF8String, 0);
    }
}

static int boot_error(NSString *message) {
    fprintf(stderr, "【红】%s\n", message.UTF8String);
    [NSApplication sharedApplication];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Unable to start the game";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    return 0;
}

@interface DmMacApp : NSObject <NSApplicationDelegate>
@end
@implementation DmMacApp
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dm_host_shutdown("Quit"); });
    return NSTerminateCancel;
}
@end

int dm_app_bootstrap(int *argc, char ***argv) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *res = bundle.resourcePath, *bid = bundle.bundleIdentifier;
        if (!bid.length || ![bundle.bundlePath.pathExtension isEqualToString:@"app"])
            return boot_error(@"Launch the packaged .app. Use dmhost for command-line runs.");
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:bid];
        NSString *logs = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Logs"] stringByAppendingPathComponent:bid];
        if (getenv("DM_APP_SUPPORT")) support = @(getenv("DM_APP_SUPPORT"));
        if (getenv("DM_APP_LOG_DIR")) logs = @(getenv("DM_APP_LOG_DIR"));
        for (NSString *dir in @[support, logs]) {
            NSError *error = nil;
            if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error])
                return boot_error(error.localizedDescription);
        }
        NSString *log = [logs stringByAppendingPathComponent:@"log.txt"], *prev = [logs stringByAppendingPathComponent:@"log.prev.txt"];
        [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
        if (!freopen(log.fileSystemRepresentation, "w", stderr)) return boot_error(@"Cannot open the game log.");
        setvbuf(stderr, NULL, _IOLBF, 0);
        NSString *dm = [res stringByAppendingPathComponent:@"dm"];
        // Shell variables win, followed by the user's env.txt, then the baked-in file.
        env_file([support stringByAppendingPathComponent:@"env.txt"]);
        env_file([dm stringByAppendingPathComponent:@"env.txt"]);
        env_default("DM_ROOT", support);
        env_default("DM_SAVE", [support stringByAppendingPathComponent:@"save"]);
        env_default("DM_TEMP", [support stringByAppendingPathComponent:@"temp"]);
        env_default("DM_ROMFS", [res stringByAppendingPathComponent:@"romfs"]);
        env_default("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"]);
        env_default("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"]);
        env_default("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"]);
        if ([fm fileExistsAtPath:[res stringByAppendingPathComponent:@"aoc"]])
            env_default("DM_AOC_DIR", [res stringByAppendingPathComponent:@"aoc"]);
        setenv("DM_WINDOW", "1", 0); setenv("DM_AUDIO", "1", 0);
        for (const char **key = (const char *[]){"DM_SAVE", "DM_TEMP", NULL}; *key; key++) {
            NSError *error = nil;
            if (![fm createDirectoryAtPath:@(getenv(*key)) withIntermediateDirectories:YES attributes:nil error:&error])
                return boot_error(error.localizedDescription);
        }
        NSString *marker = [@(getenv("DM_ROMFS")) stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER];
        if (![fm fileExistsAtPath:marker]) return boot_error([@"Missing game resources: " stringByAppendingString:marker]);
        if (chdir(support.fileSystemRepresentation)) return boot_error(@"Cannot open the application support folder.");
        // Finder may supply launch-service arguments; modules come from the game profile.
        static char *av[3]; av[0] = (*argv)[0]; av[1] = strdup(dm.fileSystemRepresentation);
        *argv = av; *argc = 2;
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"ApplePersistenceIgnoreState": @YES} forName:NSArgumentDomain];
        [NSApplication sharedApplication];
        static DmMacApp *delegate; delegate = [DmMacApp new]; NSApp.delegate = delegate;
        NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @DM_GAME_NAME;
        NSMenu *bar = [NSMenu new]; NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
        [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        NSMenuItem *viewItem = [NSMenuItem new]; [bar addItem:viewItem];
        NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
        NSMenuItem *full = [view addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
        full.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        viewItem.submenu = view; NSApp.mainMenu = bar;
        fprintf(stderr, "boot: game %s; resources %s; saves %s\n", DM_GAME_ID, res.fileSystemRepresentation, getenv("DM_SAVE"));
        return 1;
    }
}
