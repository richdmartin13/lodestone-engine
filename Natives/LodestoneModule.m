// Lodestone: this engine as a module of a Sandbox app (capability `java`).
//
// Built as usual, the engine is an app of its own. Lodestone's package takes that app's binary as a
// library (its Mach-O type changed after the build) inside a Sandbox app, with the engine's
// resources beside the Sandbox app's own, so `NSBundle.mainBundle` still finds them. The Sandbox
// shell loads the library at launch and calls `+[LodestoneJavaModule sandboxRegister:]`; from then
// on the launcher (the Sandbox app, in TypeScript) asks for what it shows through the calls below,
// and `launch` hands the window to the game. Nothing of the engine's own start-up runs before
// `launch`: it changes the process (HOME, stdout, UIKit) in ways the launcher must not see.
//
// Included at the end of main.m (it is part of that file, for its start-up functions).

#import <objc/message.h>
#include <dlfcn.h>
#include "external/fishhook/fishhook.h"
#import "authenticator/BaseAuthenticator.h"
#import "ios_uikit_bridge.h"
#import "MinecraftResourceDownloadTask.h"

typedef void (^LodestoneReply)(BOOL ok, NSString *json);
typedef void (^LodestoneHandler)(NSString *call, NSString *context, NSString *args, LodestoneReply reply);

extern __weak UIWindow *mainWindow;
void launchInitialViewController(UIWindow *window);

static BOOL lodestoneLaunched;
static MinecraftResourceDownloadTask *lodestoneTask;

// libjli starts Java on a thread of its own by calling the program's `main` again, which it looks
// up by name: in a Sandbox app that would be the Sandbox shell's. It is given this one.
static void *(*lodestone_orig_dlsym)(void *handle, const char *symbol);
static void *lodestone_dlsym(void *handle, const char *symbol) {
    if (symbol && strcmp(symbol, "main") == 0 && lodestoneLaunched) {
        return (void *)&main;
    }
    return lodestone_orig_dlsym(handle, symbol);
}

static NSString *lodestoneDocuments(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject.path;
}

static NSString *lodestoneGameRoot(void) {
    return [lodestoneDocuments() stringByAppendingPathComponent:@"instances/default"];
}

static NSString *lodestoneJSON(id value) {
    if (!value) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSMutableDictionary *lodestoneProfilesFile(void) {
    NSData *data = [NSData dataWithContentsOfFile:[lodestoneGameRoot() stringByAppendingPathComponent:@"launcher_profiles.json"]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [parsed isKindOfClass:NSMutableDictionary.class] ? parsed : [NSMutableDictionary new];
}

static NSString *lodestoneGameDir(NSDictionary *profile) {
    NSString *dir = profile[@"gameDir"];
    if (![dir isKindOfClass:NSString.class] || dir.length == 0) return lodestoneGameRoot();
    if ([dir hasPrefix:@"./"]) return [lodestoneGameRoot() stringByAppendingPathComponent:[dir substringFromIndex:2]];
    return dir.isAbsolutePath ? dir : [lodestoneGameRoot() stringByAppendingPathComponent:dir];
}

static NSArray<NSDictionary *> *lodestoneMods(NSString *gameDir) {
    NSMutableArray *mods = [NSMutableArray new];
    NSString *folder = [gameDir stringByAppendingPathComponent:@"mods"];
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *name in names) {
        BOOL on = [name hasSuffix:@".jar"], off = [name hasSuffix:@".jar.disabled"];
        if (!on && !off) continue;
        [mods addObject:@{@"file": name, @"enabled": @(on)}];
    }
    return mods;
}

static NSDictionary *lodestonePreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[lodestoneDocuments() stringByAppendingPathComponent:@"launcher_preferences_v2.plist"]];
    return prefs ?: @{};
}

