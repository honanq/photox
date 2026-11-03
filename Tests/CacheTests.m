// SPDX-License-Identifier: MIT
// Isolated synthetic data only: no assets, preferences, authentication, or UI.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <string.h>

@interface HATestCollection : NSObject
@property (nonatomic, copy) NSString *localIdentifier;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic) PHAssetCollectionType assetCollectionType;
@property (nonatomic) PHAssetCollectionSubtype assetCollectionSubtype;
@end
@implementation HATestCollection
@end

static Class HATestGetClass(const char *name);

// All system headers are imported first. Suppress only the source constructor;
// the test includes the actual production functions, not copies of their logic.
#define constructor unused
#define PHAssetCollection HATestCollection
#define PUHorizontalAlbumListGadget HATestAlbumList
#define objc_getClass HATestGetClass
#define APELIN_PACKAGE_ID "local.apelin.synthetic-cache-tests"
#define APELIN_BUILD_ID "synthetic-test"
#import "../Sources/Tweak.m"
#undef constructor
#undef PHAssetCollection
#undef PUHorizontalAlbumListGadget
#undef objc_getClass

// The metadata worker has its own isolated tests; never start it in this suite.
void HAStartAlbumInventory(void) {}
void HARefreshAlbumInventory(void) {}
void HAStopAlbumInventory(dispatch_block_t completion) { (void)completion; }

static NSUInteger gAssertions;
static NSUInteger gFailures;
static NSUInteger gCollectionReads;
static NSUInteger gHookCalls;

static void CHECK(BOOL condition, const char *label) {
    gAssertions++;
    if (!condition) { gFailures++; fprintf(stderr, "FAIL: %s\n", label); }
}

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    (void)cls; (void)selector; (void)replacement; (void)original;
    gHookCalls++;
}

@interface HATestGadget : NSObject
@property (nonatomic, strong) HATestCollection *testCollection;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic) NSUInteger titleReads;
- (HATestCollection *)collection;
@end
@implementation HATestGadget
- (HATestCollection *)collection { gCollectionReads++; return _testCollection; }
- (NSString *)title { _titleReads++; return _title; }
@end

@interface HATestProvider : NSObject <HAAlbumGadgetProvider>
@property (nonatomic, copy) NSArray *gadgets;
@end
@implementation HATestProvider
@end

static char kTestProviderKey;
@implementation HATestAlbumList
- (id<HAAlbumGadgetProvider>)provider {
    return objc_getAssociatedObject(self, &kTestProviderKey);
}
@end

static Class HATestGetClass(const char *name) {
    // Do not discover or hook real private Photos classes in this process.
    return strcmp(name, "PUHorizontalAlbumListGadget") == 0 ? [HATestAlbumList class] : Nil;
}

@interface HATestView : NSObject
@property (nonatomic, strong) id dataSource;
@property (nonatomic) CGRect bounds;
@end
@implementation HATestView
@end

@interface HATestLayout : NSObject
@property (nonatomic, strong) HATestView *collectionView;
@property (nonatomic, strong) NSMutableDictionary *attributes;
@property (nonatomic) NSUInteger originalCalls;
@property (nonatomic) CGSize cardSize;
@property (nonatomic) CGPoint origin;
@property (nonatomic) CGFloat columnStep;
@property (nonatomic) CGFloat rowOffset;
@end
@implementation HATestLayout
@end

static UICollectionViewLayoutAttributes *TestOriginalLayout(id object, SEL selector, NSIndexPath *path) {
    (void)selector;
    HATestLayout *layout = object;
    layout.originalCalls++;
    if (path.item == 999) return nil;
    UICollectionViewLayoutAttributes *attributes = layout.attributes[path];
    if (attributes == nil) {
        attributes = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:path];
        attributes.frame = (CGRect){
            {layout.origin.x + (path.item / 2) * layout.columnStep,
             layout.origin.y + (path.item % 2) * layout.rowOffset}, layout.cardSize};
        layout.attributes[path] = attributes;
    }
    return attributes;
}

