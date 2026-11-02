// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Photos, trimmed down: the "Hidden" smart album reads as empty (Photos draws
// its own "无照片或视频"), and the "人物与地点" block of the Albums tab can be
// hidden along with its title. Both are switches in the HiddenAlbumSettings
// preference bundle, stored in the com.simon.hidden-album domain.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>

#pragma mark - The settings

// Read once per launch; re-read only when the pane says a value changed or the
// app comes back to the front. Nothing polls.
static BOOL gHideHiddenAlbum = YES;
static BOOL gHidePeopleAndPlaces = YES;
static BOOL gLoaded = NO;

static BOOL BoolFromPreferences(NSString *key, BOOL fallback) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
    id value = [defaults objectForKey:key];
    if (value != nil && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

static void ReadSettings(void) {
    BOOL album = BoolFromPreferences(@"enabled", YES);
    BOOL peopleAndPlaces = BoolFromPreferences(@"hidePeoplePlaces", YES);
    if (gLoaded && (album != gHideHiddenAlbum || peopleAndPlaces != gHidePeopleAndPlaces)) {
        // A changed value ends this process: the next launch of Photos starts
        // from it, with no data source carrying the old one.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            exit(0);
        });
    }
    gHideHiddenAlbum = album;
    gHidePeopleAndPlaces = peopleAndPlaces;
    gLoaded = YES;
}

static void SettingChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    ReadSettings();
}

#pragma mark - The Hidden album

static BOOL IsHiddenSmartAlbum(PHAssetCollection *collection) {
    return [collection isKindOfClass:[PHAssetCollection class]] &&
           collection.assetCollectionType == PHAssetCollectionTypeSmartAlbum &&
           collection.assetCollectionSubtype == PHAssetCollectionSubtypeSmartAlbumAllHidden;
}

// A data source's verdict is kept on the object itself, so the collection is
// read once and the hot count call stays a lookup. Reading it must not call the
// data source's own methods: -[PXPhotosDataSource containerCollection] asks for
// numberOfSections again, which re-entered this and crashed the app.
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

static long (*OriginalNumberOfSections)(id, SEL);

static long HookedNumberOfSections(id self, SEL _cmd) {
    if (gHideHiddenAlbum && DataSourceIsHiddenAlbum(self)) {
        return 0;  // No sections: Photos draws its own "无照片或视频".
    }
    return OriginalNumberOfSections(self, _cmd);
}

#pragma mark - 人物与地点 in the Albums tab

// The Albums tab is a gadget collection view: PUAlbumsGadgetViewController (a
// PXGadgetUIViewController) lists gadgets one section each, titled "我的相簿",
// "人物与地点", "媒体类型" and so on. The section whose gadget is titled People &
// Places gets no items and no header, so the block and its title are both gone.
@interface PXGadgetUIViewController : UIViewController
- (id)_gadgetAtIndexPath:(NSIndexPath *)indexPath;
@end

static BOOL GadgetIsPeopleAndPlaces(id gadget) {
    NSString *title = nil;
    @try {
        id value = [gadget valueForKey:@"title"];
        if (value == nil) {
            value = [gadget valueForKey:@"localizedTitle"];
        }
        title = [value description];
    } @catch (NSException *exception) {
        return NO;
    }
    if (title.length == 0) {
        return NO;
    }
    BOOL people = [title containsString:@"人物"] ||
                  [title rangeOfString:@"people" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL places = [title containsString:@"地点"] ||
                  [title rangeOfString:@"place" options:NSCaseInsensitiveSearch].location != NSNotFound;
    return people && places;
}

static BOOL SectionIsPeopleAndPlaces(id controller, NSInteger section) {
    id gadget = nil;
    @try {
        gadget = [(PXGadgetUIViewController *)controller
            _gadgetAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:section]];
    } @catch (NSException *exception) {
        (void)exception;
    }
    return gadget != nil && GadgetIsPeopleAndPlaces(gadget);
}

static NSInteger (*OriginalGadgetNumberOfItems)(id, SEL, UICollectionView *, NSInteger);

static NSInteger HookedGadgetNumberOfItems(id self, SEL _cmd, UICollectionView *collectionView,
                                           NSInteger section) {
    if (gHidePeopleAndPlaces && SectionIsPeopleAndPlaces(self, section)) {
        return 0;
    }
    return OriginalGadgetNumberOfItems(self, _cmd, collectionView, section);
}

static CGSize (*OriginalHeaderSize)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSInteger);

static CGSize HookedHeaderSize(id self, SEL _cmd, UICollectionView *collectionView,
                               UICollectionViewLayout *layout, NSInteger section) {
    if (gHidePeopleAndPlaces && SectionIsPeopleAndPlaces(self, section)) {
        return CGSizeMake(0, 0);
    }
    return OriginalHeaderSize(self, _cmd, collectionView, layout, section);
}

#pragma mark - Loading

static void HookSelector(Class cls, SEL selector, IMP hook, IMP *original) {
    if (cls != Nil && class_getInstanceMethod(cls, selector) != NULL) {
        MSHookMessageEx(cls, selector, hook, original);
    }
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded reads this marker; it is the only line logged.
    os_log(os_log_create(APELIN_PACKAGE_ID, "tweak"), "ApelinLoaded %{public}s in %{public}s",
           APELIN_BUILD_ID, getprogname());

    ReadSettings();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SettingChangedCallback,
                                    (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/changed"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        (void)note;
        ReadSettings();
    }];

    HookSelector(objc_getClass("PXPhotosDataSource"), @selector(numberOfSections),
                 (IMP)HookedNumberOfSections, (IMP *)&OriginalNumberOfSections);

    Class gadgetController = objc_getClass("PXGadgetUIViewController");
    HookSelector(gadgetController, @selector(collectionView:numberOfItemsInSection:),
                 (IMP)HookedGadgetNumberOfItems, (IMP *)&OriginalGadgetNumberOfItems);
    HookSelector(gadgetController, @selector(collectionView:layout:referenceSizeForHeaderInSection:),
                 (IMP)HookedHeaderSize, (IMP *)&OriginalHeaderSize);
}