static NSDictionary *lodestoneInstance(NSString *name, NSDictionary *profile, BOOL full) {
    NSString *gameDir = lodestoneGameDir(profile);
    NSArray *mods = lodestoneMods(gameDir);
    NSDictionary *logAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:[lodestoneDocuments() stringByAppendingPathComponent:@"latestlog.txt"] error:nil];
    NSMutableDictionary *out = [@{
        @"id": name,
        @"name": profile[@"name"] ?: name,
        @"version": profile[@"lastVersionId"] ?: @"",
        @"mods": @(mods.count),
    } mutableCopy];
    NSDate *played = logAttributes.fileModificationDate;
    if (played) out[@"lastPlayed"] = @((long long)(played.timeIntervalSince1970 * 1000));
    if (!full) return out;
    out[@"modList"] = mods;
    NSDictionary *java = lodestonePreferences()[@"java"];
    out[@"settings"] = @{
        @"memoryMB": [java[@"allocated_memory"] isKindOfClass:NSNumber.class] ? java[@"allocated_memory"] : @0,
        @"renderer": profile[@"renderer"] ?: @"",
        @"javaArgs": profile[@"javaArgs"] ?: @"",
    };
    // The newest of the game's own reports and the JVM's.
    NSString *newest = nil; NSDate *newestDate = nil;
    for (NSString *folder in @[[gameDir stringByAppendingPathComponent:@"crash-reports"], gameDir]) {
        for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil]) {
            if (!([file hasPrefix:@"crash-"] || [file hasPrefix:@"hs_err_pid"])) continue;
            NSString *path = [folder stringByAppendingPathComponent:file];
            NSDate *date = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (date && (!newestDate || [date compare:newestDate] == NSOrderedDescending)) { newest = path; newestDate = date; }
        }
    }
    if (newest) {
        NSString *text = [[NSString alloc] initWithData:[NSData dataWithContentsOfFile:newest] ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        if (text.length > 60000) text = [text substringToIndex:60000];
        out[@"lastCrash"] = @{@"file": newest.lastPathComponent, @"when": @((long long)(newestDate.timeIntervalSince1970 * 1000)), @"report": text};
    }
    return out;
}

static NSString *lodestoneTail(NSString *path, NSUInteger bytes) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return @"";
    unsigned long long size = [file seekToEndOfFile];
    [file seekToFileOffset:size > bytes ? size - bytes : 0];
    NSData *data = [file readDataToEndOfFile];
    [file closeFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

static UIWindow *lodestoneWindow(void) {
    UIWindow *first = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!first) first = window;
        }
    }
    return first;
}

static UIViewController *lodestoneFind(UIViewController *from, Class wanted) {
    if (!from || !wanted) return nil;
    if ([from isKindOfClass:wanted]) return from;
    for (UIViewController *child in from.childViewControllers) {
        UIViewController *found = lodestoneFind(child, wanted);
        if (found) return found;
    }
    return lodestoneFind(from.presentedViewController, wanted);
}

// Presses the engine's own Play once its launcher is on screen: it fetches what the version still
// needs, waits for JIT and starts the game, as it does when a person presses it.
static void lodestonePressPlay(UIWindow *window, int triesLeft) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *launcher = lodestoneFind(window.rootViewController, NSClassFromString(@"LauncherNavigationController"));
        id button = nil;
        @try { button = launcher.isViewLoaded ? [launcher valueForKey:@"buttonInstall"] : nil; } @catch (NSException *e) { button = nil; }
        SEL play = NSSelectorFromString(@"launchMinecraft:");
        if (launcher && button && [launcher respondsToSelector:play]) {
            NSLog(@"[Lodestone] starting the game");
            ((void (*)(id, SEL, id))objc_msgSend)(launcher, play, button);
        } else if (triesLeft > 0) {
            lodestonePressPlay(window, triesLeft - 1);
        } else {
            NSLog(@"[Lodestone] the engine's launcher did not appear");
        }
    });
}