static HATestGadget *Gadget(NSString *identifier) {
    HATestGadget *gadget = [HATestGadget new];
    gadget.testCollection = [HATestCollection new];
    gadget.testCollection.localIdentifier = identifier;
    gadget.testCollection.localizedTitle = identifier;
    return gadget;
}
static HATestAlbumList *Source(HATestProvider *provider) {
    HATestAlbumList *source = [HATestAlbumList new];
    objc_setAssociatedObject(source, &kTestProviderKey, provider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return source;
}
static NSIndexPath *Path(NSUInteger item) {
    return [NSIndexPath indexPathForItem:item inSection:0];
}
static HAAlbumLayoutState *Map(HATestLayout *layout) {
    return AlbumSlotMap((UICollectionViewLayout *)layout);
}
static UICollectionViewLayoutAttributes *Item(HATestLayout *layout, NSUInteger item) {
    return HookedAlbumLayoutItem(layout, @selector(layoutAttributesForItemAtIndexPath:), Path(item));
}

static void TestCacheAndGeometry(void) {
    HATestGadget *a = Gadget(@"A"), *b = Gadget(@"B"), *c = Gadget(@"C"), *d = Gadget(@"D");
    HATestProvider *provider = [HATestProvider new];
    provider.gadgets = @[a, b, c, d];
    HATestAlbumList *source = Source(provider);
    HATestLayout *layout = [HATestLayout new];
    layout.collectionView = [HATestView new];
    layout.collectionView.bounds = CGRectMake(0, 0, 390, 300);
    layout.attributes = [NSMutableDictionary dictionary];
    layout.cardSize = CGSizeMake(100, 120);
    layout.origin = CGPointMake(12, 18);
    layout.columnStep = 130;
    layout.rowOffset = 150;
    OriginalAlbumLayoutItem = TestOriginalLayout;
    gHiddenAlbumFlags = @{@"A": @YES};
    gSettingsGeneration = 1;

    CHECK(Map(layout) == nil, "nil source is not cached as a permanent mismatch");
    layout.collectionView.dataSource = source;
    HAAlbumLayoutState *state = Map(layout);
    CHECK(state.count == 4, "nil source can recover");
    CHECK([state.hidden isEqual:@[@YES, @NO, @NO, @NO]], "initial hidden mapping");
    CHECK([state.slots isEqual:@[@0, @0, @1, @2]], "initial visible slots");
    NSUInteger reads = gCollectionReads;
    NSArray *cached = state.hidden;
    for (NSUInteger i = 0; i < 10000; i++) Map(layout);
    CHECK(gCollectionReads == reads, "10000 cache hits perform no collection scans");
    CHECK(state.hidden == cached, "cache hits preserve the slot arrays");

    provider.gadgets = @[b, a, c, d];
    state = Map(layout);
    CHECK(gCollectionReads == reads + 4, "same-count replacement invalidates");
    CHECK([state.hidden isEqual:@[@NO, @YES, @NO, @NO]], "reordered hidden mapping");
    CHECK([state.slots isEqual:@[@0, @1, @1, @2]], "reordered visible slots");
    gHiddenAlbumFlags = @{@"B": @YES};
    gSettingsGeneration++;
    reads = gCollectionReads;
    state = Map(layout);
    CHECK(gCollectionReads == reads + 4, "settings generation invalidates");
    CHECK(state.hidden[0].boolValue && !state.hidden[1].boolValue, "new settings applied");

    HATestProvider *replacement = [HATestProvider new];
    replacement.gadgets = @[a, b, c, d];
    objc_setAssociatedObject(source, &kTestProviderKey, replacement, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state = Map(layout);
    CHECK(state.provider == replacement && state.hidden[1].boolValue, "provider identity invalidates");
    HATestAlbumList *otherSource = Source(provider);
    layout.collectionView.dataSource = otherSource;
    state = Map(layout);
    CHECK(state.dataSource == otherSource && state.provider == provider, "source identity invalidates");
    layout.collectionView.dataSource = [NSObject new];
    CHECK(Map(layout) == nil, "unrelated source stays untouched");
    layout.collectionView.dataSource = source;
    gHiddenAlbumFlags = @{@"A": @YES};
    gSettingsGeneration++;
    state = Map(layout);

    UICollectionViewLayoutAttributes *hidden = Item(layout, 0);
    CHECK(hidden.hidden, "hidden card has hidden attributes");
    CHECK(![layout.attributes[Path(0)] isHidden], "hidden copy leaves native cache unchanged");
    UICollectionViewLayoutAttributes *moved = Item(layout, 1);
    CHECK(CGPointEqualToPoint(moved.frame.origin, layout.origin), "visible card compacts to first slot");
    CHECK(CGPointEqualToPoint([layout.attributes[Path(1)] frame].origin,
                             CGPointMake(12, 168)), "moved copy leaves native geometry unchanged");
    NSUInteger calls = layout.originalCalls;
    Item(layout, 1);
    CHECK(layout.originalCalls == calls + 1, "geometry cache avoids extra native lookups");
    layout.collectionView.bounds = CGRectMake(0, 0, 844, 300);
    calls = layout.originalCalls;
    Item(layout, 1);
    CHECK(layout.originalCalls == calls + 4, "bounds-size change refreshes metrics once");
    layout.cardSize = CGSizeMake(110, 120);
    [layout.attributes removeAllObjects];
    calls = layout.originalCalls;
    Item(layout, 1);
    CHECK(layout.originalCalls == calls + 4, "card-size change refreshes metrics once");
    CHECK(Item(layout, 999) == nil, "nil native attributes pass through");
    replacement.gadgets = @[a, b];
    [layout.attributes removeAllObjects];
    CHECK(CGPointEqualToPoint(Item(layout, 1).frame.origin, layout.origin), "two-card layout compacts");
    gHiddenAlbumFlags = @{};
    UICollectionViewLayoutAttributes *native = TestOriginalLayout(layout, NULL, Path(1));
    CHECK(Item(layout, 1) == native, "no hidden flags returns original object");
}

static void TestTitles(void) {
    HATestGadget *gadget = [HATestGadget new];
    CHECK(!GadgetIsPeopleAndPlaces((id)gadget), "empty title is not a match");
    gadget.localizedTitle = @"人物与地点";
    CHECK(GadgetIsPeopleAndPlaces((id)gadget), "localized title can resolve an initially empty gadget");
    NSUInteger reads = gadget.titleReads;
    CHECK(GadgetIsPeopleAndPlaces((id)gadget) && gadget.titleReads == reads, "positive title is cached");
    HATestGadget *ordinary = [HATestGadget new];
    ordinary.title = @"My Albums";
    CHECK(!GadgetIsPeopleAndPlaces((id)ordinary), "ordinary title is not a match");
    reads = ordinary.titleReads;
    CHECK(!GadgetIsPeopleAndPlaces((id)ordinary) && ordinary.titleReads == reads, "negative title is cached");
    CHECK(TitleIsPeopleAndPlaces(@"People & Places"), "English title supported");
}

@interface HATestPrivacy : NSObject
@property (nonatomic, getter=isLocked) BOOL locked;
@property (nonatomic, strong) id assetCollectionToObserve;
@end
@implementation HATestPrivacy
@end

@interface HATestAssetSource : NSObject
@property (nonatomic, strong) id containerCollection;
@property (nonatomic) NSUInteger collectionReads;
@end
@implementation HATestAssetSource
- (id)containerCollection { _collectionReads++; return _containerCollection; }
@end

@interface HATestPhotosModel : NSObject
@property (nonatomic, strong) HATestPrivacy *privacyController;
@property (nonatomic, strong) HATestAssetSource *currentDataSource;
@property (nonatomic) NSInteger contentPrivacyState;
@property (nonatomic) NSInteger emptyPlaceholderState;
@property (nonatomic) NSInteger footerVisibilityStyle;
@property (nonatomic) BOOL wantsFooterVisible;
@end
@implementation HATestPhotosModel
@end

static void TestOriginalEmptySetter(id object, SEL selector, NSInteger value) {
    (void)selector;
    [(HATestPhotosModel *)object setEmptyPlaceholderState:value];
}
static void SetPresentation(HATestPhotosModel *model, NSInteger value) {
    HookedSetEmptyPlaceholderState(model, @selector(setEmptyPlaceholderState:), value);
}
static void TestHiddenPresentation(void) {
    OriginalSetEmptyPlaceholderState = TestOriginalEmptySetter;
    gHideHiddenAlbum = YES;
    HATestCollection *hidden = Gadget(@"SYNTHETIC-HIDDEN").testCollection;
    hidden.assetCollectionType = PHAssetCollectionTypeSmartAlbum;
    hidden.assetCollectionSubtype = PHAssetCollectionSubtypeSmartAlbumAllHidden;
    HATestPhotosModel *model = [HATestPhotosModel new];
    model.footerVisibilityStyle = 2;
    model.wantsFooterVisible = YES;
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 0 && model.footerVisibilityStyle == 2,
          "absent privacy controller leaves native presentation untouched");
    HATestPrivacy *privacy = [HATestPrivacy new];
    model.privacyController = privacy;
    privacy.assetCollectionToObserve = hidden;
    privacy.locked = YES;
    model.contentPrivacyState = 1;
    SetPresentation(model, 1);
    CHECK(model.emptyPlaceholderState == 1 && model.footerVisibilityStyle == 2,
          "native locked presentation preserved");
    privacy.locked = NO;
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 0, "stale locked view-model state never overridden");
    model.contentPrivacyState = 0;
    SetPresentation(model, 1);
    CHECK(model.emptyPlaceholderState == 1, "explicit native locked request always wins");
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 3 && model.footerVisibilityStyle == 0 &&
          !model.wantsFooterVisible, "unlocked synthetic Hidden presents native empty without footer");
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 3, "later native content publication stays empty");
    privacy.locked = YES;
    model.contentPrivacyState = 1;
    SetPresentation(model, 1);
    CHECK(model.emptyPlaceholderState == 1 && model.footerVisibilityStyle == 2,
          "relocking restores native protection and footer policy");
    privacy.locked = NO;
    model.contentPrivacyState = 0;
    privacy.assetCollectionToObserve = nil;
    HATestAssetSource *source = [HATestAssetSource new];
    source.containerCollection = hidden;
    model.currentDataSource = source;
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 3 && source.collectionReads == 1,
          "missing observed collection resolves this model's display source");
    for (NSUInteger i = 0; i < 10000; i++) SetPresentation(model, 0);
    CHECK(source.collectionReads == 1, "10000 presentation hits never rescan source identity");
    HATestAssetSource *other = [HATestAssetSource new];
    other.containerCollection = Gadget(@"SYNTHETIC-ORDINARY").testCollection;
    model.currentDataSource = other;
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 0 && model.footerVisibilityStyle == 2,
          "source replacement invalidates Hidden identity and restores footer");
    model.currentDataSource = source;
    SetPresentation(model, 0);
    gHideHiddenAlbum = NO;
    SetPresentation(model, 0);
    CHECK(model.emptyPlaceholderState == 0 && model.footerVisibilityStyle == 2,
          "disabled feature passes through and restores footer");
    CHECK(!privacy.locked && model.currentDataSource == source && source.containerCollection == hidden,
          "synthetic privacy flag and real-source reference never mutated");
    gHideHiddenAlbum = YES;
}

