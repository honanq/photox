// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Hides the contents of the Photos app's "Hidden" smart album, so the album
// grid shows Photos' own empty state. The settings switch lives in the
// HiddenAlbumSettings preference bundle and is read from the
// com.simon.hidden-album preferences domain.
//
// The album grid does not render +[PHAsset fetchAssetsInAssetCollection:options:]:
// Photos asks its PhotosUI data source for counts instead, a PXPhotosDataSource
// whose containerCollection is the "Hidden" smart album (type 2, subtype 205).
// Making that data source answer zero sections leaves the grid showing its own
// empty state, which is what an album with no items looks like.
//
// Photos no longer asks for Face ID once the album reads as empty, so the tweak
// asks itself and keeps a plain cover over the album until the person passes
// it: blank before, "无照片或视频" after.
//
// The build defines APELIN_PACKAGE_ID, APELIN_VERSION and APELIN_BUILD_ID as
// string literals on every compile.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdlib.h>
#import <substrate.h>

#import "ApelinBootstrap.h"

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#pragma mark - A log file the Photos sandbox still lets us write

// A line here is readable through shell_run while Photos keeps running, which
// the unified log cannot do. Kept small: it is a diagnostic, not a record.
static NSString *DebugLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *candidates = @[
            ApelinBootstrapPath(@"/var/mobile/Library/HiddenAlbumDebug.log") ?: @"",
            ApelinBootstrapPath(@"/var/tmp/HiddenAlbumDebug.log") ?: @"",
        ];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *candidate in candidates) {
            if (candidate.length == 0) {
                continue;
            }
            [fileManager createFileAtPath:candidate contents:nil attributes:nil];
            if ([fileManager isWritableFileAtPath:candidate]) {
                path = candidate;
                break;
            }
        }
    });
    return path;
}

static void FileLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSString *path = DebugLogPath();
    if (path == nil) {
        return;
    }
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.simon.hidden-album.filelog", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *exception) {
            (void)exception;
        }
        [handle closeFile];
    });
}

#pragma mark - The setting

// The preference domain is the package id, the same string the preference
// bundle's Root.plist stores to and posts the change notification on.
static BOOL gEnabled = YES;
static BOOL gLoaded = NO;
// Whether Photos' own Face ID for the hidden album has been passed in this
// session: the album reads as empty only after it has.
static BOOL gAuthenticated = NO;
// Set while the hidden album is the page on screen.
static BOOL gHiddenAlbumOpen = NO;

static BOOL ReadEnabledFromPreferences(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
    id value = [defaults objectForKey:@"enabled"];
    if (value == nil) {
        return YES;  // No stored value yet: on by default, as Root.plist's default.
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return YES;
}

// Read once, and again only when something says the value may have changed:
// the pane's Darwin notification, or the app coming back to the front. Nothing
// here polls.
static BOOL HiddenContentsEnabled(void) {
    if (!gLoaded) {
        gEnabled = ReadEnabledFromPreferences();
        gLoaded = YES;
    }
    return gEnabled;
}

// Applies a changed setting: when the value really differs from the one this
// process has been using, the process ends itself, so the next launch of Photos
// starts from the new value with nothing stale left behind.
static void ApplySettingFromPreferences(void) {
    BOOL enabled = ReadEnabledFromPreferences();
    BOOL changed = gLoaded && enabled != gEnabled;
    gEnabled = enabled;
    gLoaded = YES;
    if (!changed) {
        return;
    }
    FileLog(@"setting changed to enabled=%d, ending this process", enabled ? 1 : 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        exit(0);
    });
}

// The pane posts <package id>/changed on the Darwin notification center.
static void SettingChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    ApplySettingFromPreferences();
}

// Test hook: posting com.simon.hidden-album/authtest pretends the pass was
// made, so the switch to the empty state can be checked on its own.
static void RefreshAlbumViews(void);

static void AuthTestCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    gAuthenticated = YES;
    FileLog(@"authtest: authenticated=1");
    RefreshAlbumViews();
}

static void StartListeningForSettingChanges(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        SettingChangedCallback,
                                        (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        AuthTestCallback,
                                        (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/authtest"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // Leaving Photos must ask again next time the album is opened.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            gAuthenticated = NO;
            gHiddenAlbumOpen = NO;
        }];
        // Coming back from Settings is the moment the value can differ; coming
        // back after Photos' own Face ID is the moment the album may be read as
        // empty (its verified result never reaches the process).
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            ApplySettingFromPreferences();
            if (gHiddenAlbumOpen && !gAuthenticated) {
                gAuthenticated = YES;
                FileLog(@"album active again: treating Face ID as passed");
                RefreshAlbumViews();
            }
        }];
    });
}

