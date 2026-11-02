// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Hides the contents of the Photos app's "Hidden" smart album by handing the
// grid an empty PhotoKit fetch result, so it shows Photos' own empty state.
// The settings switch lives in the HiddenAlbumSettings preference bundle and
// is read from the com.simon.hidden-album preferences domain.
//
// Photos runs PhotoKit in multi-library mode, where the single-library fetch
// APIs raise "Calling single library mode API while in multi library mode",
// and calling PhotoKit from inside a PhotoKit fetch was seen to hang the app.
// The empty result is therefore built once, off the fetch path, by an async
// task that tries the ways in turn and keeps the first that answers a count
// of 0. Until one works the hook changes nothing.
//
// The build defines APELIN_PACKAGE_ID, APELIN_VERSION and APELIN_BUILD_ID as
// string literals on every compile.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <notify.h>
#import <os/log.h>
#import <substrate.h>

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#pragma mark - The setting

// The preference domain is the package id, the same string the preference
// bundle's Root.plist stores to and posts the change notification on.
static BOOL gEnabled = YES;
static BOOL gLoaded = NO;

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

static BOOL HiddenContentsEnabled(void) {
    if (!gLoaded) {
        gEnabled = ReadEnabledFromPreferences();
        gLoaded = YES;
        os_log(TweakLog(), "ApelinSetting enabled=%d", gEnabled ? 1 : 0);
    }
    return gEnabled;
}

// The pane posts <package id>/changed; re-read the value on the next fetch.
static void SettingChanged(void) {
    BOOL enabled = ReadEnabledFromPreferences();
    gEnabled = enabled;
    gLoaded = YES;
    os_log(TweakLog(), "ApelinSetting changed enabled=%d", enabled ? 1 : 0);
}

static void StartListeningForSettingChanges(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_dispatch(APELIN_PACKAGE_ID "/changed",
                                 &token,
                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                 ^(int t) {
            (void)t;
            SettingChanged();
        });
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

// The empty result, built off the fetch path: 0 not tried, 1 building,
// 2 ready, -1 no way works.
static PHFetchResult<PHAsset *> *gEmptyResult = nil;
static NSInteger gEmptyState = 0;
static PHAssetCollection *gHiddenCollection = nil;
static PHFetchOptions *gHiddenOptions = nil;

// A predicate no asset satisfies: nothing was created a century from now.
static NSPredicate *NothingMatchesPredicate(void) {
    NSDate *farFuture = [NSDate dateWithTimeIntervalSinceNow:60.0 * 60.0 * 24.0 * 365.0 * 100.0];
    return [NSPredicate predicateWithFormat:@"dateCreated > %@", farFuture];
}

static void FinishBuildingEmptyResult(PHFetchResult<PHAsset *> *result, NSString *how) {
    if (result != nil && result.count == 0) {
        gEmptyResult = result;
        gEmptyState = 2;
        os_log(TweakLog(), "ApelinEmpty ready via %{public}@, count=%lu", how,
               (unsigned long)result.count);
        return;
    }
    os_log(TweakLog(), "ApelinEmpty %{public}@ gave %d item(s)", how,
           result != nil ? 1 : 0);
}

static void BuildEmptyResult(void) {
    PHAssetCollection *collection = gHiddenCollection;
    PHFetchOptions *options = gHiddenOptions;
    os_log(TweakLog(), "ApelinEmpty building, collection=%{public}@ options=%{public}@",
           collection.localizedTitle, NSStringFromClass([options class]));

    // 1. The same library-aware collection fetch Photos itself makes, with a
    //    predicate nothing satisfies.
    if (collection != nil) {
        @try {
            PHFetchOptions *emptyOptions = options != nil ? [options copy] : [[PHFetchOptions alloc] init];
            emptyOptions.predicate = NothingMatchesPredicate();
            emptyOptions.sortDescriptors = nil;
            PHFetchResult<PHAsset *> *result =
                [PHAsset fetchAssetsInAssetCollection:collection options:emptyOptions];
            FinishBuildingEmptyResult(result, @"collection+predicate");
            if (gEmptyState == 2) {
                return;
            }
        } @catch (NSException *exception) {
            os_log_error(TweakLog(), "ApelinEmpty collection+predicate threw: %{public}@",
                         exception.reason);
        }
    }

    // 2. A local identifier that matches nothing, with the fetch's own options.
    @try {
        PHFetchResult<PHAsset *> *result =
            [PHAsset fetchAssetsWithLocalIdentifiers:@[@"apelin-hidden-album-none"]
                                             options:options];
        FinishBuildingEmptyResult(result, @"localIdentifier");
        if (gEmptyState == 2) {
            return;
        }
    } @catch (NSException *exception) {
        os_log_error(TweakLog(), "ApelinEmpty localIdentifier threw: %{public}@", exception.reason);
    }

    // 3. The whole library with the same predicate.
    @try {
        PHFetchOptions *emptyOptions = [[PHFetchOptions alloc] init];
        emptyOptions.predicate = NothingMatchesPredicate();
        PHFetchResult<PHAsset *> *result = [PHAsset fetchAssetsWithOptions:emptyOptions];
        FinishBuildingEmptyResult(result, @"library+predicate");
        if (gEmptyState == 2) {
            return;
        }
    } @catch (NSException *exception) {
        os_log_error(TweakLog(), "ApelinEmpty library+predicate threw: %{public}@", exception.reason);
    }

    gEmptyState = -1;
    os_log_error(TweakLog(), "ApelinEmpty no way works; the album is left as it is");
}

#pragma mark - +[PHAsset fetchAssetsInAssetCollection:options:]

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
    BOOL hidden = IsHiddenSmartAlbum(collection);
    BOOL enabled = HiddenContentsEnabled();
    os_log(TweakLog(),
           "ApelinFetch title=%{public}@ type=%ld subtype=%ld hidden=%d enabled=%d count=%lu state=%ld",
           [collection respondsToSelector:@selector(localizedTitle)] ? collection.localizedTitle : @"(nil)",
           (long)collection.assetCollectionType,
           (long)collection.assetCollectionSubtype,
           hidden ? 1 : 0,
           enabled ? 1 : 0,
           (unsigned long)original.count,
           (long)gEmptyState);
    if (!hidden || !enabled) {
        return original;
    }
    if (gEmptyResult != nil) {
        os_log(TweakLog(), "ApelinFetch hidden album emptied, returning count=%lu",
               (unsigned long)gEmptyResult.count);
        return gEmptyResult;
    }
    if (gEmptyState == 0) {
        // Build it away from this fetch: calling PhotoKit here hung the app.
        gHiddenCollection = collection;
        gHiddenOptions = options;
        gEmptyState = 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BuildEmptyResult();
        });
    }
    return original;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    StartListeningForSettingChanges();

    Class phAsset = objc_getClass("PHAsset");
    if (phAsset == Nil) {
        os_log_error(TweakLog(), "ApelinSetup PHAsset missing");
        return;
    }
    MSHookMessageEx(object_getClass(phAsset),
                    @selector(fetchAssetsInAssetCollection:options:),
                    (IMP)HookedFetchAssetsInAssetCollection,
                    (IMP *)&OriginalFetchAssetsInAssetCollection);
    os_log(TweakLog(), "ApelinSetup hooked +[PHAsset fetchAssetsInAssetCollection:options:]");
}
