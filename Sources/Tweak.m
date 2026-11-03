// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Photos, trimmed down: the "Hidden" smart album reads as empty (Photos draws
// its own "无照片或视频"), the "人物与地点" block of the Albums tab is gone with its
// title, and single albums can be left out of "我的相簿". A video can start with
// sound, with its mute button still working. Every switch belongs to the
// HiddenAlbumSettings pane and lives in the com.simon.hidden-album domain.
//
// Nine possible hook targets, enabled as needed on these concrete classes:
//   -[PXPhotosViewModel setEmptyPlaceholderState:]             the Hidden album
//   -[PXGadgetUIViewController collectionView:numberOfItemsInSection:]      \
//   -[PXGadgetUIViewController collectionView:layout:referenceSize...:]      / 人物与地点
//   -[PUAlbumsGadgetProvider gadgets]                          the album list
//   -[PUDoubleHeightHorizontalAlbumListGadgetLayout layoutAttributesForItemAtIndexPath:]
//                                                              hidden album cards
//   -[PUOneUpViewController presentViewController:animated:completion:]
//                                                              deleting without asking
//   -[PUOneUpBarsController _performMuteAction:]               the mute button
//   -[PUBrowsingVideoPlayer setMuted:]                         a video's start mute
//   -[PXVideoSession setVolume:withFade:]                      the video's audio level

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>

#import "ApelinBootstrap.h"

#pragma mark - The settings

// Settings are snapshotted only at launch, on a change notification, or on
// foreground entry. Layout callbacks never read preferences or invalidate an
// unchanged snapshot.
static BOOL gHideHiddenAlbum = YES;
static BOOL gHidePeopleAndPlaces = YES;
static BOOL gQuickDelete = NO;
static BOOL gAutoUnmuteVideo = NO;
static BOOL gLoaded = NO;
static BOOL gRestartScheduled = NO;
static NSUInteger gSettingsGeneration = 0;
static NSUInteger gInventoryObservationGeneration = 0;
static NSDictionary<NSString *, NSNumber *> *gHiddenAlbumFlags = nil;
static void InstallConfiguredHooks(void);
static dispatch_queue_t AlbumInventoryQueue(void);

static NSUserDefaults *Preferences(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
    });
    return defaults;
}

static BOOL BoolFromSnapshot(NSDictionary *snapshot, NSString *key, BOOL fallback) {
    id value = snapshot[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static BOOL AlbumIsHidden(PHAssetCollection *collection) {
    if (![collection isKindOfClass:[PHAssetCollection class]]) {
        return NO;
    }
    NSString *identifier = collection.localIdentifier;
    return identifier.length != 0 && gHiddenAlbumFlags[identifier].boolValue;
}

static void ReadSettings(void) {
    gInventoryObservationGeneration++;
    NSDictionary *snapshot = [Preferences() dictionaryRepresentation];
    BOOL album = BoolFromSnapshot(snapshot, @"enabled", YES);
    BOOL peopleAndPlaces = BoolFromSnapshot(snapshot, @"hidePeoplePlaces", YES);
    BOOL restart = gLoaded &&
        (album != gHideHiddenAlbum || peopleAndPlaces != gHidePeopleAndPlaces);

    NSMutableDictionary<NSString *, NSNumber *> *flags = [NSMutableDictionary dictionary];
    for (NSString *key in snapshot) {
        if ([key hasPrefix:@"hide."] && key.length > 5 &&
            BoolFromSnapshot(snapshot, key, NO)) {
            flags[[key substringFromIndex:5]] = @YES;
        }
    }
    if (gHiddenAlbumFlags == nil || ![gHiddenAlbumFlags isEqualToDictionary:flags]) {
        gHiddenAlbumFlags = [flags copy];
        gSettingsGeneration++;
    }
    gHideHiddenAlbum = album;
    gHidePeopleAndPlaces = peopleAndPlaces;
    gQuickDelete = BoolFromSnapshot(snapshot, @"quickDelete", NO);
    gAutoUnmuteVideo = BoolFromSnapshot(snapshot, @"autoUnmuteVideo", NO);
    gLoaded = YES;
    InstallConfiguredHooks();

    if (restart && !gRestartScheduled) {
        gRestartScheduled = YES;
        // Drain previously queued inventory writes before leaving, without
        // blocking Photos' main thread or scheduling a timer.
        dispatch_async(AlbumInventoryQueue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
        });
    }
}

static void SettingChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if ([NSThread isMainThread]) {
        ReadSettings();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ ReadSettings(); });
    }
}

#pragma mark - The Hidden album

