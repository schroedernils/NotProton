// Prepare Steam game names and artwork for native launches.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include "native_presentation.h"
#include "../util/log.h"

typedef NSRunningApplication *(*launch_fn)(id, SEL, NSURL *, NSWorkspaceLaunchOptions,
    NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *, NSError **);
typedef void (*open_fn)(id, SEL, NSURL *, NSWorkspaceOpenConfiguration *,
    void (^)(NSRunningApplication *, NSError *));
typedef NSRunningApplication *(*open_urls_fn)(id, SEL, NSArray<NSURL *> *, NSURL *,
    NSWorkspaceLaunchOptions, NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *, NSError **);
typedef void (*open_many_fn)(id, SEL, NSArray<NSURL *> *, NSURL *,
    NSWorkspaceOpenConfiguration *, void (^)(NSRunningApplication *, NSError *));

static launch_fn original_launch;
static open_fn original_open_app, original_open_url;
static open_urls_fn original_open_urls;
static open_many_fn original_open_many;

static NSDictionary *prepared_environment(NSURL *url, NSDictionary *environment) {
    if (!url.isFileURL) return nil;
    return np_native_presentation_environment(url.path, environment);
}

static NSDictionary *legacy_configuration(NSDictionary *configuration, NSURL *url) {
    NSDictionary *base = configuration[NSWorkspaceLaunchConfigurationEnvironment];
    if (!base) base = NSProcessInfo.processInfo.environment;
    NSDictionary *prepared = prepared_environment(url, base);
    if (!prepared) return configuration;
    NSMutableDictionary *copy = configuration ? [configuration mutableCopy] : [NSMutableDictionary dictionary];
    copy[NSWorkspaceLaunchConfigurationEnvironment] = prepared;
    return copy;
}

static NSWorkspaceOpenConfiguration *open_configuration(NSWorkspaceOpenConfiguration *configuration,
    NSURL *url) {
    NSDictionary *base = configuration.environment ?: NSProcessInfo.processInfo.environment;
    NSDictionary *prepared = prepared_environment(url, base);
    if (!prepared) return configuration;
    NSWorkspaceOpenConfiguration *copy = configuration ? [configuration copy] : [NSWorkspaceOpenConfiguration configuration];
    copy.environment = prepared;
    return copy;
}

static NSRunningApplication *np_launch(id self, SEL cmd, NSURL *url,
    NSWorkspaceLaunchOptions options,
    NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *configuration, NSError **error) {
    NSDictionary *next = legacy_configuration(configuration, url);
    return original_launch(self, cmd, url, options, next, error);
}

static void np_open_app(id self, SEL cmd, NSURL *url,
    NSWorkspaceOpenConfiguration *configuration,
    void (^completion)(NSRunningApplication *, NSError *)) {
    NSWorkspaceOpenConfiguration *next = open_configuration(configuration, url);
    original_open_app(self, cmd, url, next, completion);
}

static void np_open_url(id self, SEL cmd, NSURL *url,
    NSWorkspaceOpenConfiguration *configuration,
    void (^completion)(NSRunningApplication *, NSError *)) {
    NSWorkspaceOpenConfiguration *next = open_configuration(configuration, url);
    original_open_url(self, cmd, url, next, completion);
}

static NSRunningApplication *np_open_urls(id self, SEL cmd, NSArray<NSURL *> *urls,
    NSURL *appURL, NSWorkspaceLaunchOptions options,
    NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *configuration, NSError **error) {
    NSDictionary *next = legacy_configuration(configuration, appURL);
    return original_open_urls(self, cmd, urls, appURL, options, next, error);
}

static void np_open_many(id self, SEL cmd, NSArray<NSURL *> *urls, NSURL *appURL,
    NSWorkspaceOpenConfiguration *configuration,
    void (^completion)(NSRunningApplication *, NSError *)) {
    NSWorkspaceOpenConfiguration *next = open_configuration(configuration, appURL);
    original_open_many(self, cmd, urls, appURL, next, completion);
}

static BOOL replace_workspace(SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod([NSWorkspace class], selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

void np_hooks_native_install(void) {
    const char *disabled = getenv("NOTPROTON_DISABLE_NATIVE_PRESENTATION");
    if (disabled && strcmp(disabled, "1") == 0) return;
    replace_workspace(@selector(launchApplicationAtURL:options:configuration:error:),
        (IMP)np_launch, (IMP *)&original_launch);
    replace_workspace(@selector(openApplicationAtURL:configuration:completionHandler:),
        (IMP)np_open_app, (IMP *)&original_open_app);
    replace_workspace(@selector(openURL:configuration:completionHandler:),
        (IMP)np_open_url, (IMP *)&original_open_url);
    replace_workspace(@selector(openURLs:withApplicationAtURL:options:configuration:error:),
        (IMP)np_open_urls, (IMP *)&original_open_urls);
    replace_workspace(@selector(openURLs:withApplicationAtURL:configuration:completionHandler:),
        (IMP)np_open_many, (IMP *)&original_open_many);
}
