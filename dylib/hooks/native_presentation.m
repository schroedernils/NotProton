#import "native_presentation.h"

#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <errno.h>
#import <limits.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>

extern char **environ;

static NSString *np_real(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
}

static BOOL np_inside(NSString *path, NSString *root) {
    if (!path || !root) return NO;
    if ([path isEqualToString:root]) return YES;
    NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL np_regular_nosymlink(NSString *path, BOOL executable) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) return NO;
    return !executable || (st.st_mode & 0111) != 0;
}

// Strict Valve key/value parser: quoted strings, braces, no escapes/duplicates.
@interface NPManifestScanner : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) NSUInteger tokens;
- (NSDictionary *)parse;
@end

@implementation NPManifestScanner
- (void)space {
    while (self.offset < self.text.length) {
        unichar c = [self.text characterAtIndex:self.offset];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') self.offset++;
        else break;
    }
}
- (NSString *)string {
    [self space];
    if (self.offset >= self.text.length || [self.text characterAtIndex:self.offset] != '"' || ++self.tokens > 200000) return nil;
    NSUInteger start = ++self.offset;
    while (self.offset < self.text.length) {
        unichar c = [self.text characterAtIndex:self.offset];
        if (c == '"') {
            NSString *s = [self.text substringWithRange:NSMakeRange(start, self.offset - start)];
            self.offset++;
            if ([s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound || [s containsString:@"\\"]) return nil;
            return s;
        }
        if (c == '\\' || c == 0) return nil;
        self.offset++;
    }
    return nil;
}
- (NSDictionary *)dictionaryAtDepth:(NSUInteger)depth closing:(BOOL)closing {
    if (depth > 32) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (;;) {
        [self space];
        if (self.offset >= self.text.length) return closing ? nil : result;
        if ([self.text characterAtIndex:self.offset] == '}') {
            if (!closing) return nil;
            self.offset++;
            return result;
        }
        NSString *key = [self string];
        if (!key.length || result[key]) return nil;
        [self space];
        if (self.offset >= self.text.length) return nil;
        if ([self.text characterAtIndex:self.offset] == '{') {
            self.offset++;
            NSDictionary *nested = [self dictionaryAtDepth:depth + 1 closing:YES];
            if (!nested) return nil;
            result[key] = nested;
        } else {
            NSString *value = [self string];
            if (!value) return nil;
            result[key] = value;
        }
    }
}
- (NSDictionary *)parse {
    NSDictionary *d = [self dictionaryAtDepth:0 closing:NO];
    [self space];
    return self.offset == self.text.length ? d : nil;
}
@end

static NSDictionary *np_manifest(NSString *path, uint32_t expected) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 4 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!text) return nil;
    NPManifestScanner *scanner = [NPManifestScanner new]; scanner.text = text;
    NSDictionary *top = [scanner parse];
    if (![top isKindOfClass:NSDictionary.class] || top.count != 1 || ![top[@"AppState"] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *app = top[@"AppState"];
    NSString *appid = app[@"appid"];
    NSString *install = app[@"installdir"];
    if (![appid isKindOfClass:NSString.class] || !appid.length || ![install isKindOfClass:NSString.class] || !install.length ||
        !appid.length || appid.length > 10 || install.length > 255 ||
        [install isEqualToString:@"."] || [install isEqualToString:@".."] ||
        [install containsString:@"/"] || [install containsString:@"\\"]) return nil;
    for (NSUInteger i = 0; i < appid.length; i++) if ([appid characterAtIndex:i] < '0' || [appid characterAtIndex:i] > '9') return nil;
    unsigned long long parsed = strtoull(appid.UTF8String, NULL, 10);
    if (!parsed || parsed > UINT32_MAX || parsed != expected) return nil;
    return app;
}

static BOOL np_uint32(NSString *s, uint32_t *out) {
    if (![s isKindOfClass:NSString.class] || !s.length || s.length > 10) return NO;
    unsigned long long n = 0;
    for (NSUInteger i=0; i<s.length; i++) { unichar c=[s characterAtIndex:i]; if(c<'0'||c>'9') return NO; n=n*10+(c-'0'); if(n>UINT32_MAX) return NO; }
    if (!n) return NO;
    *out=(uint32_t)n; return YES;
}

static NSString *np_primary_steam_root(NSString *home) {
    char executable[PATH_MAX]; uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) == 0) {
        NSString *p = np_real([NSString stringWithUTF8String:executable]);
        for (NSUInteger i=0; p && i<64; i++) {
            NSString *candidate = [p stringByAppendingPathComponent:@"appcache/appinfo.vdf"];
            if (np_regular_nosymlink(candidate, NO)) return p;
            NSString *parent = p.stringByDeletingLastPathComponent;
            if ([parent isEqualToString:p]) break;
            p = parent;
        }
    }
    NSString *fallback = [home stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    NSString *cache = [fallback stringByAppendingPathComponent:@"appcache/appinfo.vdf"];
    return np_regular_nosymlink(cache, NO) ? np_real(fallback) : nil;
}

