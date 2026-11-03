// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// Photos, trimmed down: the "Hidden" smart album reads as empty (Photos draws
// its own "无照片或视频"), the "人物与地点" block of the Albums tab is gone with its
// title, and single albums can be left out of "我的相簿". A video can start with
// sound, with its mute button still working. Every switch belongs to the
// HiddenAlbumSettings pane and lives in the com.simon.hidden-album domain.
//
// Nine hooks, each on the class that implements the method:
//   -[PXPhotosViewModel _updateEmptyPlaceholderState]          the Hidden album
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

#import "ApelinBootstrap.h"

#pragma mark - The settings

// Read once per launch and re-read only when the pane says a value changed or
// the app comes back to the front. Nothing polls.
static BOOL gHideHiddenAlbum = YES;
static BOOL gHidePeopleAndPlaces = YES;
static BOOL gQuickDelete = NO;
static BOOL gAutoUnmuteVideo = NO;
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
    gAutoUnmuteVideo = BoolFromPreferences(@"autoUnmuteVideo", NO);
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

// Only presentation changes. Photos retains its real data source, native
// authentication challenge, cancellation handling, and relocking behavior.
@interface PXContentPrivacyController : NSObject
- (BOOL)isLocked;
- (id)assetCollectionToObserve;
@end

@interface PXPhotosViewModel : NSObject
- (PXContentPrivacyController *)privacyController;
- (void)_updateEmptyPlaceholderState;
@property (nonatomic) NSInteger emptyPlaceholderState;
@property (nonatomic) NSInteger footerVisibilityStyle;
@property (nonatomic) BOOL wantsFooterVisible;
@end

@interface HAHiddenAlbumPresentationState : NSObject
@property (nonatomic, weak) PXContentPrivacyController *privacyController;
@property (nonatomic, strong) id collection;
@property (nonatomic) BOOL hiddenAlbum;
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

static void (*OriginalUpdateEmptyPlaceholderState)(id, SEL);
static void InstallVideoPlayerHooks(void);

