// Per-launch presentation for Wine's separately spawned macOS processes.
// No graphics hooks or frame polling: update only at AppKit lifecycle events.
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <strings.h>
#include "console_mode.h"

static NSString *game_name;
static NSString *game_icon_path;
static NSImage *game_icon;
static BOOL game_icon_loading;
static BOOL game_icon_load_attempted;
static BOOL helper_process;
static BOOL game_mode_disabled;
static id (*next_bundle_value)(id, SEL, NSString *);
static void (*next_icon)(id, SEL, NSImage *);
static void (*next_menu)(id, SEL, NSMenu *);
static BOOL (*next_policy)(id, SEL, NSApplicationActivationPolicy);

static void load_game_icon_if_ready(void)
{
    if (helper_process || game_icon || game_icon_loading || game_icon_load_attempted ||
        !game_icon_path.length || ![NSThread isMainThread] || !NSApp)
        return;

    game_icon_loading = YES;
    game_icon_load_attempted = YES;
    game_icon = [[NSImage alloc] initWithContentsOfFile:game_icon_path];
    game_icon_loading = NO;
}

static void reapply_game_icon(void)
{
    load_game_icon_if_ready();
    if (!helper_process && game_icon && [NSThread isMainThread] && NSApp)
        next_icon(NSApp, @selector(setApplicationIconImage:), game_icon);
}

static BOOL is_helper(const char *name)
{
    // These are infrastructure, not game-specific launchers with useful UI.
    const char *helpers[] = { "wine", "wine64", "wine-preloader", "wine64-preloader",
        "steam.exe", "wineboot.exe", "services.exe", "winedevice.exe",
        "explorer.exe", "plugplay.exe", "rpcss.exe", "conhost.exe",
        "winemenubuilder.exe", "upc.exe", "UbisoftGameLauncher.exe",
        "UplayWebCore.exe", "UplayService.exe", "UnityCrashHandler64.exe",
        "svchost.exe" };
    for (size_t i = 0; i < sizeof(helpers) / sizeof(helpers[0]); ++i)
        if (!strcasecmp(name, helpers[i])) return YES;
    return NO;
}

static void update_name(void)
{
    if (![NSThread isMainThread] || helper_process || !NSApp) return;
    load_game_icon_if_ready();
    [[NSProcessInfo processInfo] setProcessName:game_name];
    // AppKit has no public setter for the Dock's live process display name.
    // Resolve the optional LaunchServices SPI at runtime and fail gracefully.
    typedef CFTypeRef (*GetASN)(void);
    typedef OSStatus (*SetInfo)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *);
    static GetASN get_asn;
    static SetInfo set_info;
    static CFStringRef display_key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
        if (!bundle) return;
        get_asn = (GetASN)CFBundleGetFunctionPointerForName(bundle, CFSTR("_LSGetCurrentApplicationASN"));
        set_info = (SetInfo)CFBundleGetFunctionPointerForName(bundle, CFSTR("_LSSetApplicationInformationItem"));
        CFStringRef *key = CFBundleGetDataPointerForName(bundle, CFSTR("_kLSDisplayNameKey"));
        display_key = key ? *key : NULL;
        ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        GetCurrentProcess(&psn);
#pragma clang diagnostic pop
    });
    CFTypeRef asn = get_asn ? get_asn() : NULL;
    if (asn && set_info && display_key) {
        OSStatus status = set_info(-2, asn, display_key, (CFStringRef)game_name, NULL);
        if (status) fprintf(stderr, "notproton identity: display name status=%d\n", (int)status);
    }
}

static id bundle_value(id self, SEL cmd, NSString *key)
{
    if (!helper_process && self == [NSBundle mainBundle] &&
        ([key isEqualToString:@"LSSupportsGameMode"] || [key isEqualToString:@"GCSupportsGameMode"]))
        return @(!game_mode_disabled);
    if (!helper_process && self == [NSBundle mainBundle] &&
        ([key isEqualToString:@"CFBundleName"] || [key isEqualToString:@"CFBundleDisplayName"]))
        return game_name;
    return next_bundle_value(self, cmd, key);
}

static void set_icon(id self, SEL cmd, NSImage *image)
{
    NSImage *replacement = image;
    if (!helper_process && [NSThread isMainThread]) {
        load_game_icon_if_ready();
        if (game_icon) replacement = game_icon;
    }
    next_icon(self, cmd, replacement);
}

static void set_menu(id self, SEL cmd, NSMenu *menu)
{
    if (!helper_process && menu.numberOfItems) {
        NSMenuItem *app = [menu itemAtIndex:0];
        app.title = game_name;
        app.submenu.title = game_name;
        // Wine builds these entries from CFBundleName; the bundle hook above
        // supplies the game name before the menu is created.
    }
    next_menu(self, cmd, menu);
    update_name();
    reapply_game_icon();
}

static BOOL set_policy(id self, SEL cmd, NSApplicationActivationPolicy policy)
{
    if (helper_process && policy == NSApplicationActivationPolicyRegular)
        policy = NSApplicationActivationPolicyAccessory;
    BOOL result = next_policy(self, cmd, policy);
    if (!helper_process && result && policy == NSApplicationActivationPolicyRegular) {
        update_name(); // Apply the name after AppKit accepts regular activation.
        reapply_game_icon();
    }
    return result;
}

static BOOL replace(Class cls, SEL selector, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return YES;
}

__attribute__((constructor)) static void load_game_identity(void)
{
    const char *name = getenv("NOTPROTON_GAME_NAME");
    if (!name || !*name) return;
    @autoreleasepool {
        game_name = [[NSString alloc] initWithUTF8String:name];
        if (!game_name.length) return;
        helper_process = is_helper(getprogname());
        const char *mode = getenv("NOTPROTON_GAME_MODE");
        game_mode_disabled = mode && strcmp(mode, "0") == 0;
        np_console_mode_install(helper_process);
        const char *path = getenv("NOTPROTON_GAME_ICON");
        if (!helper_process && path && *path)
            game_icon_path = [[NSString alloc] initWithUTF8String:path];
        replace([NSBundle class], @selector(objectForInfoDictionaryKey:), (IMP)bundle_value, (IMP *)&next_bundle_value);
        replace([NSApplication class], @selector(setApplicationIconImage:), (IMP)set_icon, (IMP *)&next_icon);
        replace([NSApplication class], @selector(setMainMenu:), (IMP)set_menu, (IMP *)&next_menu);
        replace([NSApplication class], @selector(setActivationPolicy:), (IMP)set_policy, (IMP *)&next_policy);
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
            object:nil queue:nil usingBlock:^(NSNotification *notification) {
                (void)notification;
                update_name();
                reapply_game_icon();
            }];
        fprintf(stderr, "notproton identity: pid=%d process=%s name=%s helper=%d icon=%d\n",
            getpid(), getprogname(), name, helper_process, game_icon_path != nil);
    }
}
