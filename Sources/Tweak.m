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

#import "ApelinBootstrap.h"

#pragma mark - The settings

// Read once per launch; re-read only when the pane says a value changed or the
// app comes back to the front. Nothing polls.
static BOOL gHideHiddenAlbum = YES;
static BOOL gHidePeopleAndPlaces = YES;
static BOOL gLoaded = NO;
static NSDictionary<NSString *, NSNumber *> *gHiddenAlbumFlags = nil;

static NSUserDefaults *Preferences(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
}

static BOOL BoolFromPreferences(NSString *key, BOOL fallback) {
    id value = [Preferences() objectForKey:key];
    if (value != nil && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

// True when the pane has this album's own switch on. The pane stores one key
// per album, "hide.<localIdentifier>".
static BOOL AlbumIsHidden(PHAssetCollection *collection) {
    if (![collection isKindOfClass:[PHAssetCollection class]] ||
        collection.localIdentifier.length == 0) {
        return NO;
    }
    if (gHiddenAlbumFlags == nil) {
        NSDictionary *all = [Preferences() dictionaryRepresentation];
        NSMutableDictionary *flags = [NSMutableDictionary dictionary];
        for (NSString *key in all) {
            if ([key hasPrefix:@"hide."]) {
                flags[[key substringFromIndex:5]] = all[key];
            }
        }
        gHiddenAlbumFlags = flags;
    }
    NSNumber *flag = gHiddenAlbumFlags[collection.localIdentifier];
    return flag != nil && flag.boolValue;
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
    gHiddenAlbumFlags = nil;  // per-album switches are re-read on next use
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


#pragma mark - Albums the pane lists, and albums it hides

// The pane runs in Settings, which cannot read the photo library, so the album
// list is gathered from the album cards Photos itself builds and published to
// the preferences domain the pane reads.
@interface PUAlbumGadget : NSObject
- (PHAssetCollection *)collection;
@end

static void RecordAlbumFromGadget(id gadget) {
    static NSMutableArray<NSDictionary *> *albums;
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        albums = [NSMutableArray array];
        seen = [NSMutableSet set];
    });
    PHAssetCollection *collection = nil;
    @try {
        if ([gadget respondsToSelector:@selector(collection)]) {
            collection = [(PUAlbumGadget *)gadget collection];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    NSString *identifier = collection.localIdentifier;
    NSString *title = collection.localizedTitle;
    if (identifier.length == 0 || title.length == 0 || [seen containsObject:identifier]) {
        return;
    }
    // People and Places have their own switch above; they are not albums here.
    NSString *gadgetClass = NSStringFromClass([gadget class]);
    if ([gadgetClass containsString:@"People"] || [gadgetClass containsString:@"Place"] ||
        [title containsString:@"人物"] || [title containsString:@"地点"] ||
        [title rangeOfString:@"people" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [title rangeOfString:@"places" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return;
    }
    [seen addObject:identifier];
    [albums addObject:@{@"id": identifier, @"title": title}];
    CFPreferencesSetAppValue(CFSTR("albumInventory"),
                             (__bridge CFPropertyListRef)[albums copy],
                             (__bridge CFStringRef)@APELIN_PACKAGE_ID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)@APELIN_PACKAGE_ID);
}

// The "我的相簿" list is a horizontal list of PUAlbumGadget, one per album, fed by
// PUAlbumsGadgetProvider. Leaving a gadget out of that provider's list is what
// removes the album's card.
static NSArray *(*OriginalGadgetProviderGadgets)(id, SEL);

static NSArray *HookedGadgetProviderGadgets(id self, SEL _cmd) {
    NSArray *gadgets = OriginalGadgetProviderGadgets(self, _cmd);
    Class albumsProvider = objc_getClass("PUAlbumsGadgetProvider");
    if (albumsProvider == Nil || ![self isKindOfClass:albumsProvider]) {
        return gadgets;
    }
    // The list is left as it is (its cells are keyed by position); the album is
    // hidden by giving its card no size, see below.
    for (id gadget in gadgets) {
        RecordAlbumFromGadget(gadget);
    }
    return gadgets;
}

// A hidden album's card cannot be dropped from the list (its neighbours shift)
// nor resized to nothing (the layout breaks), so it is laid out hidden: the cell
// stays in place for indexing and simply is not drawn.
static PHAssetCollection *AlbumAtIndexPath(id albumListGadget, NSIndexPath *indexPath) {
    id provider = nil;
    @try {
        provider = [albumListGadget valueForKey:@"provider"];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (provider == nil || ![provider respondsToSelector:@selector(gadgetForIndexPath:)]) {
        return nil;
    }
    id gadget = nil;
    @try {
        gadget = [(id)provider performSelector:@selector(gadgetForIndexPath:) withObject:indexPath];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (gadget != nil && [gadget respondsToSelector:@selector(collection)]) {
        return [(PUAlbumGadget *)gadget collection];
    }
    return nil;
}

static UICollectionViewLayoutAttributes *(*OriginalLayoutAttributesForItem)(id, SEL, NSIndexPath *);
static char kAlbumListLayoutKey;

static UICollectionViewLayoutAttributes *HookedLayoutAttributesForItem(id self, SEL _cmd,
                                                                      NSIndexPath *indexPath) {
    UICollectionViewLayoutAttributes *attributes = OriginalLayoutAttributesForItem(self, _cmd, indexPath);
    Class albumListClass = objc_getClass("PUHorizontalAlbumListGadget");
    if (albumListClass == Nil) {
        return attributes;
    }
    // Whether this layout belongs to the album list is asked once per layout.
    NSNumber *cached = objc_getAssociatedObject(self, &kAlbumListLayoutKey);
    id dataSource = nil;
    if (cached == nil) {
        @try {
            UICollectionView *collectionView = [self valueForKey:@"collectionView"];
            dataSource = collectionView.dataSource;
        } @catch (NSException *exception) {
            (void)exception;
        }
        BOOL isAlbumList = dataSource != nil && [dataSource isKindOfClass:albumListClass];
        objc_setAssociatedObject(self, &kAlbumListLayoutKey, @(isAlbumList),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!isAlbumList) {
            return attributes;
        }
    } else if (!cached.boolValue) {
        return attributes;
    } else {
        @try {
            UICollectionView *collectionView = [self valueForKey:@"collectionView"];
            dataSource = collectionView.dataSource;
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    if (dataSource == nil) {
        return attributes;
    }
    PHAssetCollection *collection = AlbumAtIndexPath(dataSource, indexPath);
    if (collection != nil && AlbumIsHidden(collection)) {
        attributes.hidden = YES;
    }
    return attributes;
}

// The list keeps its own array of album gadgets; filtering that array (not the
// provider's) keeps its counts, cells and indices consistent.
static void FilterAlbumListGadgetArrays(id albumList) {
    Class cls = object_getClass(albumList);
    for (Class klass = cls; klass != Nil; klass = class_getSuperclass(klass)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(klass, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type == NULL || type[0] != '@') {
                continue;
            }
            id value = object_getIvar(albumList, ivars[i]);
            if (![value isKindOfClass:[NSArray class]] || [value count] == 0) {
                continue;
            }
            BOOL hasAlbumGadget = NO;
            BOOL hasHidden = NO;
            for (id element in (NSArray *)value) {
                if (![element respondsToSelector:@selector(collection)]) {
                    continue;
                }
                hasAlbumGadget = YES;
                PHAssetCollection *collection = nil;
                @try {
                    collection = [(PUAlbumGadget *)element collection];
                } @catch (NSException *exception) {
                    (void)exception;
                }
                if (collection != nil && AlbumIsHidden(collection)) {
                    hasHidden = YES;
                    break;
                }
            }
            if (!hasAlbumGadget || !hasHidden) {
                continue;
            }
            NSMutableArray *kept = [NSMutableArray array];
            for (id element in (NSArray *)value) {
                PHAssetCollection *collection = nil;
                if ([element respondsToSelector:@selector(collection)]) {
                    @try {
                        collection = [(PUAlbumGadget *)element collection];
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                }
                if (collection != nil && AlbumIsHidden(collection)) {
                    continue;
                }
                [kept addObject:element];
            }
            object_setIvar(albumList, ivars[i], kept);
            // Keep the replacement alive: object_setIvar does not retain for us.
            objc_setAssociatedObject(albumList, ivars[i], kept, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        free(ivars);
    }
}

static id (*OriginalInitWithAlbumsGadgetProvider)(id, SEL, id);

static id HookedInitWithAlbumsGadgetProvider(id self, SEL _cmd, id provider) {
    id result = OriginalInitWithAlbumsGadgetProvider(self, _cmd, provider);
    @try {
        FilterAlbumListGadgetArrays(result);
    } @catch (NSException *exception) {
        (void)exception;
    }
    return result;
}

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

    Class albumsProvider = objc_getClass("PUAlbumsGadgetProvider");
    if (albumsProvider != Nil && class_getInstanceMethod(albumsProvider, @selector(gadgets)) != NULL) {
        MSHookMessageEx(albumsProvider, @selector(gadgets),
                        (IMP)HookedGadgetProviderGadgets, (IMP *)&OriginalGadgetProviderGadgets);
    } else {
        Class baseProvider = objc_getClass("PXGadgetProvider");
        if (baseProvider != Nil && class_getInstanceMethod(baseProvider, @selector(gadgets)) != NULL) {
            MSHookMessageEx(baseProvider, @selector(gadgets),
                            (IMP)HookedGadgetProviderGadgets, (IMP *)&OriginalGadgetProviderGadgets);
        }
    }

    if (albumsProvider != Nil &&
        class_getInstanceMethod(albumsProvider, @selector(_newGadgetForCollection:)) != NULL) {
        // Kept unhooked: returning nil from this creation point terminates Photos.
    }

    Class collectionViewClass = objc_getClass("UICollectionView");
    if (collectionViewClass != Nil) {
        (void)collectionViewClass;
    }

    Class albumList = objc_getClass("PUHorizontalAlbumListGadget");
    if (albumList != Nil) {
        (void)albumList;
    }

    Class layoutClass = objc_getClass("UICollectionViewLayout");
    if (layoutClass != Nil &&
        class_getInstanceMethod(layoutClass, @selector(layoutAttributesForItemAtIndexPath:)) != NULL) {
        MSHookMessageEx(layoutClass, @selector(layoutAttributesForItemAtIndexPath:),
                        (IMP)HookedLayoutAttributesForItem, (IMP *)&OriginalLayoutAttributesForItem);
    }

    Class albumListClass = objc_getClass("PUHorizontalAlbumListGadget");
    if (albumListClass != Nil &&
        class_getInstanceMethod(albumListClass, @selector(initWithAlbumsGadgetProvider:)) != NULL) {
        MSHookMessageEx(albumListClass, @selector(initWithAlbumsGadgetProvider:),
                        (IMP)HookedInitWithAlbumsGadgetProvider,
                        (IMP *)&OriginalInitWithAlbumsGadgetProvider);
    }
}