static BOOL IsHiddenSmartAlbum(PHAssetCollection *collection) {
    return [collection isKindOfClass:[PHAssetCollection class]] &&
           collection.assetCollectionType == PHAssetCollectionTypeSmartAlbum &&
           collection.assetCollectionSubtype == PHAssetCollectionSubtypeSmartAlbumAllHidden;
}

// Only presentation changes. Photos retains its real data source, native
// authentication challenge, cancellation handling, and relocking behavior.
@interface PXContentPrivacyController : NSObject
- (BOOL)isLocked;
- (id)assetCollectionToObserve;
@end

@interface PXAssetsDataSource : NSObject
- (id)containerCollection;
@end

@interface PXPhotosViewModel : NSObject
- (PXContentPrivacyController *)privacyController;
- (PXAssetsDataSource *)currentDataSource;
- (NSInteger)contentPrivacyState;
@property (nonatomic) NSInteger emptyPlaceholderState;
@property (nonatomic) NSInteger footerVisibilityStyle;
@property (nonatomic) BOOL wantsFooterVisible;
@end

@interface HAHiddenAlbumPresentationState : NSObject
@property (nonatomic, weak) PXContentPrivacyController *privacyController;
@property (nonatomic, strong) id collection;
@property (nonatomic, weak) id dataSource;
@property (nonatomic, strong) id sourceCollection;
@property (nonatomic) BOOL hiddenAlbum;
@property (nonatomic) BOOL resolvingCollection;
@property (nonatomic) BOOL footerSuppressed;
@property (nonatomic) NSInteger savedFooterVisibilityStyle;
@end

@implementation HAHiddenAlbumPresentationState
@end

static char kHiddenPresentationStateKey;

// The native iOS 17 implementation uses 0 for content, 1 for locked, 2 for
// loading, and 3 for empty. Its state setter publishes the same change that
// PXPhotosUIViewController consumes to build the system empty configuration.
static const NSInteger HAEmptyPlaceholderStateEmpty = 3;
static const NSInteger HAFooterVisibilityStyleNever = 0;

static void HARestoreFooter(PXPhotosViewModel *model,
                            HAHiddenAlbumPresentationState *state) {
    if (state.footerSuppressed) {
        if (model.footerVisibilityStyle == HAFooterVisibilityStyleNever) {
            model.footerVisibilityStyle = state.savedFooterVisibilityStyle;
        }
        state.footerSuppressed = NO;
    }
}

static void (*OriginalSetEmptyPlaceholderState)(id, SEL, NSInteger);