static BOOL np_target_common_library(NSString *target, NSString **realTargetOut, NSString **commonOut, NSString **libraryOut) {
    NSString *realTarget=np_real(target); if(!realTarget) return NO;
    NSString *common=realTarget;
    while(common.length>1 && ![common.lastPathComponent isEqualToString:@"common"]) common=common.stringByDeletingLastPathComponent;
    if (![common.lastPathComponent isEqualToString:@"common"] || ![common.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"steamapps"]) return NO;
    NSString *library=common.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *realLibrary=np_real(library); if(!realLibrary || ![realLibrary isEqualToString:library]) return NO;
    *realTargetOut=realTarget; *commonOut=common; *libraryOut=library; return YES;
}

static BOOL np_installed_target(NSString *target, NSString *reportedAppID, uint32_t *appid, NSString **steamRoot) {
    NSString *realTarget=nil,*common=nil,*library=nil;
    if(!np_target_common_library(target,&realTarget,&common,&library)) return NO;
    NSString *steamapps=[library stringByAppendingPathComponent:@"steamapps"];
    NSArray<NSString *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:steamapps error:nil]; if(!files) return NO;
    NSMutableArray<NSDictionary *> *matches=[NSMutableArray array];
    for(NSString *file in files) {
        if(![file hasPrefix:@"appmanifest_"] || ![file hasSuffix:@".acf"]) continue;
        if(file.length<=16) continue;
        NSString *digits=[file substringWithRange:NSMakeRange(12,file.length-16)]; uint32_t candidateID;
        if(!np_uint32(digits,&candidateID) || ![file isEqualToString:[NSString stringWithFormat:@"appmanifest_%u.acf",candidateID]]) continue;
        NSDictionary *manifest=np_manifest([steamapps stringByAppendingPathComponent:file],candidateID);
        if(!manifest) continue;
        NSString *install=[manifest[@"installdir"] isKindOfClass:NSString.class] ? manifest[@"installdir"] : @"";
        NSString *installPath=[common stringByAppendingPathComponent:install];
        NSString *realInstall=np_real(installPath);
        if(realInstall && np_inside(realTarget,realInstall)) [matches addObject:@{@"id":@(candidateID),@"path":realInstall}];
    }
    if(matches.count!=1) return NO;
    uint32_t found=[matches[0][@"id"] unsignedIntValue];
    if(reportedAppID) { uint32_t envID; if(!np_uint32(reportedAppID,&envID)||envID!=found) return NO; }
    *appid=found; *steamRoot=np_primary_steam_root(NSHomeDirectory()); return *steamRoot!=nil;
}

