// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Photos, trimmed down: the "Hidden" smart album reads as empty (Photos draws
// its own "无照片或视频"), the "人物与地点" block of the Albums tab is gone with its
// title, and single albums can be left out of "我的相簿". Every switch belongs to
// the HiddenAlbumSettings pane and lives in the com.simon.hidden-album domain.
//
// Five hooks, each on the class that implements the method:
//   -[PXPhotosDataSource numberOfSections]                    the Hidden album
//   -[PXGadgetUIViewController collectionView:numberOfItemsInSection:]      \
//   -[PXGadgetUIViewController collectionView:layout:referenceSize...:]      / 人物与地点
//   -[PUAlbumsGadgetProvider gadgets]                          the album list
//   -[PUDoubleHeightHorizontalAlbumListGadgetLayout layoutAttributesForItemAtIndexPath:]
//                                                              hidden album cards

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>

#import "ApelinBootstrap.h"

#pragma mark - The settings

// Read once per launch and re-read only when the pane says a value changed or
// the app comes back to the front. Nothing polls.
static BOOL gHideHiddenAlbum = YES;
static BOOL gHidePeopleAndPlaces = YES;
static BOOL gQuickDelete = NO;
static BOOL gLoaded = NO;
static int gSettingsGeneration = 0;
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
    gQuickDelete = BoolFromPreferences(@"quickDelete", NO);
    gHiddenAlbumFlags = nil;  // per-album switches are re-read on next use
    gSettingsGeneration++;    // and every cached album list with them
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

// The Albums tab is a gadget collection view: PXGadgetUIViewController lists
// gadgets one section each, titled "我的相簿", "人物与地点", "媒体类型" and so on.
// The section whose gadget is People & Places gets no items and no header, so the
// block and its title are both gone.
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

#pragma mark - The albums the pane lists

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

static NSArray *(*OriginalGadgetProviderGadgets)(id, SEL);

static NSArray *HookedGadgetProviderGadgets(id self, SEL _cmd) {
    NSArray *gadgets = OriginalGadgetProviderGadgets(self, _cmd);
    for (id gadget in gadgets) {
        RecordAlbumFromGadget(gadget);
    }
    return gadgets;
}

#pragma mark - The album cards

// "我的相簿" is one list of PUAlbumGadget positions, its cells laid out by
// PUDoubleHeightHorizontalAlbumListGadgetLayout: item i sits in column i/2, row
// i%2. Dropping a hidden album from the provider's array breaks Photos' own
// indexing (it kept asking for index 10 of a 7 item array and crashed), so the
// array is left alone and the layout is given the visible arrangement instead.
static char kAlbumSlotMapKey;

