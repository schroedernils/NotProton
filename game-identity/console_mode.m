/* Request fullscreen once for a suitable game window; ignore launcher and dialog windows. */
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include "console_mode.h"

@interface NPConsoleModeController : NSObject <NSMenuItemValidation> {
    BOOL _automaticAttempted;
    NSWindow *_selected; // Retained until willClose; queued evaluations cannot dangle.
    BOOL _transitioning;
    BOOL _evaluating;
    BOOL _scheduled;
}
- (void)start;
- (void)changed:(NSNotification *)notification;
- (void)evaluate;
- (void)scheduleEvaluation;
- (void)toggle:(id)sender;
@end

@implementation NPConsoleModeController

- (BOOL)eligible:(NSWindow *)window
{
    if (!window || !NSApp || NSApp.activationPolicy != NSApplicationActivationPolicyRegular)
        return NO;
    Class wine = NSClassFromString(@"WineWindow");
    NSWindowStyleMask style = window.styleMask;
    NSWindowCollectionBehavior behavior = window.collectionBehavior;
    NSString *description = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(window.class), window.title].lowercaseString;
    BOOL overlay = NO;
    // Conservative exclusions: launchers/splash screens and utility UI can be
    // large and key, so size alone is insufficient evidence of a game window.
    for (NSString *word in @[@"overlay", @"dialog", @"splash", @"launcher", @"crash", @"messagebox", @"settings", @"preferences"]) {
        if ([description containsString:word]) { overlay = YES; break; }
    }
    // Conservative AppKit indicators only. CGDisplayIsCaptured is deprecated
    // and unsupported, so this cannot reliably detect Wine exclusive mode.
    // Do not alter presentation options or call private Wine state APIs.
    NSApplicationPresentationOptions exclusive = NSApplicationPresentationHideDock |
        NSApplicationPresentationHideMenuBar | NSApplicationPresentationDisableProcessSwitching;
    BOOL captured = !(style & NSWindowStyleMaskFullScreen) &&
        (NSApp.presentationOptions & exclusive) != 0;
    NSSize size = window.contentView.bounds.size;
    NSWindowStyleMask unsafe = NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskDocModalWindow |
        NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskHUDWindow;
    NSWindowCollectionBehavior auxiliary = NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorFullScreenNone | NSWindowCollectionBehaviorTransient;
    return wine && [window isKindOfClass:wine] &&
        (window == NSApp.mainWindow || window == NSApp.keyWindow) && window.canBecomeMainWindow &&
        window.visible && !window.miniaturized && ![window isKindOfClass:[NSPanel class]] &&
        !window.parentWindow && !window.sheetParent && !window.attachedSheet && !NSApp.modalWindow &&
        !overlay && window.level == NSNormalWindowLevel && !window.ignoresMouseEvents &&
        !(style & unsafe) && !(behavior & auxiliary) && !captured &&
        isfinite(size.width) && isfinite(size.height) && size.width >= 640 && size.height >= 360 &&
        isfinite(window.alphaValue) && window.alphaValue >= 0.99;
}

- (NSWindow *)candidate
{
    // Do not enumerate unrelated windows or promote one to become main/key.
    if ([self eligible:NSApp.mainWindow]) return NSApp.mainWindow;
    if ([self eligible:NSApp.keyWindow]) return NSApp.keyWindow;
    return nil;
}

- (void)updateMenu
{
    NSMenu *appMenu = NSApp.mainMenu.numberOfItems ? [NSApp.mainMenu itemAtIndex:0].submenu : nil;
    if (!appMenu || !_selected) return;
    // Respect an existing native fullscreen menu action anywhere in the menu.
    NSMutableArray<NSMenu *> *menus = [NSMutableArray arrayWithObject:NSApp.mainMenu];
    while (menus.count) {
        NSMenu *menu = [menus lastObject];
        [menus removeLastObject];
        for (NSMenuItem *item in menu.itemArray) {
            if (item.action == @selector(toggleFullScreen:)) return;
            if (item.submenu) [menus addObject:item.submenu];
        }
    }
    NSMenuItem *ours = nil;
    for (NSMenuItem *item in appMenu.itemArray) {
        if (item.target == self && item.action == @selector(toggle:)) { ours = item; break; }
    }
    if (!ours) {
        // Empty shortcut avoids stealing a game key combination.
        ours = [appMenu addItemWithTitle:@"Enter macOS Full Screen (Experimental)" action:@selector(toggle:) keyEquivalent:@""];
        ours.target = self;
    }
    ours.title = (_selected.styleMask & NSWindowStyleMaskFullScreen)
        ? @"Exit macOS Full Screen (Experimental)" : @"Enter macOS Full Screen (Experimental)";
}