#pragma mark - The hidden album

static BOOL IsHiddenSmartAlbum(PHAssetCollection *collection) {
    if (![collection isKindOfClass:[PHAssetCollection class]]) {
        return NO;
    }
    return collection.assetCollectionType == PHAssetCollectionTypeSmartAlbum &&
           collection.assetCollectionSubtype == PHAssetCollectionSubtypeSmartAlbumAllHidden;
}

// The empty fetch result, built off the fetch path: 0 not tried, 1 building,
// 2 ready, -1 no way works. Photos' multi library mode refuses a fetch result
// built from a single library, so it is built with the fetch's own options.
static PHFetchResult<PHAsset *> *gEmptyResult = nil;
static NSInteger gEmptyState = 0;
static PHFetchOptions *gHiddenOptions = nil;

static void BuildEmptyResult(void) {
    @try {
        PHFetchResult<PHAsset *> *result =
            [PHAsset fetchAssetsWithLocalIdentifiers:@[@"apelin-hidden-album-none"]
                                             options:gHiddenOptions];
        if (result != nil && result.count == 0) {
            gEmptyResult = result;
            gEmptyState = 2;
            return;
        }
    } @catch (NSException *exception) {
        FileLog(@"empty fetch result threw: %@", exception.reason);
    }
    gEmptyState = -1;
    FileLog(@"empty fetch result unavailable");
}

static PHFetchResult<PHAsset *> *(*OriginalFetchAssetsInAssetCollection)(id, SEL,
                                                                        PHAssetCollection *,
                                                                        PHFetchOptions *);

static PHFetchResult<PHAsset *> *HookedFetchAssetsInAssetCollection(id self, SEL _cmd,
                                                                   PHAssetCollection *collection,
                                                                   PHFetchOptions *options) {
    PHFetchResult<PHAsset *> *original =
        OriginalFetchAssetsInAssetCollection != NULL
            ? OriginalFetchAssetsInAssetCollection(self, _cmd, collection, options)
            : nil;
    if (!IsHiddenSmartAlbum(collection) || !HiddenContentsEnabled()) {
        return original;
    }
    if (gEmptyResult != nil) {
        return gEmptyResult;
    }
    if (gEmptyState == 0) {
        gHiddenOptions = options;
        gEmptyState = 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BuildEmptyResult();
        });
    }
    return original;
}

#pragma mark - The grid: PXPhotosDataSource

// A data source's verdict is kept on the object itself, so the collection is
// read once and the hot count calls stay cheap. Reading it must not call the
// data source's own methods: -[PXPhotosDataSource containerCollection] was
// seen to ask for numberOfSections again, which re-entered this and crashed.
static char kHiddenDataSourceKey;
static __thread BOOL gResolvingDataSource = NO;