static void HookedSetEmptyPlaceholderState(id self, SEL _cmd, NSInteger requestedState) {
    PXPhotosViewModel *model = (PXPhotosViewModel *)self;
    HAHiddenAlbumPresentationState *state =
        objc_getAssociatedObject(model, &kHiddenPresentationStateKey);
    if (![NSThread isMainThread] || state.resolvingCollection) {
        OriginalSetEmptyPlaceholderState(self, _cmd, requestedState);
        return;
    }
    if (!gHideHiddenAlbum) {
        OriginalSetEmptyPlaceholderState(self, _cmd, requestedState);
        HARestoreFooter(model, state);
        return;
    }

    // Native locked presentation always wins, including a transition whose
    // controller has changed but whose view-model state has not caught up yet.
    PXContentPrivacyController *privacy = [model privacyController];
    if (privacy == nil || requestedState == 1 || [model contentPrivacyState] == 1 ||
        [privacy isLocked]) {
        OriginalSetEmptyPlaceholderState(self, _cmd, requestedState);
        HARestoreFooter(model, state);
        return;
    }
    if (state == nil) {
        state = [HAHiddenAlbumPresentationState new];
        objc_setAssociatedObject(model, &kHiddenPresentationStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // The observed collection is optional in the native privacy controller.
    // Resolve this model's displayed collection instead when it is absent.
    // This is a presentation setter, never a data-source count callback.
    state.resolvingCollection = YES;
    id collection = [privacy assetCollectionToObserve];
    if (![collection isKindOfClass:[PHAssetCollection class]]) {
        PXAssetsDataSource *source = [model currentDataSource];
        if (state.dataSource != source || state.sourceCollection == nil) {
            state.dataSource = source;
            state.sourceCollection = [source containerCollection];
        }
        collection = state.sourceCollection;
    }
    state.resolvingCollection = NO;
    if (state.privacyController != privacy || state.collection != collection) {
        state.privacyController = privacy;
        state.collection = collection;
        state.hiddenAlbum = IsHiddenSmartAlbum(collection);
    }
    if (!state.hiddenAlbum) {
        OriginalSetEmptyPlaceholderState(self, _cmd, requestedState);
        HARestoreFooter(model, state);
        return;
    }

    // Enforce at the single publishing boundary, not after one particular
    // recomputation. Future native presentation updates cannot overwrite it.
    // The real data source and every authentication method remain untouched.
    OriginalSetEmptyPlaceholderState(self, _cmd, HAEmptyPlaceholderStateEmpty);
    NSInteger footerStyle = model.footerVisibilityStyle;
    if (!state.footerSuppressed || footerStyle != HAFooterVisibilityStyleNever) {
        state.savedFooterVisibilityStyle = footerStyle;
        state.footerSuppressed = YES;
    }
    if (footerStyle != HAFooterVisibilityStyleNever) {
        model.footerVisibilityStyle = HAFooterVisibilityStyleNever;
    }
    if (model.wantsFooterVisible) {
        model.wantsFooterVisible = NO;
    }
}

#pragma mark - 人物与地点 in the Albums tab

// The Albums tab is a gadget collection view: PXGadgetUIViewController lists
// gadgets one section each, titled "我的相簿", "人物与地点", "媒体类型" and so on.
// The section whose gadget is People & Places gets no items and no header, so the
// block and its title are both gone.
@interface PXGadgetUIViewController : UIViewController
- (id)_gadgetAtIndexPath:(NSIndexPath *)indexPath;
@end

static char kPeopleGadgetKey;

// The title is what tells the 人物与地点 block apart: its gadget is the same class as the
// album ones, so the class name says nothing.
static BOOL TitleIsPeopleAndPlaces(NSString *title) {
    if (title.length == 0) {
        return NO;
    }
    BOOL people = [title containsString:@"人物"] ||
                  [title rangeOfString:@"people" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL places = [title containsString:@"地点"] ||
                  [title rangeOfString:@"place" options:NSCaseInsensitiveSearch].location != NSNotFound;
    return people && places;
}

@protocol HATitledGadget <NSObject>
- (NSString *)title;
- (NSString *)localizedTitle;
@end

// Cache only a usable title; an initially untitled gadget can finish loading.
// The getter checks also avoid throwing KVC exceptions on every layout pass.
static BOOL GadgetIsPeopleAndPlaces(id<HATitledGadget> gadget) {
    NSNumber *cached = objc_getAssociatedObject(gadget, &kPeopleGadgetKey);
    if (cached != nil) {
        return cached.boolValue;
    }
    id title = [gadget respondsToSelector:@selector(title)] ? [gadget title] : nil;
    if ((![title isKindOfClass:[NSString class]] || [title length] == 0) &&
        [gadget respondsToSelector:@selector(localizedTitle)]) {
        title = [gadget localizedTitle];
    }
    if (![title isKindOfClass:[NSString class]] || [title length] == 0) {
        return NO;
    }
    BOOL verdict = TitleIsPeopleAndPlaces(title);
    objc_setAssociatedObject(gadget, &kPeopleGadgetKey, @(verdict),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return verdict;
}

static BOOL SectionIsPeopleAndPlaces(id controller, NSInteger section) {
    if (!gHidePeopleAndPlaces || section < 0) {
        return NO;
    }
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
    if (SectionIsPeopleAndPlaces(self, section)) {
        return 0;
    }
    return OriginalGadgetNumberOfItems(self, _cmd, collectionView, section);
}

static CGSize (*OriginalHeaderSize)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSInteger);

static CGSize HookedHeaderSize(id self, SEL _cmd, UICollectionView *collectionView,
                               UICollectionViewLayout *layout, NSInteger section) {
    if (SectionIsPeopleAndPlaces(self, section)) {
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

@interface HAAlbumProviderSnapshot : NSObject
@property (nonatomic, weak) NSArray *gadgets;
@property (nonatomic) NSUInteger count;
@property (nonatomic) NSUInteger observationGeneration;
@property (nonatomic) BOOL complete;
@property (nonatomic, copy) NSArray<NSDictionary *> *inventory;
@end
@implementation HAAlbumProviderSnapshot
@end

static char kProviderSnapshotKey;

static id DisplayCollectionOfGadget(id gadget) {
    id collection = nil;
    @try {
        if ([gadget respondsToSelector:@selector(collection)]) {
            collection = [(PUAlbumGadget *)gadget collection];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    return collection;
}

static PHAssetCollection *CollectionOfGadget(id gadget) {
    id collection = DisplayCollectionOfGadget(gadget);
    return [collection isKindOfClass:[PHAssetCollection class]] ? collection : nil;
}

static dispatch_queue_t AlbumInventoryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create(APELIN_PACKAGE_ID ".inventory", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Main-thread state describes the latest request, not a guaranteed disk commit.
// A failed latest synchronization permits a retry on the next provider event.
static NSArray<NSDictionary *> *gRequestedInventory;
static NSUInteger gInventoryRequestGeneration;

static NSArray<NSDictionary *> *QueueAlbumInventory(NSArray<NSDictionary *> *albums) {
    if (albums == nil || gRestartScheduled) {
        return albums;
    }
    if (gRequestedInventory == albums || [gRequestedInventory isEqualToArray:albums]) {
        return gRequestedInventory;
    }
    gRequestedInventory = [albums copy];
    NSArray *inventory = gRequestedInventory;
    NSUInteger generation = ++gInventoryRequestGeneration;
    // Preserve the original last-provider-wins order without synchronizing
    // cfprefsd on the UI thread. Equal provider snapshots share the same array.
    dispatch_async(AlbumInventoryQueue(), ^{
        CFPreferencesSetAppValue(CFSTR("albumInventory"),
                                 (__bridge CFPropertyListRef)inventory,
                                 (__bridge CFStringRef)@APELIN_PACKAGE_ID);
        if (CFPreferencesAppSynchronize((__bridge CFStringRef)@APELIN_PACKAGE_ID)) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/inventoryChanged"), NULL, NULL, true);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == gInventoryRequestGeneration) {
                    gRequestedInventory = nil;
                }
            });
        }
    });
    return inventory;
}

// Parse only a changed provider snapshot, but publish its cached inventory even
// on a cache hit when a different provider most recently supplied the pane.
static void RecordAlbumsInGadgets(id provider, NSArray *gadgets) {
    HAAlbumProviderSnapshot *snapshot =
        objc_getAssociatedObject(provider, &kProviderSnapshotKey);
    BOOL sameSnapshot = snapshot != nil && snapshot.gadgets == gadgets &&
                        snapshot.count == gadgets.count;
    if (sameSnapshot && (snapshot.complete ||
        snapshot.observationGeneration == gInventoryObservationGeneration)) {
        if (snapshot.complete) {
            snapshot.inventory = QueueAlbumInventory(snapshot.inventory);
        }
        return;
    }
    if (snapshot == nil) {
        snapshot = [HAAlbumProviderSnapshot new];
        objc_setAssociatedObject(provider, &kProviderSnapshotKey, snapshot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL previouslyLoaded = snapshot.inventory != nil;
    snapshot.gadgets = gadgets;
    snapshot.count = gadgets.count;
    snapshot.observationGeneration = gInventoryObservationGeneration;
    snapshot.complete = NO;
    if (gadgets.count == 0) {
        // An initially empty provider may still be loading. A previously valid
        // provider becoming empty can clear its own stale inventory.
        if (previouslyLoaded) {
            snapshot.complete = YES;
            snapshot.inventory = QueueAlbumInventory(@[]);
        }
        return;
    }
    BOOL incomplete = NO;
    NSMutableArray<NSDictionary *> *albums = [NSMutableArray arrayWithCapacity:gadgets.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:gadgets.count];
    for (id gadget in gadgets) {
        id displayedCollection = DisplayCollectionOfGadget(gadget);
        if (![displayedCollection isKindOfClass:[PHAssetCollection class]]) {
            if (displayedCollection == nil && [gadget respondsToSelector:@selector(collection)]) {
                incomplete = YES;
            }
            continue;  // Folder and utility cards are not per-album switches.
        }
        PHAssetCollection *collection = displayedCollection;
        NSString *identifier = collection.localIdentifier;
        NSString *title = collection.localizedTitle;
        if (identifier.length == 0 || title.length == 0) {
            incomplete = YES;
            continue;
        }
        if ([seen containsObject:identifier]) {
            continue;
        }
        // People and Places have their own switch above; they are not albums here.
        if (TitleIsPeopleAndPlaces(title)) {
            continue;
        }
        [seen addObject:identifier];
        [albums addObject:@{@"id": identifier, @"title": title}];
    }
    if (!incomplete && albums.count != 0) {
        snapshot.complete = YES;
        snapshot.inventory = QueueAlbumInventory(albums);
    }
}

static NSArray *(*OriginalGadgetProviderGadgets)(id, SEL);

static NSArray *HookedGadgetProviderGadgets(id self, SEL _cmd) {
    NSArray *gadgets = OriginalGadgetProviderGadgets(self, _cmd);
    if ([NSThread isMainThread] && [gadgets isKindOfClass:[NSArray class]]) {
        RecordAlbumsInGadgets(self, gadgets);
    }
    return gadgets;
}

#pragma mark - The album cards

// "我的相簿" is one list of PUAlbumGadget positions, its cells laid out by
// PUDoubleHeightHorizontalAlbumListGadgetLayout: item i sits in column i/2, row
// i%2. Dropping a hidden album from the provider's array breaks Photos' own
// indexing (it kept asking for index 10 of a 7 item array and crashed), so the
// array is left alone and the layout is given the visible arrangement instead.
@protocol HAAlbumGadgetProvider <NSObject>
- (NSArray *)gadgets;
@end

@interface PUHorizontalAlbumListGadget : NSObject
- (id<HAAlbumGadgetProvider>)provider;
@end

@interface HAAlbumLayoutState : NSObject
@property (nonatomic, weak) id dataSource;
@property (nonatomic) BOOL matchesAlbumList;
@property (nonatomic, weak) id<HAAlbumGadgetProvider> provider;
@property (nonatomic, weak) NSArray *gadgets;
@property (nonatomic) NSUInteger settingsGeneration;
@property (nonatomic) NSUInteger count;
@property (nonatomic, copy) NSArray<NSNumber *> *hidden;
@property (nonatomic, copy) NSArray<NSNumber *> *slots;
@property (nonatomic) BOOL metricsValid;
@property (nonatomic) CGSize boundsSize;
@property (nonatomic) CGSize cardSize;
@property (nonatomic) CGPoint origin;
@property (nonatomic) CGFloat columnStep;
@property (nonatomic) CGFloat rowOffset;
@end
@implementation HAAlbumLayoutState
@end

static char kAlbumLayoutStateKey;
static UICollectionViewLayoutAttributes *(*OriginalAlbumLayoutItem)(id, SEL, NSIndexPath *);

// The concrete layout inherits collectionView from UICollectionViewLayout.
// Resolve only its own list; weak references avoid layout -> controller cycles.
static HAAlbumLayoutState *AlbumSlotMap(UICollectionViewLayout *layout) {
    id dataSource = layout.collectionView.dataSource;
    if (dataSource == nil) {
        return nil;  // A layout can be queried before its view has a data source.
    }
    HAAlbumLayoutState *state = objc_getAssociatedObject(layout, &kAlbumLayoutStateKey);
    if (state == nil) {
        state = [HAAlbumLayoutState new];
        objc_setAssociatedObject(layout, &kAlbumLayoutStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.dataSource != dataSource) {
        state.dataSource = dataSource;
        state.provider = nil;
        state.gadgets = nil;
        state.hidden = nil;
        state.metricsValid = NO;
        Class albumListClass = objc_getClass("PUHorizontalAlbumListGadget");
        state.matchesAlbumList = albumListClass != Nil &&
            [dataSource isKindOfClass:albumListClass] &&
            [dataSource respondsToSelector:@selector(provider)];
    }
    if (!state.matchesAlbumList) {
        return nil;
    }
    id<HAAlbumGadgetProvider> provider = [(PUHorizontalAlbumListGadget *)dataSource provider];
    if (provider == nil || ![provider respondsToSelector:@selector(gadgets)]) {
        return nil;
    }
    NSArray *gadgets = [provider gadgets];
    if (![gadgets isKindOfClass:[NSArray class]]) {
        return nil;
    }
    // The native provider's gadgets property is copy/NSArray on this device.
    // A replacement snapshot invalidates even when its item count is unchanged.
    if (state.hidden != nil && state.provider == provider && state.gadgets == gadgets &&
        state.count == gadgets.count && state.settingsGeneration == gSettingsGeneration) {
        return state;
    }

    NSUInteger count = gadgets.count;
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:count];
    NSUInteger visible = 0;
    for (id gadget in gadgets) {
        BOOL isHidden = AlbumIsHidden(CollectionOfGadget(gadget));
        [hidden addObject:@(isHidden)];
        [slots addObject:@(visible)];
        if (!isHidden) {
            visible++;
        }
    }
    state.provider = provider;
    state.gadgets = gadgets;
    state.count = count;
    state.settingsGeneration = gSettingsGeneration;
    state.hidden = hidden;
    state.slots = slots;
    state.metricsValid = NO;
    return state;
}

static BOOL AlbumLayoutMetrics(UICollectionViewLayout *layout, SEL selector,
                               HAAlbumLayoutState *state, CGSize cardSize) {
    CGSize boundsSize = layout.collectionView.bounds.size;
    if (state.metricsValid && CGSizeEqualToSize(state.boundsSize, boundsSize) &&
        CGSizeEqualToSize(state.cardSize, cardSize)) {
        return YES;
    }
    if (state.count < 2) {
        return NO;
    }
    UICollectionViewLayoutAttributes *first =
        OriginalAlbumLayoutItem(layout, selector, [NSIndexPath indexPathForItem:0 inSection:0]);
    UICollectionViewLayoutAttributes *second =
        OriginalAlbumLayoutItem(layout, selector, [NSIndexPath indexPathForItem:1 inSection:0]);
    UICollectionViewLayoutAttributes *third = state.count >= 3 ?
        OriginalAlbumLayoutItem(layout, selector, [NSIndexPath indexPathForItem:2 inSection:0]) : nil;
    if (first == nil || second == nil || (state.count >= 3 && third == nil)) {
        return NO;
    }
    CGFloat columnStep = third != nil ? third.frame.origin.x - first.frame.origin.x : 1;
    CGFloat rowOffset = second.frame.origin.y - first.frame.origin.y;
    if (columnStep <= 0 || rowOffset <= 0) {
        return NO;
    }
    state.origin = first.frame.origin;
    state.columnStep = columnStep;
    state.rowOffset = rowOffset;
    state.boundsSize = boundsSize;
    state.cardSize = cardSize;
    state.metricsValid = YES;
    return YES;
}

static UICollectionViewLayoutAttributes *HookedAlbumLayoutItem(id self, SEL _cmd,
                                                               NSIndexPath *indexPath) {
    UICollectionViewLayoutAttributes *attributes = OriginalAlbumLayoutItem(self, _cmd, indexPath);
    if (attributes == nil || gHiddenAlbumFlags.count == 0 ||
        indexPath.section != 0 || indexPath.item < 0) {
        return attributes;
    }
    HAAlbumLayoutState *state = AlbumSlotMap(self);
    NSUInteger item = (NSUInteger)indexPath.item;
    if (state == nil || item >= state.count) {
        return attributes;
    }
    if (state.hidden[item].boolValue) {
        UICollectionViewLayoutAttributes *result = [attributes copy];
        result.hidden = YES;
        return result;
    }
    NSUInteger slot = state.slots[item].unsignedIntegerValue;
    if (slot == item || !AlbumLayoutMetrics(self, _cmd, state, attributes.size)) {
        return attributes;
    }
    UICollectionViewLayoutAttributes *result = [attributes copy];
    CGRect frame = result.frame;
    frame.origin.x = state.origin.x + (CGFloat)(slot / 2) * state.columnStep;
    frame.origin.y = state.origin.y + (CGFloat)(slot % 2) * state.rowOffset;
    result.frame = frame;
    return result;
}

#pragma mark - Deleting a photo without the question

// The viewer's trash button shows an action sheet: 从相簿中移除 / 删除 / 取消, and
// choosing 删除 brings a second confirmation. With the switch on neither is
// presented: the 删除 action of the one that Photos asks for is run instead, so
// the photo is deleted straight away and still lands in 最近删除.
static void (*OriginalPresentViewController)(id, SEL, UIViewController *, BOOL, void (^)(void));

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
    NSString *text = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
    NSString *lowercaseText = [text lowercaseString];
    BOOL mentionsPhoto = [text containsString:@"照片"] ||
                         [lowercaseText containsString:@"photo"];
    BOOL mentionsDelete = [text containsString:@"删除"] ||
                          [lowercaseText containsString:@"delete"];
    if (choices == 1 && mentionsPhoto && mentionsDelete) {
        return delete;
    }
    return nil;
}

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

#pragma mark - Sound when a video plays

// Use the actual setter from Photos' interface. Declaring a property named `isMuted`
// without setter=setMuted: would make a write call the nonexistent setIsMuted:.
@class PXVideoSession;
@interface PUBrowsingVideoPlayer : NSObject
@property (nonatomic, getter=isMuted, setter=setMuted:) BOOL muted;
@property (nonatomic) float volume;
@property (readonly, nonatomic) PXVideoSession *videoSession;
@end

@interface PUOneUpBarsController : NSObject
- (void)_performChangesWithCurrentVideoPlayer:(void (^)(PUBrowsingVideoPlayer *player))changes;
- (void)_setNeedsUpdatePlayPauseItems:(BOOL)needsUpdate;
- (void)updateBars;
@end

static void (*OriginalSetMuted)(id, SEL, BOOL);

// Set as soon as the user uses the mute button; from then on this video's mute requests
// are the user's and are applied as they come.
static BOOL gUserTouchedMute = NO;

// The session's volume is what the mute button really moves; it is kept so the button can
// drive it directly, through the same method Photos uses.
@interface PXVideoSession : NSObject
@property (readonly, nonatomic) float volume;
- (void)setVolume:(float)volume withFade:(BOOL)fade;
@end

static void (*OriginalSessionSetVolume)(id, SEL, float, BOOL);
static __weak PXVideoSession *gLastSession = nil;

static void HookedSessionSetVolume(id self, SEL _cmd, float volume, BOOL fade) {
    if (gLastSession != (PXVideoSession *)self) {
        // Another video: what Photos mutes while it starts belongs to Photos again.
        gUserTouchedMute = NO;
        gLastSession = (PXVideoSession *)self;
    }
    OriginalSessionSetVolume(self, _cmd, volume, fade);
}

static void HookedSetMuted(id self, SEL _cmd, BOOL muted) {
    PUBrowsingVideoPlayer *player = (PUBrowsingVideoPlayer *)self;
    // Photos mutes a video by itself while it starts (several times). Those requests are
    // applied as "not muted", and the audio is set to full so the video is really audible;
    // once the user has pressed the mute button everything goes through.
    BOOL automatic = gAutoUnmuteVideo && muted && !gUserTouchedMute;
    OriginalSetMuted(self, _cmd, automatic ? NO : muted);
    if (automatic) {
        @try {
            player.volume = 1.0f;
        } @catch (NSException *exception) {
            (void)exception;
        }
        @try {
            [gLastSession setVolume:1.0f withFade:NO];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

static void (*OriginalPerformMuteAction)(id, SEL, BOOL);

static void HookedPerformMuteAction(id self, SEL _cmd, BOOL muted) {
    gUserTouchedMute = YES;
    PUOneUpBarsController *bars = (PUOneUpBarsController *)self;
    if (!gAutoUnmuteVideo ||
        ![bars respondsToSelector:@selector(_performChangesWithCurrentVideoPlayer:)] ||
        ![bars respondsToSelector:@selector(_setNeedsUpdatePlayPauseItems:)] ||
        ![bars respondsToSelector:@selector(updateBars)]) {
        OriginalPerformMuteAction(self, _cmd, muted);
        return;
    }

    [bars _performChangesWithCurrentVideoPlayer:^(PUBrowsingVideoPlayer *player) {
        if (player == nil) {
            return;
        }
        PXVideoSession *session = player.videoSession ?: gLastSession;
        BOOL shouldMute = session != nil ? (session.volume > 0.5f) : !player.isMuted;

        // Photos' own state and the session's audio are both set here, inside the changes
        // block, and the bars are told to recompute their play/pause items: the button's
        // icon follows this state, the sound follows the session volume.
        [player setMuted:shouldMute];
        [session setVolume:(shouldMute ? 0.0f : 1.0f) withFade:YES];
        [bars _setNeedsUpdatePlayPauseItems:YES];
        [bars updateBars];
    }];
}

#pragma mark - Hook installation

static atomic_bool gWaitingForHookClasses;
static atomic_bool gHookInstallQueued;

static void HookSelector(Class cls, SEL selector, IMP hook, IMP *original) {
    if (*original == NULL && cls != Nil && class_getInstanceMethod(cls, selector) != NULL) {
        MSHookMessageEx(cls, selector, hook, original);
    }
}

static void HookNamedClass(const char *name, SEL selector, IMP hook, IMP *original,
                           BOOL requireOwnImplementation, BOOL *waiting) {
    if (*original != NULL) {
        return;
    }
    Class cls = objc_getClass(name);
    if (cls == Nil) {
        *waiting = YES;
        return;
    }
    if (requireOwnImplementation) {
        Method method = class_getInstanceMethod(cls, selector);
        Class parent = class_getSuperclass(cls);
        if (method == NULL || method == class_getInstanceMethod(parent, selector)) {
            return;  // Never fall back to hooking a base layout implementation.
        }
    }
    HookSelector(cls, selector, hook, original);
}

// Only enabled features install hooks. Once installed, a hook stays chained;
// changing its setting makes it pass through until the next app launch.
static void InstallConfiguredHooks(void) {
    // Arm the image callback before looking for classes, including when a new
    // setting enables a previously unused feature during a concurrent load.
    atomic_store_explicit(&gWaitingForHookClasses, true, memory_order_relaxed);
    BOOL waiting = NO;
    if (gHideHiddenAlbum && OriginalSetEmptyPlaceholderState == NULL) {
        Class model = objc_getClass("PXPhotosViewModel");
        Class privacy = objc_getClass("PXContentPrivacyController");
        Class source = objc_getClass("PXAssetsDataSource");
        if (model == Nil || privacy == Nil || source == Nil) {
            waiting = YES;
        } else {
            BOOL supported = YES;
            SEL selectors[] = {
                @selector(privacyController), @selector(currentDataSource),
                @selector(contentPrivacyState), @selector(setEmptyPlaceholderState:),
                @selector(footerVisibilityStyle), @selector(setFooterVisibilityStyle:),
                @selector(wantsFooterVisible), @selector(setWantsFooterVisible:)
            };
            for (NSUInteger i = 0; supported && i < sizeof(selectors) / sizeof(selectors[0]); i++) {
                supported = [model instancesRespondToSelector:selectors[i]];
            }
            if (supported && [source instancesRespondToSelector:@selector(containerCollection)] &&
                [privacy instancesRespondToSelector:@selector(assetCollectionToObserve)] &&
                [privacy instancesRespondToSelector:@selector(isLocked)]) {
                HookSelector(model, @selector(setEmptyPlaceholderState:),
                             (IMP)HookedSetEmptyPlaceholderState,
                             (IMP *)&OriginalSetEmptyPlaceholderState);
            }
        }
    }
    if (gHidePeopleAndPlaces) {
        HookNamedClass("PXGadgetUIViewController", @selector(collectionView:numberOfItemsInSection:),
                       (IMP)HookedGadgetNumberOfItems, (IMP *)&OriginalGadgetNumberOfItems, NO, &waiting);
        HookNamedClass("PXGadgetUIViewController",
                       @selector(collectionView:layout:referenceSizeForHeaderInSection:),
                       (IMP)HookedHeaderSize, (IMP *)&OriginalHeaderSize, NO, &waiting);
    }
    // Inventory is needed by the settings pane even when no cards are hidden.
    HookNamedClass("PUAlbumsGadgetProvider", @selector(gadgets),
                   (IMP)HookedGadgetProviderGadgets, (IMP *)&OriginalGadgetProviderGadgets, NO, &waiting);
    if (gHiddenAlbumFlags.count != 0) {
        HookNamedClass("PUDoubleHeightHorizontalAlbumListGadgetLayout",
                       @selector(layoutAttributesForItemAtIndexPath:),
                       (IMP)HookedAlbumLayoutItem, (IMP *)&OriginalAlbumLayoutItem, YES, &waiting);
    }
    if (gQuickDelete) {
        HookNamedClass("PUOneUpViewController", @selector(presentViewController:animated:completion:),
                       (IMP)HookedPresentViewController, (IMP *)&OriginalPresentViewController, NO, &waiting);
    }
    if (gAutoUnmuteVideo) {
        HookNamedClass("PUOneUpBarsController", @selector(_performMuteAction:),
                       (IMP)HookedPerformMuteAction, (IMP *)&OriginalPerformMuteAction, NO, &waiting);
        HookNamedClass("PUBrowsingVideoPlayer", @selector(setMuted:),
                       (IMP)HookedSetMuted, (IMP *)&OriginalSetMuted, NO, &waiting);
        HookNamedClass("PXVideoSession", @selector(setVolume:withFade:),
                       (IMP)HookedSessionSetVolume, (IMP *)&OriginalSessionSetVolume, NO, &waiting);
    }
    atomic_store_explicit(&gWaitingForHookClasses, waiting, memory_order_relaxed);
}

// dyld only queues one main-thread attempt when an image is actually added.
// No timer, hot-path availability check, or work under dyld's loader lock.
static void HAImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (!atomic_load_explicit(&gWaitingForHookClasses, memory_order_relaxed) ||
        atomic_exchange_explicit(&gHookInstallQueued, true, memory_order_relaxed)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(&gHookInstallQueued, false, memory_order_relaxed);
        InstallConfiguredHooks();
    });
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Required by Apelin; no feature, debugging, or periodic logging is kept.
    os_log(os_log_create(APELIN_PACKAGE_ID, "tweak"), "ApelinLoaded %{public}s in %{public}s",
           APELIN_BUILD_ID, getprogname());

    ReadSettings();
    _dyld_register_func_for_add_image(HAImageAdded);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SettingChangedCallback,
                                    (__bridge CFStringRef)(@APELIN_PACKAGE_ID "/changed"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        (void)note;
        ReadSettings();
    }];
}