- (void)prepareAndToggle:(NSWindow *)window
{
    // Only add affordances to an ordinary titled window, or to a truly
    // borderless Wine main window. Leave unusual combinations untouched.
    @try {
        NSWindowStyleMask style = window.styleMask;
        if (!(style & NSWindowStyleMaskFullScreen)) {
            if (!(style & NSWindowStyleMaskTitled) && style != NSWindowStyleMaskBorderless) return;
            window.styleMask = style | NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
            window.collectionBehavior = window.collectionBehavior | NSWindowCollectionBehaviorFullScreenPrimary;
        }
        _transitioning = YES;
        [window toggleFullScreen:nil]; // Preserve WineWindow's implementation.
    } @catch (NSException *exception) {
        _transitioning = NO;
        fprintf(stderr, "notproton console mode: fullscreen request rejected (%s); no automatic retry\n", exception.name.UTF8String);
    }
}

- (void)evaluate
{
    if (_evaluating || _transitioning || !NSApp.active) return;
    _evaluating = YES;
    @try {
        NSWindow *window = _selected ?: [self candidate];
        if ([self eligible:window]) {
            if (!_selected) _selected = [window retain];
            [self updateMenu];
            if (!_automaticAttempted) {
                _automaticAttempted = YES;
                if (!(window.styleMask & NSWindowStyleMaskFullScreen)) [self prepareAndToggle:window];
            }
        }
    } @catch (NSException *exception) {
        _automaticAttempted = YES;
        fprintf(stderr, "notproton console mode: unsupported window (%s); no automatic retry\n", exception.name.UTF8String);
    } @finally { _evaluating = NO; }
}

- (void)scheduleEvaluation
{
    if (_scheduled) return;
    _scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_scheduled = NO;
        [self evaluate];
    });
}

- (void)changed:(NSNotification *)notification
{
    if (![NSThread isMainThread]) {
        // AppKit normally posts on main; never retain a potentially closing
        // window by forwarding its notification to a later main-queue block.
        return;
    }
    NSWindow *window = [notification.object isKindOfClass:[NSWindow class]] ? notification.object : nil;
    if ([notification.name isEqualToString:NSWindowWillCloseNotification]) {
        if (window == _selected) { [_selected release]; _selected = nil; _transitioning = NO; }
        return;
    }
    if (window == _selected) {
        if ([notification.name isEqualToString:NSWindowWillEnterFullScreenNotification] ||
            [notification.name isEqualToString:NSWindowWillExitFullScreenNotification]) _transitioning = YES;
        if ([notification.name isEqualToString:NSWindowDidEnterFullScreenNotification] ||
            [notification.name isEqualToString:NSWindowDidExitFullScreenNotification]) _transitioning = NO;
        [self updateMenu];
    }
    [self scheduleEvaluation];
}

- (void)toggle:(id)sender
{
    (void)sender;
    // A failed/no-op transition stays latched; explicit menu use can try again
    // only when AppKit did report completion. Never bypass Wine's delegate.
    if (!_transitioning && [self eligible:_selected]) {
        _automaticAttempted = YES;
        [self prepareAndToggle:_selected];
        [self updateMenu];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action != @selector(toggle:)) return NO;
    [self updateMenu];
    return !_transitioning && [self eligible:_selected];
}

- (void)start
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[
        NSApplicationDidFinishLaunchingNotification, NSApplicationDidBecomeActiveNotification,
        NSWindowDidBecomeMainNotification, NSWindowDidBecomeKeyNotification,
        NSWindowDidResizeNotification, NSWindowDidDeminiaturizeNotification,
        NSWindowWillCloseNotification, NSWindowWillEnterFullScreenNotification,
        NSWindowWillExitFullScreenNotification, NSWindowDidEnterFullScreenNotification,
        NSWindowDidExitFullScreenNotification]) {
        [center addObserver:self selector:@selector(changed:) name:name object:nil];
    }
    fprintf(stderr, "notproton console mode: experimental native fullscreen enabled; exclusive fullscreen may require in-game windowed/borderless mode\n");
    [self scheduleEvaluation];
}
@end

static NPConsoleModeController *console_controller;

void np_console_mode_install(bool helper_process)
{
    const char *enabled = getenv("NOTPROTON_CONSOLE_MODE");
    if (helper_process || !enabled || strcmp(enabled, "1") != 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                // Intentionally process-lifetime retained; no shared app files,
                // swizzles, accessibility permission, polling, or global settings.
                console_controller = [[NPConsoleModeController alloc] init];
                [console_controller start];
            }
        });
    });
}