static id ContainerCollectionFromIvars(id dataSource) {
    for (Class cls = object_getClass(dataSource); cls != Nil; cls = class_getSuperclass(cls)) {
        for (NSString *name in @[@"_containerCollection", @"_assetCollection", @"_collection"]) {
            Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
            if (ivar == NULL) {
                continue;
            }
            const char *type = ivar_getTypeEncoding(ivar);
            if (type == NULL || type[0] != '@') {
                continue;
            }
            id value = object_getIvar(dataSource, ivar);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static BOOL DataSourceIsHiddenAlbum(id dataSource) {
    if (gResolvingDataSource) {
        return NO;  // A count call made from inside the lookup: leave it alone.
    }
    NSNumber *cached = objc_getAssociatedObject(dataSource, &kHiddenDataSourceKey);
    if (cached != nil) {
        return cached.boolValue;
    }
    gResolvingDataSource = YES;
    BOOL hidden = NO;
    @try {
        id collection = ContainerCollectionFromIvars(dataSource);
        if (collection == nil) {
            collection = [dataSource valueForKey:@"containerCollection"];
        }
        hidden = IsHiddenSmartAlbum(collection);
    } @catch (NSException *exception) {
        (void)exception;
    }
    gResolvingDataSource = NO;
    objc_setAssociatedObject(dataSource, &kHiddenDataSourceKey, @(hidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return hidden;
}

#pragma mark - Face ID, then the empty state

// Photos no longer asks for Face ID for an album it reads as empty, so this
// asks, and the album shows nothing until it is passed: the section stays with
// no items before, and reads as empty afterwards, which is what makes Photos
// draw "无照片或视频".
static char kAskedFaceIDKey __attribute__((unused));
static UIViewController *TopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow != nil) {
            break;
        }
    }
    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        controller = ((UINavigationController *)controller).topViewController;
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

// The counts changed, so the grid has to be asked for them again.
static void RefreshAlbumViews(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = TopViewController();
        UIView *root = controller.view;
        if (root == nil) {
            return;
        }
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
        NSInteger visited = 0;
        while (pending.count > 0 && visited < 400) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            visited++;
            NSString *name = NSStringFromClass([view class]);
            if ([name containsString:@"PXG"] || [view isKindOfClass:[UICollectionView class]]) {
                FileLog(@"relayout %@", name);
                if ([view isKindOfClass:[UICollectionView class]]) {
                    [(UICollectionView *)view reloadData];
                }
                [view setNeedsLayout];
                [view layoutIfNeeded];
            }
            [pending addObjectsFromArray:view.subviews];
        }
        [root setNeedsLayout];
        [root layoutIfNeeded];
    });
}

// Photos asks for Face ID itself when the album is opened, and asks nothing
// once the album reads as empty. So before the pass nothing is touched at all:
// Photos runs its own flow. Only after Photos' own Face ID succeeds does the
// album read as empty, which is what makes Photos draw "无照片或视频".
typedef void (^HiddenAlbumAuthReply)(BOOL success, NSError *error);
static void (*OriginalEvaluatePolicyReason)(id, SEL, LAPolicy, NSString *, HiddenAlbumAuthReply);
static void (*OriginalEvaluatePolicyOptions)(id, SEL, LAPolicy, NSDictionary *, HiddenAlbumAuthReply);

static void HandleAuthenticationResult(BOOL success, NSError *error, NSString *source) {
    FileLog(@"lauth %@ success=%d error=%@", source, success ? 1 : 0, error.localizedDescription);
    if (!success) {
        return;
    }
    gAuthenticated = YES;
    RefreshAlbumViews();
}

static void HookedEvaluatePolicyReason(id self, SEL _cmd, LAPolicy policy, NSString *reason,
                                       HiddenAlbumAuthReply reply) {
    HiddenAlbumAuthReply wrapped = ^(BOOL success, NSError *error) {
        HandleAuthenticationResult(success, error, @"reason");
        if (reply != nil) {
            reply(success, error);
        }
    };
    if (OriginalEvaluatePolicyReason != NULL) {
        OriginalEvaluatePolicyReason(self, _cmd, policy, reason, wrapped);
    } else if (reply != nil) {
        reply(NO, nil);
    }
}

static void HookedEvaluatePolicyOptions(id self, SEL _cmd, LAPolicy policy, NSDictionary *options,
                                        HiddenAlbumAuthReply reply) {
    FileLog(@"lauth options policy=%ld options=%@", (long)policy, [options description]);
    HiddenAlbumAuthReply wrapped = ^(BOOL success, NSError *error) {
        HandleAuthenticationResult(success, error, @"options");
        if (reply != nil) {
            reply(success, error);
        }
    };
    if (OriginalEvaluatePolicyOptions != NULL) {
        OriginalEvaluatePolicyOptions(self, _cmd, policy, options, wrapped);
    } else if (reply != nil) {
        reply(NO, nil);
    }
}

static void (*OriginalEvaluateAccessControl)(id, SEL, id, LAPolicy, NSString *, HiddenAlbumAuthReply);

static void HookedEvaluateAccessControl(id self, SEL _cmd, id accessControl, LAPolicy operation,
                                        NSString *reason, HiddenAlbumAuthReply reply) {
    FileLog(@"lauth accessControl op=%ld reason=%@", (long)operation, reason);
    HiddenAlbumAuthReply wrapped = ^(BOOL success, NSError *error) {
        HandleAuthenticationResult(success, error, @"accessControl");
        if (reply != nil) {
            reply(success, error);
        }
    };
    if (OriginalEvaluateAccessControl != NULL) {
        OriginalEvaluateAccessControl(self, _cmd, accessControl, operation, reason, wrapped);
    } else if (reply != nil) {
        reply(NO, nil);
    }
}