@interface HATestGridView : NSObject
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) NSUInteger hiddenWrites;
@end
@implementation HATestGridView
- (void)setHidden:(BOOL)hidden { _hidden = hidden; _hiddenWrites++; }
@end

@interface HATestPhotosController : NSObject
@property (nonatomic, strong) HATestPhotosModel *viewModel;
@property (nonatomic, strong) HATestGridView *gridView;
@property (nonatomic, getter=isViewLoaded) BOOL viewLoaded;
@property (nonatomic) NSUInteger gridReads;
@property (nonatomic) NSUInteger nativeCalls;
@property (nonatomic, strong) id lastConfiguration;
@property (nonatomic) BOOL nativeUnhidesGrid;
@end
@implementation HATestPhotosController
- (HATestGridView *)gridView { _gridReads++; return _gridView; }
@end

static void TestOriginalUnavailableUpdate(id object, SEL selector, id configuration) {
    (void)selector;
    HATestPhotosController *controller = object;
    controller.nativeCalls++;
    controller.lastConfiguration = configuration;
    if (controller.nativeUnhidesGrid) controller.gridView.hidden = NO;
}

static void RenderPresentation(HATestPhotosController *controller, id configuration) {
    HookedUpdateContentUnavailable(controller,
        NSSelectorFromString(@"_updateContentUnavailableConfigurationUsingState:"), configuration);
}