// One pass over the provider's albums, cached per provider until the switches
// change or the list does: `hidden` says which albums the pane hides, `slots`
// says which visible position each album takes.
static NSDictionary *AlbumSlotMap(id albumListGadget) {
    id provider = nil;
    @try {
        provider = [albumListGadget valueForKey:@"provider"];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (provider == nil || ![provider respondsToSelector:@selector(gadgets)]) {
        return nil;
    }
    NSArray *gadgets = nil;
    @try {
        gadgets = [(id)provider performSelector:@selector(gadgets)];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (![gadgets isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSDictionary *cached = objc_getAssociatedObject(provider, &kAlbumSlotMapKey);
    if ([cached[@"generation"] intValue] == gSettingsGeneration &&
        [cached[@"count"] unsignedIntegerValue] == gadgets.count) {
        return cached;
    }

    NSMutableArray<NSNumber *> *hidden = [NSMutableArray arrayWithCapacity:gadgets.count];
    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:gadgets.count];
    NSUInteger visible = 0;
    for (id gadget in gadgets) {
        PHAssetCollection *collection = nil;
        if ([gadget respondsToSelector:@selector(collection)]) {
            @try {
                collection = [(PUAlbumGadget *)gadget collection];
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        BOOL isHidden = collection != nil && AlbumIsHidden(collection);
        [hidden addObject:@(isHidden)];
        [slots addObject:@(visible)];
        if (!isHidden) {
            visible++;
        }
    }
    NSDictionary *map = @{@"generation": @(gSettingsGeneration),
                          @"count": @(gadgets.count),
                          @"hidden": hidden,
                          @"slots": slots};
    objc_setAssociatedObject(provider, &kAlbumSlotMapKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return map;
}

static char kAlbumLayoutMetricsKey;
static char kAlbumListLayoutKey;

static UICollectionViewLayoutAttributes *(*OriginalAlbumLayoutItem)(id, SEL, NSIndexPath *);

// Column step and row offset, read from the layout's own attributes once and kept
// on the layout instance.
static BOOL AlbumLayoutMetrics(id layout, SEL _cmd, CGFloat *columnStep, CGFloat *rowOffset) {
    NSArray *cached = objc_getAssociatedObject(layout, &kAlbumLayoutMetricsKey);
    if ([cached isKindOfClass:[NSArray class]] && cached.count == 2) {
        *columnStep = [cached[0] doubleValue];
        *rowOffset = [cached[1] doubleValue];
        return *columnStep > 0 && *rowOffset > 0;
    }
    UICollectionViewLayoutAttributes *first =
        OriginalAlbumLayoutItem(layout, _cmd, [NSIndexPath indexPathForItem:0 inSection:0]);
    UICollectionViewLayoutAttributes *second =
        OriginalAlbumLayoutItem(layout, _cmd, [NSIndexPath indexPathForItem:1 inSection:0]);
    UICollectionViewLayoutAttributes *third =
        OriginalAlbumLayoutItem(layout, _cmd, [NSIndexPath indexPathForItem:2 inSection:0]);
    if (first == nil || second == nil || third == nil) {
        return NO;
    }
    *columnStep = third.frame.origin.x - first.frame.origin.x;
    *rowOffset = second.frame.origin.y - first.frame.origin.y;
    if (*columnStep <= 0 || *rowOffset <= 0) {
        return NO;
    }
    objc_setAssociatedObject(layout, &kAlbumLayoutMetricsKey,
                             @[@(*columnStep), @(*rowOffset)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static UICollectionViewLayoutAttributes *HookedAlbumLayoutItem(id self, SEL _cmd,
                                                               NSIndexPath *indexPath) {
    UICollectionViewLayoutAttributes *attributes = OriginalAlbumLayoutItem(self, _cmd, indexPath);
    if (indexPath.section != 0) {
        return attributes;
    }
    // Asked once per layout: does this one lay out the album cards at all?
    NSNumber *isAlbumList = objc_getAssociatedObject(self, &kAlbumListLayoutKey);
    id dataSource = nil;
    if (isAlbumList == nil || isAlbumList.boolValue) {
        @try {
            dataSource = [[self valueForKey:@"collectionView"] dataSource];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    if (isAlbumList == nil) {
        Class albumListClass = objc_getClass("PUHorizontalAlbumListGadget");
        BOOL matches = dataSource != nil && albumListClass != Nil &&
                       [dataSource isKindOfClass:albumListClass];
        objc_setAssociatedObject(self, &kAlbumListLayoutKey, @(matches),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!matches) {
            return attributes;
        }
    } else if (!isAlbumList.boolValue || dataSource == nil) {
        return attributes;
    }

    NSDictionary *map = AlbumSlotMap(dataSource);
    NSArray<NSNumber *> *hidden = map[@"hidden"];
    NSArray<NSNumber *> *slots = map[@"slots"];
    if (indexPath.item < 0 || (NSUInteger)indexPath.item >= hidden.count) {
        return attributes;
    }
    if (hidden[indexPath.item].boolValue) {
        attributes.hidden = YES;
        return attributes;
    }
    NSUInteger slot = slots[indexPath.item].unsignedIntegerValue;
    if (slot == (NSUInteger)indexPath.item) {
        return attributes;  // nothing hidden before this card
    }
    CGFloat columnStep = 0;
    CGFloat rowOffset = 0;
    if (!AlbumLayoutMetrics(self, _cmd, &columnStep, &rowOffset)) {
        return attributes;
    }
    CGRect frame = attributes.frame;
    frame.origin.x = (CGFloat)(slot / 2) * columnStep;
    frame.origin.y = (CGFloat)(slot % 2) * rowOffset;
    attributes.frame = frame;
    return attributes;
}

#pragma mark - Deleting a photo without the question

// The viewer's trash button shows an action sheet: 从相簿中移除 / 删除 / 取消. With
// the switch on the sheet is not presented at all and its 删除 action runs
// straight away; the photo still lands in 最近删除, as any delete does.
static BOOL (*OriginalPresentViewController)(id, SEL, UIViewController *, BOOL, void (^)(void));

static BOOL TitleMentionsAlbum(NSString *title) {
    return [title containsString:@"相簿"] ||
           [title rangeOfString:@"album" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL TitleIsDelete(NSString *title) {
    return [title containsString:@"删除"] ||
           [title rangeOfString:@"delete" options:NSCaseInsensitiveSearch].location == 0;
}

// The 删除 action of the viewer's sheet, or the one on the system's own
// confirmation that follows it ("此照片将从图库中删除。它将在“最近删除”中保留 30 天。"),
// or nil when this alert is something else. Two shapes are recognised:
//   从相簿中移除 / 删除 / 取消        — the sheet the trash button shows
//   message mentioning 最近删除 + 删除照片 / 取消 — the confirmation behind it
static UIAlertAction *DeleteActionInAlert(UIAlertController *alert) {
    UIAlertAction *delete = nil;
    BOOL offersRemoveFromAlbum = NO;
    NSUInteger choices = 0;
    for (UIAlertAction *action in alert.actions) {
        if (action.style == UIAlertActionStyleDestructive) {
            delete = action;
        } else if (action.style != UIAlertActionStyleCancel &&
                   TitleMentionsAlbum(action.title ?: @"")) {
            offersRemoveFromAlbum = YES;
        }
        if (action.style != UIAlertActionStyleCancel) {
            choices++;
        }
    }
    if (delete == nil || !TitleIsDelete(delete.title ?: @"")) {
        return nil;
    }
    if (offersRemoveFromAlbum) {
        return delete;
    }
    NSString *message = alert.message ?: @"";
    BOOL mentionsRecentlyDeleted =
        [message containsString:@"最近删除"] ||
        [message rangeOfString:@"recently deleted" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (choices == 1 && mentionsRecentlyDeleted) {
        return delete;
    }
    return nil;
}

// Only this app's own alerts are considered: the tweak is injected into Photos
// alone, and the two shapes matched by DeleteActionInAlert are specific enough
// that another alert in this app cannot be mistaken for them.
static void HookedPresentViewController(id self, SEL _cmd, UIViewController *viewController,
                                        BOOL animated, void (^completion)(void)) {
    if (gQuickDelete && [viewController isKindOfClass:[UIAlertController class]]) {
        UIAlertAction *delete = DeleteActionInAlert((UIAlertController *)viewController);
        if (delete != nil) {
            void (^handler)(UIAlertAction *) = nil;
            @try {
                handler = [delete valueForKey:@"handler"];
            } @catch (NSException *exception) {
                (void)exception;
            }
            if (handler != nil) {
                handler(delete);
                if (completion != nil) {
                    completion();
                }
                return;
            }
        }
    }
    OriginalPresentViewController(self, _cmd, viewController, animated, completion);
}

// Some of Photos' alerts do not come through presentViewController: on this build
// the system delete confirmation is shown by its own presenter. One that appears
// all the same is closed here and its 删除 action run instead.
static void (*OriginalAlertViewDidAppear)(id, SEL, BOOL);

static void HookedAlertViewDidAppear(id self, SEL _cmd, BOOL animated) {
    OriginalAlertViewDidAppear(self, _cmd, animated);
    if (!gQuickDelete) {
        return;
    }
    UIAlertAction *delete = DeleteActionInAlert((UIAlertController *)self);
    if (delete == nil) {
        return;
    }
    void (^handler)(UIAlertAction *) = nil;
    @try {
        handler = [delete valueForKey:@"handler"];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (handler == nil) {
        return;
    }
    UIAlertController *alert = (UIAlertController *)self;
    [alert dismissViewControllerAnimated:NO
                              completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(delete);
        });
    }];
}

#pragma mark - Hooks

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

    HookSelector(objc_getClass("PUAlbumsGadgetProvider"), @selector(gadgets),
                 (IMP)HookedGadgetProviderGadgets, (IMP *)&OriginalGadgetProviderGadgets);

    HookSelector(objc_getClass("PUDoubleHeightHorizontalAlbumListGadgetLayout"),
                 @selector(layoutAttributesForItemAtIndexPath:),
                 (IMP)HookedAlbumLayoutItem, (IMP *)&OriginalAlbumLayoutItem);

    HookSelector(objc_getClass("UIViewController"),
                 @selector(presentViewController:animated:completion:),
                 (IMP)HookedPresentViewController, (IMP *)&OriginalPresentViewController);
    HookSelector(objc_getClass("UIAlertController"), @selector(viewDidAppear:),
                 (IMP)HookedAlertViewDidAppear, (IMP *)&OriginalAlertViewDidAppear);
}