static NSString *np_bundle_artwork(NSString *target) {
    NSString *p=np_real(target); if(!p) return nil;
    NSString *cursor=p;
    while(cursor.length>1) {
        if([cursor.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSString *resources=[cursor stringByAppendingPathComponent:@"Contents/Resources"];
            NSDictionary *plist=[NSDictionary dictionaryWithContentsOfFile:[cursor stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *icon=[plist[@"CFBundleIconFile"] isKindOfClass:NSString.class]?plist[@"CFBundleIconFile"]:nil;
            if(!icon || [icon containsString:@"/"] || [icon containsString:@"\\"]) return nil;
            if(![icon.pathExtension.lowercaseString isEqualToString:@"icns"]) icon=[icon stringByAppendingPathExtension:@"icns"];
            NSString *candidate=np_real([resources stringByAppendingPathComponent:icon]);
            if(candidate && np_inside(candidate,np_real(resources)) && np_regular_nosymlink(candidate,NO)) return candidate;
            return nil;
        }
        NSString *parent=cursor.stringByDeletingLastPathComponent; if([parent isEqualToString:cursor]) break; cursor=parent;
    }
    return nil;
}

// Respect hardened runtime and library validation before adding an insert.
BOOL np_native_presentation_signing_policy(uint32_t flags, NSDictionary *entitlements) {
    BOOL runtime=(flags & kSecCodeSignatureRuntime)!=0;
    BOOL libraryValidation=(flags & kSecCodeSignatureLibraryValidation)!=0;
    if(!runtime && !libraryValidation) return YES;
    return [entitlements[@"com.apple.security.cs.allow-dyld-environment-variables"] boolValue] &&
           [entitlements[@"com.apple.security.cs.disable-library-validation"] boolValue];
}

BOOL np_native_presentation_signing_result_policy(OSStatus status, uint32_t flags, NSDictionary *entitlements) {
    if(status==errSecCSUnsigned) return YES;
    if(status!=errSecSuccess) return NO;
    return np_native_presentation_signing_policy(flags,entitlements);
}

static BOOL np_signing_allows_dyld(NSString *target) {
    NSString *codePath=target;
    NSString *cursor=target;
    while(cursor.length>1 && ![cursor.pathExtension.lowercaseString isEqualToString:@"app"]) cursor=cursor.stringByDeletingLastPathComponent;
    if([cursor.pathExtension.lowercaseString isEqualToString:@"app"]) {
        NSDictionary *plist=[NSDictionary dictionaryWithContentsOfFile:[cursor stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *name=[plist[@"CFBundleExecutable"] isKindOfClass:NSString.class]?plist[@"CFBundleExecutable"]:nil;
        if(!name.length || [name containsString:@"/"] || [name containsString:@"\\"]) return NO;
        codePath=[cursor stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:name]];
    }
    NSString *real=np_real(codePath); if(!real) return NO;
    if([cursor.pathExtension.lowercaseString isEqualToString:@"app"]) {
        NSString *realBundle=np_real(cursor);
        if(!np_inside(real,realBundle) || !np_regular_nosymlink(codePath,NO)) return NO;
    }
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,(const UInt8 *)real.fileSystemRepresentation,strlen(real.fileSystemRepresentation),false);
    if(!url) return NO;
    SecStaticCodeRef code=NULL; OSStatus status=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code); CFRelease(url);
    if(status==errSecCSUnsigned) return np_native_presentation_signing_result_policy(status,0,@{});
    if(status!=errSecSuccess || !code) { if(code) CFRelease(code); return NO; }
    CFDictionaryRef info=NULL; status=SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info); CFRelease(code);
    if(status==errSecCSUnsigned) return np_native_presentation_signing_result_policy(status,0,@{});
    if(status!=errSecSuccess || !info) { if(info) CFRelease(info); return NO; }
    CFNumberRef number=CFDictionaryGetValue(info,kSecCodeInfoFlags); int flags=0;
    BOOL valid=number && CFGetTypeID(number)==CFNumberGetTypeID() && CFNumberGetValue(number,kCFNumberIntType,&flags);
    CFDictionaryRef ents=CFDictionaryGetValue(info,kSecCodeInfoEntitlementsDict);
    NSDictionary *entitlements=(ents && CFGetTypeID(ents)==CFDictionaryGetTypeID()) ? (__bridge NSDictionary *)ents : @{};
    BOOL eligible=np_native_presentation_signing_result_policy(valid?errSecSuccess:errSecInternalComponent,(uint32_t)flags,entitlements);
    CFRelease(info); return eligible;
}

static NSString *np_identity_path(void) {
    NSString *support=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/notproton"];
    NSString *p=[support stringByAppendingPathComponent:@"game-identity.dylib"];
    NSString *real=np_real(p);
    return real && np_inside(real,np_real(support)) && np_regular_nosymlink(p,NO) ? real : nil;
}

static NSString *np_self_image(void) {
    Dl_info info;
    if(!dladdr((const void *)np_native_presentation_environment,&info) || !info.dli_fname) return nil;
    return np_real([NSString stringWithUTF8String:info.dli_fname]);
}

static BOOL np_safe_name(NSString *s) {
    if(![s isKindOfClass:NSString.class] || !s.length || s.length>512) return NO;
    return [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}

static NSDictionary *np_run_helper(uint32_t appid, NSString *root, NSString *fallback) {
    NSString *support=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/notproton"];
    NSString *helper=[support stringByAppendingPathComponent:@"game-presentation"];
    NSString *realHelper=np_real(helper);
    if(!realHelper || !np_inside(realHelper,np_real(support)) || !np_regular_nosymlink(helper,YES)) return nil;
    NSTask *task=[NSTask new]; task.launchPath=@"/bin/sh";
    NSMutableArray *args=[NSMutableArray arrayWithObjects:helper,root,[NSString stringWithFormat:@"%u",appid],nil];
    if(fallback.length) [args addObject:fallback]; task.arguments=args;
    NSMutableDictionary *helperEnvironment=[NSProcessInfo.processInfo.environment mutableCopy];
    helperEnvironment[@"HOME"]=NSHomeDirectory();
    // The helper is trusted tooling; it needs no game identity or Steam injection.
    [helperEnvironment removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [helperEnvironment removeObjectForKey:@"NOTPROTON_GAME_NAME"];
    [helperEnvironment removeObjectForKey:@"NOTPROTON_GAME_ICON"];
    helperEnvironment[@"NOTPROTON_NATIVE_PRESENTATION_HELPER"]=@"1";
    task.environment=helperEnvironment;
    NSPipe *pipe=[NSPipe pipe]; task.standardOutput=pipe; task.standardError=[NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
    NSMutableData *output=[NSMutableData data]; dispatch_semaphore_t done=dispatch_semaphore_create(0); __block BOOL tooLarge=NO;
    NSFileHandle *reader=pipe.fileHandleForReading;
    reader.readabilityHandler=^(NSFileHandle *h){ NSData *chunk=h.availableData; if(!chunk.length){h.readabilityHandler=nil;dispatch_semaphore_signal(done);return;} @synchronized(output){ if(output.length+chunk.length>65536){tooLarge=YES;[task terminate];}else [output appendData:chunk]; }};
    NSError *error=nil; if(![task launchAndReturnError:&error]) { reader.readabilityHandler=nil; return nil; }
    dispatch_semaphore_t exited=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ [task waitUntilExit]; dispatch_semaphore_signal(exited); });
    long wait=dispatch_semaphore_wait(exited,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC));
    if(wait!=0) {
        if(task.running) [task terminate];
        if(dispatch_semaphore_wait(exited,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))!=0 && task.running) {
            kill(task.processIdentifier,SIGKILL);
            dispatch_semaphore_wait(exited,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        }
    }
    long drained=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    reader.readabilityHandler=nil;
    [reader closeFile];
    if(wait!=0 || drained!=0 || tooLarge || task.terminationStatus!=0) return nil;
    NSString *text=[[NSString alloc]initWithData:output encoding:NSUTF8StringEncoding];
    if(!text || ![text hasSuffix:@"\n"] || [text containsString:@"\r"]) return nil;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    NSArray<NSString *> *lines=[text componentsSeparatedByString:@"\n"];
    if(lines.count<2 || lines.lastObject.length) return nil;
    for(NSUInteger index=0;index+1<lines.count;index++) {
        NSString *line=lines[index];
        if(!line.length) return nil; NSRange eq=[line rangeOfString:@"="]; if(eq.location==NSNotFound) return nil;
        NSString *key=[line substringToIndex:eq.location],*value=[line substringFromIndex:eq.location+1];
        if((![key isEqualToString:@"name"] && ![key isEqualToString:@"icon"]) || !value.length || values[key] || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
        values[key]=value;
    }
    if(!np_safe_name(values[@"name"])) return nil;
    NSString *icon=values[@"icon"];
    if(icon) {
        NSString *expected=[support stringByAppendingPathComponent:[NSString stringWithFormat:@"launchers/%u/game.icns",appid]];
        NSString *real=np_real(icon),*realExpected=np_real(expected);
        NSString *realSupport=np_real(support);
        if(!real || !realExpected || !np_inside(realExpected,realSupport) || ![real isEqualToString:realExpected] || !np_regular_nosymlink(icon,NO)) return nil;
        values[@"icon"]=real;
    }
    return values;
}

NSDictionary<NSString *,NSString *> *np_native_presentation_environment(NSString *target, NSDictionary<NSString *,NSString *> *environment) {
    if(![environment isKindOfClass:NSDictionary.class] || [environment[@"NOTPROTON_NATIVE_PRESENTATION_HELPER"] isEqual:@"1"]) return nil;
    NSString *realTarget=nil,*common=nil,*library=nil;
    if(!np_target_common_library(target,&realTarget,&common,&library)) return nil;
    uint32_t appid=0; NSString *root=nil;
    if(!np_installed_target(realTarget,environment[@"SteamAppId"],&appid,&root)) return nil;
    if(!np_signing_allows_dyld(realTarget)) return nil;
    NSString *identity=np_identity_path(),*self=np_self_image(); if(!identity || !self) return nil;
    NSDictionary *metadata=np_run_helper(appid,root,np_bundle_artwork(target)); if(!metadata) return nil;
    NSString *old=environment[@"DYLD_INSERT_LIBRARIES"] ?: @"";
    NSMutableArray *kept=[NSMutableArray array];
    if(old.length) for(NSString *entry in [old componentsSeparatedByString:@":"]) {
        if(!entry.length || !entry.isAbsolutePath) return nil;
        NSString *canonical=np_real(entry);
        if(canonical && ([canonical isEqualToString:self] || [canonical isEqualToString:identity])) continue;
        [kept addObject:entry];
    }
    NSMutableDictionary *result=[environment mutableCopy];
    result[@"DYLD_INSERT_LIBRARIES"]=[[@[identity] arrayByAddingObjectsFromArray:kept] componentsJoinedByString:@":"];
    result[@"NOTPROTON_GAME_NAME"]=metadata[@"name"];
    if(metadata[@"icon"]) result[@"NOTPROTON_GAME_ICON"]=metadata[@"icon"];
    else [result removeObjectForKey:@"NOTPROTON_GAME_ICON"];
    return result;
}

char **np_native_presentation_spawn_environment(const char *target, char *const envp[]) {
    @autoreleasepool {
    if(!target) return NULL;
    char *const *source=envp ? envp : environ;
    NSMutableDictionary *dict=[NSMutableDictionary dictionary]; NSMutableArray *keys=[NSMutableArray array];
    for(size_t i=0; source && source[i]; i++) {
        if(i>=32768) return NULL; const char *eq=strchr(source[i],'='); if(!eq || eq==source[i]) return NULL;
        NSString *key=[[NSString alloc]initWithBytes:source[i] length:(NSUInteger)(eq-source[i]) encoding:NSUTF8StringEncoding];
        NSString *value=[[NSString alloc]initWithBytes:eq+1 length:strlen(eq+1) encoding:NSUTF8StringEncoding];
        if(!key || !value || dict[key]) return NULL; dict[key]=value; [keys addObject:key];
    }
    NSString *path=[[NSString alloc]initWithUTF8String:target]; if(!path) return NULL;
    NSDictionary *updated=np_native_presentation_environment(path,dict); if(!updated) return NULL;
    NSArray *changed=@[@"DYLD_INSERT_LIBRARIES",@"NOTPROTON_GAME_NAME",@"NOTPROTON_GAME_ICON"];
    NSMutableArray *entries=[NSMutableArray array];
    for(NSString *key in keys) {
        if([changed containsObject:key]) { NSString *v=updated[key]; if(v) [entries addObject:[NSString stringWithFormat:@"%@=%@",key,v]]; }
        else [entries addObject:[NSString stringWithFormat:@"%@=%@",key,dict[key]]];
    }
    for(NSString *key in changed) if(!dict[key] && updated[key]) [entries addObject:[NSString stringWithFormat:@"%@=%@",key,updated[key]]];
    char **result=calloc(entries.count+1,sizeof(char *)); if(!result) return NULL;
    for(NSUInteger i=0;i<entries.count;i++){ result[i]=strdup([entries[i] UTF8String]); if(!result[i]){np_native_presentation_free_environment(result);return NULL;} }
    return result;
    }
}

void np_native_presentation_free_environment(char **environment) {
    if(!environment) return; for(size_t i=0;environment[i];i++) free(environment[i]); free(environment);
}
