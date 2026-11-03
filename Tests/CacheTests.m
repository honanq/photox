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
static void HATestSetPreference(CFStringRef key, CFPropertyListRef value, CFStringRef domain);
static Boolean HATestSynchronize(CFStringRef domain);

// All system headers are imported first. Suppress only the source constructor;
// the test includes the actual production functions, not copies of their logic.
#define constructor unused
#define PHAssetCollection HATestCollection
#define PUHorizontalAlbumListGadget HATestAlbumList
#define objc_getClass HATestGetClass
#define CFPreferencesSetAppValue HATestSetPreference
#define CFPreferencesAppSynchronize HATestSynchronize
#define APELIN_PACKAGE_ID "local.apelin.synthetic-cache-tests"
#define APELIN_BUILD_ID "synthetic-test"
#import "../Sources/Tweak.m"
#undef constructor
#undef PHAssetCollection
#undef PUHorizontalAlbumListGadget
#undef objc_getClass
#undef CFPreferencesSetAppValue
#undef CFPreferencesAppSynchronize

static NSUInteger gAssertions;
static NSUInteger gFailures;
static NSUInteger gCollectionReads;
static NSUInteger gHookCalls;
static NSUInteger gWrites;              // Accessed on inventory queue only.
static BOOL gSynchronizationSucceeds = YES;
static NSArray *gSavedInventory;

static void CHECK(BOOL condition, const char *label) {
    gAssertions++;
    if (!condition) { gFailures++; fprintf(stderr, "FAIL: %s\n", label); }
}

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    (void)cls; (void)selector; (void)replacement; (void)original;
    gHookCalls++;
}

static void HATestSetPreference(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    NSCAssert(CFEqual(key, CFSTR("albumInventory")), @"Unexpected test key");
    NSCAssert(CFEqual(domain, CFSTR(APELIN_PACKAGE_ID)), @"Unexpected domain");
    gWrites++;
    gSavedInventory = [(__bridge NSArray *)value copy];
}
static Boolean HATestSynchronize(CFStringRef domain) {
    NSCAssert(CFEqual(domain, CFSTR(APELIN_PACKAGE_ID)), @"Unexpected domain");
    return gSynchronizationSucceeds;
}
static void DrainInventory(void) {
    dispatch_sync(AlbumInventoryQueue(), ^{});
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

static void TestInventory(void) {
    NSObject *providerA = [NSObject new], *providerB = [NSObject new];
    NSArray *albumsA = @[Gadget(@"SYNTHETIC-A"), Gadget(@"SYNTHETIC-B")];
    NSArray *albumsB = @[Gadget(@"SYNTHETIC-C")];
    RecordAlbumsInGadgets(providerA, albumsA);
    DrainInventory();
    CHECK(gWrites == 1 && gSavedInventory.count == 2, "initial synthetic inventory queued once");
    NSUInteger reads = gCollectionReads;
    for (NSUInteger i = 0; i < 10000; i++) RecordAlbumsInGadgets(providerA, albumsA);
    DrainInventory();
    CHECK(gCollectionReads == reads && gWrites == 1, "10000 inventory hits neither rescan nor rewrite");
    RecordAlbumsInGadgets(providerB, albumsB);
    DrainInventory();
    CHECK(gWrites == 2 && gSavedInventory.count == 1, "different provider can publish");
    reads = gCollectionReads;
    RecordAlbumsInGadgets(providerA, albumsA);
    DrainInventory();
    CHECK(gWrites == 3 && gSavedInventory.count == 2 && gCollectionReads == reads,
          "returning cached provider republishes without rescanning");
    RecordAlbumsInGadgets(providerB, @[Gadget(@"SYNTHETIC-A"), Gadget(@"SYNTHETIC-B")]);
    DrainInventory();
    CHECK(gWrites == 3, "equal inventory across providers does not rewrite");
    HAAlbumProviderSnapshot *snapshot = objc_getAssociatedObject(providerB, &kProviderSnapshotKey);
    CHECK(snapshot.inventory == gRequestedInventory, "equal inventory uses canonical cached array");

    gSynchronizationSucceeds = NO;
    NSArray *failed = @[Gadget(@"SYNTHETIC-RETRY")];
    RecordAlbumsInGadgets(providerA, failed);
    DrainInventory();
    CHECK(gWrites == 4, "failed synchronization attempted once");
    // The failure callback is already queued on main. Run assertions after it,
    // without a timer or polling loop, then retry on one explicit provider event.
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            CHECK(gRequestedInventory == nil, "latest failed request invalidates publication cache");
            gSynchronizationSucceeds = YES;
            NSUInteger before = gCollectionReads;
            RecordAlbumsInGadgets(providerA, failed);
            DrainInventory();
            CHECK(gWrites == 5 && gRequestedInventory != nil, "next natural event retries synchronization");
            CHECK(gCollectionReads == before, "retry uses parsed provider inventory");
            CHECK(gHookCalls == 0, "test constructor never installed hooks");
            printf("Synthetic cache tests: %lu assertions, %lu failures; two 10000-hit no-scan checks.\n",
                   (unsigned long)gAssertions, (unsigned long)gFailures);
            exit(gFailures == 0 ? 0 : 1);
        }
    });
}

int main(void) {
    @autoreleasepool {
        TestCacheAndGeometry();
        TestTitles();
        TestInventory();
    }
    dispatch_main();
}