static NSString *lodestoneLaunch(NSString *profileName, NSDictionary *profiles) {
    if (lodestoneLaunched) return @"The game was started already.";
    UIWindow *window = lodestoneWindow();
    if (!window) return @"There is no window to show the game in.";
    if (profileName.length && !profiles[profileName]) return [NSString stringWithFormat:@"There is no instance named %@.", profileName];
    lodestoneLaunched = YES;
    rebind_symbols((struct rebinding[1]){{"dlsym", lodestone_dlsym, (void *)&lodestone_orig_dlsym}}, 1);
    // The game's Java side loads this library by its file (it holds the JNI functions): where it is.
    Dl_info engine;
    if (dladdr((void *)&lodestone_dlsym, &engine) && engine.dli_fname) setenv("LODESTONE_ENGINE", engine.dli_fname, 1);
    lodestone_preinit(NSBundle.mainBundle.executablePath.fileSystemRepresentation);
    if (profileName.length) PLProfiles.current.selectedProfileName = profileName;
    mainWindow = window;

    // Straight to the game, the launcher (the Sandbox app) staying on screen meanwhile: what the
    // engine's own Play does, without its screens. That needs an account and a version already on
    // the device; without them the engine's launcher is shown, which can sign in and download.
    NSString *versionId = profiles[PLProfiles.current.selectedProfileName][@"lastVersionId"];
    NSString *versionFile = versionId.length == 0 ? nil : [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR") ?: "", versionId, versionId];
    if (BaseAuthenticator.current == nil || !versionFile || ![NSFileManager.defaultManager fileExistsAtPath:versionFile]) {
        NSLog(@"[Lodestone] no account or no version %@ here: the engine's launcher", versionId);
        launchInitialViewController(window);
        [window makeKeyAndVisible];
        lodestonePressPlay(window, 50);
        return nil;
    }
    lodestoneTask = [MinecraftResourceDownloadTask new];
    __block BOOL failed = NO;
    lodestoneTask.handleError = ^{ failed = YES; };
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[Lodestone] checking the files of %@", versionId);
        [lodestoneTask downloadVersion:@{@"id": versionId, @"type": @"custom"}];
        while (!failed && !(lodestoneTask.metadata && lodestoneTask.progress.fractionCompleted >= 1.0)) usleep(200 * 1000);
        if (failed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[Lodestone] the version's files could not be fetched: the engine's launcher");
                launchInitialViewController(window);
                [window makeKeyAndVisible];
            });
            return;
        }
        while (!isJITEnabled(false)) usleep(200 * 1000);
        NSDictionary *metadata = lodestoneTask.metadata;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[Lodestone] starting the game");
            UIKit_launchMinecraftSurfaceVC(window, metadata);
        });
    });
    return nil;
}