static void HookedUpdateEmptyPlaceholderState(id self, SEL _cmd) {
    InstallVideoPlayerHooks();
    OriginalUpdateEmptyPlaceholderState(self, _cmd);
    if (![NSThread isMainThread]) {
        return;
    }

    PXPhotosViewModel *model = (PXPhotosViewModel *)self;
    HAHiddenAlbumPresentationState *state =
        objc_getAssociatedObject(model, &kHiddenPresentationStateKey);
    if (!gHideHiddenAlbum) {
        HARestoreFooter(model, state);
        return;
    }

    // Read the controller already owned by this exact view model. Never create
    // a different privacy controller or cache whether authentication succeeded.
    PXContentPrivacyController *privacy = [model privacyController];
    id collection = [privacy assetCollectionToObserve];
    if (privacy == nil || collection == nil) {
        HARestoreFooter(model, state);
        return;
    }
    if (state == nil) {
        state = [HAHiddenAlbumPresentationState new];
        objc_setAssociatedObject(model, &kHiddenPresentationStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.privacyController != privacy || state.collection != collection) {
        state.privacyController = privacy;
        state.collection = collection;
        state.hiddenAlbum = IsHiddenSmartAlbum(collection);
    }
    if (!state.hiddenAlbum || [privacy isLocked]) {
        // Keep the original protected presentation, including its unlock button.
        HARestoreFooter(model, state);
        return;
    }

    if (model.emptyPlaceholderState != HAEmptyPlaceholderStateEmpty) {
        model.emptyPlaceholderState = HAEmptyPlaceholderStateEmpty;
    }
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

// The verdict is kept on the gadget itself: the title is read once, while a section's item
// count and header size can both ask for it on every layout pass. The gadget is fetched
// through Photos' own index, never through the collection view, whose section count would
// call back into this and recurse until the stack ran out.
static BOOL GadgetIsPeopleAndPlaces(id gadget) {
    @try {
        NSNumber *cached = objc_getAssociatedObject(gadget, &kPeopleGadgetKey);
        if (cached != nil) {
            return cached.boolValue;
        }
        id value = [gadget valueForKey:@"title"];
        if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
            value = [gadget valueForKey:@"localizedTitle"];
        }
        BOOL verdict = TitleIsPeopleAndPlaces([value isKindOfClass:[NSString class]] ? value : nil);
        objc_setAssociatedObject(gadget, &kPeopleGadgetKey, @(verdict),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return verdict;
    } @catch (NSException *exception) {
        return NO;
    }
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

// The album cards Photos last handed out. The layout reads its positions from this array
// instead of asking the provider again while a cell is laid out, and a new array is what
// tells both the album list and the layout that something changed.
static NSArray *gLastGadgets = nil;

static PHAssetCollection *CollectionOfGadget(id gadget) {
    PHAssetCollection *collection = nil;
    @try {
        if ([gadget respondsToSelector:@selector(collection)]) {
            collection = [(PUAlbumGadget *)gadget collection];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    return [collection isKindOfClass:[PHAssetCollection class]] ? collection : nil;
}

// The pane runs in Settings, which cannot read the photo library, so it is handed the album
// list gathered from those cards. It is published only when the list itself changed.
static void RecordAlbumsInGadgets(NSArray *gadgets) {
    if (gadgets == gLastGadgets && gadgets != nil) {
        return;  // the same array: nothing new to read or publish
    }
    gLastGadgets = gadgets;
    if (gadgets.count == 0) {
        return;
    }
    NSMutableArray<NSDictionary *> *albums = [NSMutableArray arrayWithCapacity:gadgets.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:gadgets.count];
    for (id gadget in gadgets) {
        PHAssetCollection *collection = CollectionOfGadget(gadget);
        NSString *identifier = collection.localIdentifier;
        NSString *title = collection.localizedTitle;
        if (identifier.length == 0 || title.length == 0 || [seen containsObject:identifier]) {
            continue;
        }
        // People and Places have their own switch above; they are not albums here.
        if (TitleIsPeopleAndPlaces(title)) {
            continue;
        }
        [seen addObject:identifier];
        [albums addObject:@{@"id": identifier, @"title": title}];
    }
    static NSArray<NSDictionary *> *published;
    if (published != nil && [published isEqualToArray:albums]) {
        return;
    }
    published = [albums copy];
    CFPreferencesSetAppValue(CFSTR("albumInventory"),
                             (__bridge CFPropertyListRef)published,
                             (__bridge CFStringRef)@APELIN_PACKAGE_ID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)@APELIN_PACKAGE_ID);
}

static NSArray *(*OriginalGadgetProviderGadgets)(id, SEL);

static NSArray *HookedGadgetProviderGadgets(id self, SEL _cmd) {
    NSArray *gadgets = OriginalGadgetProviderGadgets(self, _cmd);
    RecordAlbumsInGadgets(gadgets);
    return gadgets;
}

#pragma mark - The album cards

// "我的相簿" is one list of PUAlbumGadget positions, its cells laid out by
// PUDoubleHeightHorizontalAlbumListGadgetLayout: item i sits in column i/2, row
// i%2. Dropping a hidden album from the provider's array breaks Photos' own
// indexing (it kept asking for index 10 of a 7 item array and crashed), so the
// array is left alone and the layout is given the visible arrangement instead.
static char kAlbumSlotMapKey;
static char kAlbumListSourceKey;
static char kAlbumListResolvedKey;
static char kAlbumListProviderKey;

// The album cards of the list this layout draws. The layout's data source is resolved once
// and kept, and so is its provider, so a cell being laid out never walks KVC again.
static NSArray *AlbumCardsForLayout(id layout) {
    NSNumber *resolved = objc_getAssociatedObject(layout, &kAlbumListResolvedKey);
    if (resolved == nil) {
        id candidate = nil;
        @try {
            candidate = [[layout valueForKey:@"collectionView"] dataSource];
        } @catch (NSException *exception) {
            (void)exception;
        }
        Class albumListClass = objc_getClass("PUHorizontalAlbumListGadget");
        BOOL matches = candidate != nil && albumListClass != Nil &&
                       [candidate isKindOfClass:albumListClass];
        objc_setAssociatedObject(layout, &kAlbumListResolvedKey, @(matches),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!matches) {
            return nil;  // another layout of the Albums tab
        }
        objc_setAssociatedObject(layout, &kAlbumListSourceKey, candidate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!resolved.boolValue) {
        return nil;
    }

    id dataSource = objc_getAssociatedObject(layout, &kAlbumListSourceKey);
    id provider = objc_getAssociatedObject(dataSource, &kAlbumListProviderKey);
    if (provider == nil) {
        @try {
            provider = [dataSource valueForKey:@"provider"];
        } @catch (NSException *exception) {
            (void)exception;
        }
        if (provider == nil || ![provider respondsToSelector:@selector(gadgets)]) {
            return nil;
        }
        objc_setAssociatedObject(dataSource, &kAlbumListProviderKey, provider,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *gadgets = nil;
    @try {
        gadgets = [(id)provider performSelector:@selector(gadgets)];
    } @catch (NSException *exception) {
        (void)exception;
    }
    return [gadgets isKindOfClass:[NSArray class]] ? gadgets : nil;
}

// One pass over this list's albums, kept on the layout: `hidden` says which albums the pane
// hides, `slots` which visible position each one takes. It is rebuilt only when a switch
// changed, or when the list's length did, so laying out a cell costs two array lookups.
static NSDictionary *AlbumSlotMap(id layout) {
    NSArray *gadgets = AlbumCardsForLayout(layout);
    if (gadgets == nil) {
        return nil;
    }
    NSDictionary *cached = objc_getAssociatedObject(layout, &kAlbumSlotMapKey);
    if (cached != nil &&
        [cached[@"settings"] intValue] == gSettingsGeneration &&
        [cached[@"count"] unsignedIntegerValue] == gadgets.count) {
        return cached;
    }

    NSUInteger count = gadgets.count;
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:count];
    NSUInteger visible = 0;
    for (id gadget in gadgets) {
        PHAssetCollection *collection = CollectionOfGadget(gadget);
        BOOL isHidden = collection != nil && AlbumIsHidden(collection);
        [hidden addObject:@(isHidden)];
        [slots addObject:@(visible)];
        if (!isHidden) {
            visible++;
        }
    }
    NSDictionary *map = @{@"settings": @(gSettingsGeneration),
                          @"count": @(count),
                          @"hidden": hidden,
                          @"slots": slots};
    objc_setAssociatedObject(layout, &kAlbumSlotMapKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return map;
}

static char kAlbumLayoutMetricsKey;

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
    if (indexPath.section != 0 || indexPath.item < 0) {
        return attributes;
    }
    // AlbumSlotMap resolves the layout's own list once; nil means this layout draws another
    // part of the Albums tab, and the attributes are left as Photos made them.
    NSDictionary *map = AlbumSlotMap(self);
    NSArray<NSNumber *> *hidden = map[@"hidden"];
    NSArray<NSNumber *> *slots = map[@"slots"];
    if ((NSUInteger)indexPath.item >= hidden.count) {
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

// The viewer's trash button shows an action sheet: 从相簿中移除 / 删除 / 取消, and
// choosing 删除 brings a second confirmation. With the switch on neither is
// presented: the 删除 action of the one that Photos asks for is run instead, so
// the photo is deleted straight away and still lands in 最近删除.
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

static void InstallVideoPlayerHooks(void) {
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    Class player = objc_getClass("PUBrowsingVideoPlayer");
    if (player == Nil) {
        return;  // not loaded yet; a later call tries again
    }
    MSHookMessageEx(player, @selector(setMuted:),
                    (IMP)HookedSetMuted, (IMP *)&OriginalSetMuted);
    Class session = objc_getClass("PXVideoSession");
    if (session != Nil) {
        MSHookMessageEx(session, @selector(setVolume:withFade:),
                        (IMP)HookedSessionSetVolume, (IMP *)&OriginalSessionSetVolume);
    }
    installed = YES;
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
        InstallVideoPlayerHooks();
    }];

    // These private interfaces are checked once, outside the update path. An
    // unfamiliar Photos version keeps its original protected presentation.
    Class photosViewModel = objc_getClass("PXPhotosViewModel");
    Class privacyController = objc_getClass("PXContentPrivacyController");
    BOOL supportsHiddenPresentation = photosViewModel != Nil && privacyController != Nil;
    SEL modelSelectors[] = {
        @selector(_updateEmptyPlaceholderState), @selector(privacyController),
        @selector(emptyPlaceholderState), @selector(setEmptyPlaceholderState:),
        @selector(footerVisibilityStyle), @selector(setFooterVisibilityStyle:),
        @selector(wantsFooterVisible), @selector(setWantsFooterVisible:)
    };
    for (NSUInteger i = 0; supportsHiddenPresentation &&
         i < sizeof(modelSelectors) / sizeof(modelSelectors[0]); i++) {
        supportsHiddenPresentation =
            [photosViewModel instancesRespondToSelector:modelSelectors[i]];
    }
    if (supportsHiddenPresentation &&
        [privacyController instancesRespondToSelector:@selector(assetCollectionToObserve)] &&
        [privacyController instancesRespondToSelector:@selector(isLocked)]) {
        HookSelector(photosViewModel, @selector(_updateEmptyPlaceholderState),
                     (IMP)HookedUpdateEmptyPlaceholderState,
                     (IMP *)&OriginalUpdateEmptyPlaceholderState);
    }

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

    HookSelector(objc_getClass("PUOneUpViewController"),
                 @selector(presentViewController:animated:completion:),
                 (IMP)HookedPresentViewController, (IMP *)&OriginalPresentViewController);

    HookSelector(objc_getClass("PUOneUpBarsController"), @selector(_performMuteAction:),
                 (IMP)HookedPerformMuteAction, (IMP *)&OriginalPerformMuteAction);

    InstallVideoPlayerHooks();
}