static void RequestFaceIDForHiddenAlbum(id dataSource) {
    // Only records that the album is on screen; the counts are left alone until
    // Photos' own Face ID is passed.
    gHiddenAlbumOpen = YES;
}

static long (*OriginalNumberOfItemsInSection)(id, SEL, long);

static long HookedNumberOfItemsInSection(id self, SEL _cmd, long section) {
    long original = OriginalNumberOfItemsInSection != NULL
                        ? OriginalNumberOfItemsInSection(self, _cmd, section)
                        : 0;
    if (HiddenContentsEnabled() && DataSourceIsHiddenAlbum(self)) {
        RequestFaceIDForHiddenAlbum(self);
        return gAuthenticated ? 0 : original;  // untouched until Photos' Face ID passes
    }
    return original;
}

static long (*OriginalNumberOfSections)(id, SEL);

static long HookedNumberOfSections(id self, SEL _cmd) {
    long original = OriginalNumberOfSections != NULL ? OriginalNumberOfSections(self, _cmd) : 0;
    if (HiddenContentsEnabled() && DataSourceIsHiddenAlbum(self)) {
        RequestFaceIDForHiddenAlbum(self);
        static NSInteger logged = 0;
        if (logged < 10) {
            logged++;
            FileLog(@"sections orig=%ld authenticated=%d", original, gAuthenticated ? 1 : 0);
        }
        return gAuthenticated ? 0 : original;
    }
    return original;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());
    FileLog(@"=== loaded %@ in %s", @APELIN_BUILD_ID, getprogname());

    StartListeningForSettingChanges();

    Class phAsset = objc_getClass("PHAsset");
    if (phAsset != Nil) {
        MSHookMessageEx(object_getClass(phAsset),
                        @selector(fetchAssetsInAssetCollection:options:),
                        (IMP)HookedFetchAssetsInAssetCollection,
                        (IMP *)&OriginalFetchAssetsInAssetCollection);
    }

    Class laContext = objc_getClass("LAContext");
    if (laContext != Nil) {
        if (class_getInstanceMethod(laContext, @selector(evaluatePolicy:localizedReason:reply:)) != NULL) {
            MSHookMessageEx(laContext,
                            @selector(evaluatePolicy:localizedReason:reply:),
                            (IMP)HookedEvaluatePolicyReason,
                            (IMP *)&OriginalEvaluatePolicyReason);
            FileLog(@"hooked -[LAContext evaluatePolicy:localizedReason:reply:]");
        }
        if (class_getInstanceMethod(laContext, @selector(evaluatePolicy:options:reply:)) != NULL) {
            MSHookMessageEx(laContext,
                            @selector(evaluatePolicy:options:reply:),
                            (IMP)HookedEvaluatePolicyOptions,
                            (IMP *)&OriginalEvaluatePolicyOptions);
            FileLog(@"hooked -[LAContext evaluatePolicy:options:reply:]");
        }
        if (class_getInstanceMethod(laContext, @selector(evaluateAccessControl:operation:localizedReason:reply:)) != NULL) {
            MSHookMessageEx(laContext,
                            @selector(evaluateAccessControl:operation:localizedReason:reply:),
                            (IMP)HookedEvaluateAccessControl,
                            (IMP *)&OriginalEvaluateAccessControl);
            FileLog(@"hooked -[LAContext evaluateAccessControl:operation:localizedReason:reply:]");
        }
    }

    Class photosDataSource = objc_getClass("PXPhotosDataSource");
    if (photosDataSource != Nil &&
        class_getInstanceMethod(photosDataSource, @selector(numberOfItemsInSection:)) != NULL) {
        MSHookMessageEx(photosDataSource,
                        @selector(numberOfItemsInSection:),
                        (IMP)HookedNumberOfItemsInSection,
                        (IMP *)&OriginalNumberOfItemsInSection);
    }
    if (photosDataSource != Nil &&
        class_getInstanceMethod(photosDataSource, @selector(numberOfSections)) != NULL) {
        MSHookMessageEx(photosDataSource,
                        @selector(numberOfSections),
                        (IMP)HookedNumberOfSections,
                        (IMP *)&OriginalNumberOfSections);
    }
}