static void TestHiddenGridPresentation(void) {
    OriginalUpdateContentUnavailable = TestOriginalUnavailableUpdate;
    gHideHiddenAlbum = YES;
    HATestCollection *hidden = Gadget(@"SYNTHETIC-GRID-HIDDEN").testCollection;
    hidden.assetCollectionType = PHAssetCollectionTypeSmartAlbum;
    hidden.assetCollectionSubtype = PHAssetCollectionSubtypeSmartAlbumAllHidden;
    HATestAssetSource *source = [HATestAssetSource new];
    source.containerCollection = hidden;
    HATestPrivacy *privacy = [HATestPrivacy new];
    privacy.locked = YES;
    HATestPhotosModel *model = [HATestPhotosModel new];
    model.privacyController = privacy;
    model.currentDataSource = source;
    model.contentPrivacyState = 1;
    model.emptyPlaceholderState = 1;
    HATestGridView *grid = [HATestGridView new];
    HATestPhotosController *controller = [HATestPhotosController new];
    controller.viewLoaded = YES;
    controller.viewModel = model;
    controller.gridView = grid;
    NSObject *configuration = [NSObject new];
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden && grid.hiddenWrites == 0 && source.collectionReads == 0,
          "locked native grid is not touched or inspected for album identity");
    CHECK(controller.nativeCalls == 1 && controller.lastConfiguration == configuration,
          "native locked configuration receives the original state argument");

    privacy.locked = NO;
    model.contentPrivacyState = 0;
    SetPresentation(model, 0);
    TestOriginalUnavailableUpdate(controller, NULL, configuration);
    CHECK(model.emptyPlaceholderState == 3 && !grid.isHidden,
          "regression: empty publication alone does not suppress nonempty native grid");
    RenderPresentation(controller, configuration);
    CHECK(grid.isHidden && grid.hiddenWrites == 1,
          "unlocked Hidden empty configuration also suppresses the concrete grid");
    NSUInteger reads = source.collectionReads, writes = grid.hiddenWrites;
    NSUInteger calls = controller.nativeCalls;
    for (NSUInteger i = 0; i < 10000; i++) RenderPresentation(controller, configuration);
    CHECK(source.collectionReads == reads && grid.hiddenWrites == writes,
          "10000 grid updates neither rescan identity nor repeat visibility writes");
    CHECK(controller.nativeCalls == calls + 10000 && controller.lastConfiguration == configuration,
          "all cached presentation updates still call native configuration");
    CHECK(!privacy.locked && model.currentDataSource == source,
          "grid suppression never changes native privacy or data source");
    HAHiddenAlbumPresentationState *resolvingState =
        objc_getAssociatedObject(model, &kHiddenPresentationStateKey);
    resolvingState.resolvingCollection = YES;
    RenderPresentation(controller, configuration);
    CHECK(grid.isHidden && grid.hiddenWrites == writes,
          "nested identity resolution does not release an active grid override");
    resolvingState.resolvingCollection = NO;
    calls = controller.nativeCalls;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        RenderPresentation(controller, configuration);
        dispatch_semaphore_signal(completed);
    });
    dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
    CHECK(grid.isHidden && grid.hiddenWrites == writes && controller.nativeCalls == calls + 1,
          "off-main updates call native code without touching grid visibility");

    privacy.locked = YES;
    model.contentPrivacyState = 1;
    SetPresentation(model, 1);
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden && model.emptyPlaceholderState == 1,
          "relocking releases our visibility override and retains native locked state");
    model.emptyPlaceholderState = 3;
    model.contentPrivacyState = 0;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "failed or cancelled authentication cannot trust a stale empty state");
    privacy.locked = NO;
    model.contentPrivacyState = 1;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "stale native privacy state prevents grid override");
    model.contentPrivacyState = 0;
    model.privacyController = nil;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "missing privacy controller cannot activate grid suppression");
    model.privacyController = privacy;
    model.emptyPlaceholderState = 0;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "native content without an empty configuration remains untouched");
    model.emptyPlaceholderState = 2;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "native loading presentation remains untouched");
    model.emptyPlaceholderState = 3;
    RenderPresentation(controller, configuration);
    gHideHiddenAlbum = NO;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "disabling restores the previous grid visibility");
    gHideHiddenAlbum = YES;
    RenderPresentation(controller, configuration);
    privacy.assetCollectionToObserve = Gadget(@"SYNTHETIC-OTHER-GRID").testCollection;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden, "another album releases Hidden grid suppression even if empty");
    privacy.assetCollectionToObserve = hidden;
    RenderPresentation(controller, configuration);
    HATestGridView *replacement = [HATestGridView new];
    controller.gridView = replacement;
    RenderPresentation(controller, configuration);
    CHECK(!grid.isHidden && replacement.isHidden,
          "replacing a grid restores the previous view and suppresses the new one");
    controller.nativeUnhidesGrid = YES;
    RenderPresentation(controller, configuration);
    CHECK(replacement.isHidden, "suppression is applied after native configuration updates");
    controller.nativeUnhidesGrid = NO;
    controller.gridView = nil;
    RenderPresentation(controller, configuration);
    CHECK(!replacement.isHidden &&
          objc_getAssociatedObject(controller, &kHiddenGridPresentationStateKey) == nil,
          "a temporarily absent grid restores and releases the old override");
    controller.gridView = replacement;
    RenderPresentation(controller, configuration);
    controller.viewLoaded = NO;
    reads = controller.gridReads;
    RenderPresentation(controller, configuration);
    CHECK(!replacement.isHidden && controller.gridReads == reads,
          "unloaded controller releases old state without creating or reading a grid");
    controller.viewLoaded = YES;
    replacement.hidden = YES;
    RenderPresentation(controller, configuration);
    gHideHiddenAlbum = NO;
    RenderPresentation(controller, configuration);
    CHECK(replacement.isHidden, "an originally hidden native grid is never forced visible");
    CHECK(objc_getAssociatedObject(controller, &kHiddenGridPresentationStateKey) == nil,
          "inactive presentation releases its weak grid state");
    gHideHiddenAlbum = YES;
}

int main(void) {
    @autoreleasepool {
        TestCacheAndGeometry();
        TestTitles();
        TestHiddenPresentation();
        TestHiddenGridPresentation();
        CHECK(gHookCalls == 0, "test constructor never installed hooks");
        printf("Synthetic cache/presentation tests: %lu assertions, %lu failures; three 10000-hit no-scan checks.\n",
               (unsigned long)gAssertions, (unsigned long)gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