static void lodestoneCall(NSString *call, NSDictionary *args, LodestoneReply reply) {
    NSString *name = [args[@"id"] isKindOfClass:NSString.class] ? args[@"id"] : @"";
    NSMutableDictionary *file = lodestoneProfilesFile();
    NSMutableDictionary *profiles = [file[@"profiles"] isKindOfClass:NSMutableDictionary.class] ? file[@"profiles"] : nil;
    NSMutableDictionary *profile = name.length ? profiles[name] : nil;

    if ([call isEqualToString:@"java.device"]) {
        reply(YES, lodestoneJSON(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"));
    } else if ([call isEqualToString:@"java.jit"]) {
        reply(YES, lodestoneJSON(@{@"enabled": @(isJITEnabled(false)), @"pid": @(getpid()), @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""}));
    } else if ([call isEqualToString:@"java.instances"]) {
        NSMutableArray *list = [NSMutableArray new];
        for (NSString *key in [profiles.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            if ([profiles[key] isKindOfClass:NSDictionary.class]) [list addObject:lodestoneInstance(key, profiles[key], NO)];
        }
        reply(YES, lodestoneJSON(list));
    } else if ([call isEqualToString:@"java.install"]) {
        reply(NO, @"Installing packs isn't in this version of the engine yet.");
    } else if ([call isEqualToString:@"java.logs"]) {
        reply(YES, lodestoneJSON(lodestoneTail([lodestoneDocuments() stringByAppendingPathComponent:@"latestlog.txt"], 120000)));
    } else if (!profile) {
        reply(NO, [NSString stringWithFormat:@"There is no instance named %@.", name]);
    } else if ([call isEqualToString:@"java.instance"]) {
        reply(YES, lodestoneJSON(lodestoneInstance(name, profile, YES)));
    } else if ([call isEqualToString:@"java.setSettings"]) {
        NSDictionary *settings = [args[@"settings"] isKindOfClass:NSDictionary.class] ? args[@"settings"] : @{};
        if ([settings[@"renderer"] isKindOfClass:NSString.class]) profile[@"renderer"] = settings[@"renderer"];
        if ([settings[@"javaArgs"] isKindOfClass:NSString.class]) profile[@"javaArgs"] = settings[@"javaArgs"];
        NSData *data = [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingPrettyPrinted error:nil];
        BOOL saved = [data writeToFile:[lodestoneGameRoot() stringByAppendingPathComponent:@"launcher_profiles.json"] atomically:YES];
        if ([settings[@"memoryMB"] isKindOfClass:NSNumber.class]) {
            NSString *path = [lodestoneDocuments() stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
            NSMutableDictionary *prefs = [lodestonePreferences() mutableCopy];
            NSMutableDictionary *java = [prefs[@"java"] isKindOfClass:NSDictionary.class] ? [prefs[@"java"] mutableCopy] : [NSMutableDictionary new];
            java[@"allocated_memory"] = settings[@"memoryMB"];
            prefs[@"java"] = java;
            saved = [prefs writeToFile:path atomically:YES] && saved;
        }
        if (saved) reply(YES, nil); else reply(NO, @"The settings could not be saved.");
    } else if ([call isEqualToString:@"java.setModEnabled"]) {
        NSString *mod = [args[@"mod"] isKindOfClass:NSString.class] ? args[@"mod"] : @"";
        BOOL on = [args[@"enabled"] boolValue];
        if (mod.length == 0 || [mod containsString:@"/"]) { reply(NO, @"That is not a mod's file."); return; }
        NSString *folder = [lodestoneGameDir(profile) stringByAppendingPathComponent:@"mods"];
        NSString *base = [mod hasSuffix:@".disabled"] ? [mod substringToIndex:mod.length - 9] : mod;
        NSString *from = [folder stringByAppendingPathComponent:on ? [base stringByAppendingString:@".disabled"] : base];
        NSString *to = [folder stringByAppendingPathComponent:on ? base : [base stringByAppendingString:@".disabled"]];
        NSError *error = nil;
        if ([NSFileManager.defaultManager fileExistsAtPath:to] || [NSFileManager.defaultManager moveItemAtPath:from toPath:to error:&error]) {
            reply(YES, nil);
        } else {
            reply(NO, error.localizedDescription ?: @"The mod could not be changed.");
        }
    } else if ([call isEqualToString:@"java.launch"]) {
        NSString *problem = lodestoneLaunch(name, profiles);
        // The game ends with the app: there is no answer after a start that worked.
        if (problem) reply(NO, problem);
    } else {
        reply(NO, @"The engine has no such call.");
    }
}

@interface LodestoneJavaModule : NSObject
@end

@implementation LodestoneJavaModule

// The Sandbox shell's entry (shells/apple/SandboxKit/AppModules.swift): registers with its
// `registerModule:version:capabilities:calls:handler:`; answers why it could not, or nil.
+ (NSString *)sandboxRegister:(id)host {
    SEL selector = NSSelectorFromString(@"registerModule:version:capabilities:calls:handler:");
    if (![host respondsToSelector:selector]) return @"this shell has no module registry";
    NSMutableDictionary *calls = [NSMutableDictionary new];
    for (NSString *name in @[@"device", @"jit", @"instances", @"instance", @"setSettings", @"setModEnabled", @"logs", @"install", @"launch"]) {
        calls[[@"java." stringByAppendingString:name]] = @"java";
    }
    LodestoneHandler handler = ^(NSString *call, NSString *context, NSString *args, LodestoneReply reply) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[(args ?: @"{}") dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *arguments = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                lodestoneCall(call, arguments, reply);
            } @catch (NSException *exception) {
                reply(NO, exception.reason ?: @"The engine failed.");
            }
        });
    };
    return ((NSString *(*)(id, SEL, NSString *, NSString *, NSArray *, NSDictionary *, id))objc_msgSend)(
        host, selector, @"java", @"0.2.0", @[@"java"], calls, handler);
}

@end
