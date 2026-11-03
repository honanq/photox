// SPDX-License-Identifier: MIT
// Synthetic pane lifecycle tests: no Photos, real preferences, or on-screen UI.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <notify.h>
#import <string.h>

static id gInventory;             // Synthetic persistent storage, never a real domain.
static id gSynchronizedInventory; // Simulated process cache; refreshed only by the stub.
static BOOL gSynchronizationSucceeds = YES;
static BOOL gLastSynchronizationSucceeded;
static NSUInteger gSynchronizations;
static NSUInteger gReads;
static NSUInteger gRequests;
static NSUInteger gReadsAtLastRequest;
static NSMutableArray<NSString *> *gEvents;
static NSUInteger gReloads;
static NSUInteger gAssertions;
static NSUInteger gFailures;

static void Check(BOOL condition, const char *label) {
    gAssertions++;
    if (!condition) {
        gFailures++;
        fprintf(stderr, "FAIL: %s\n", label);
    }
}

// All preference APIs in the imported source are redirected below. Keeping a
// suite trap as well prevents a future NSUserDefaults regression from reaching
// real storage while these tests exercise the CFPreferences route.
@interface HAPaneTestDefaults : NSObject
- (instancetype)initWithSuiteName:(NSString *)suite;
- (id)objectForKey:(NSString *)key;
@end
@implementation HAPaneTestDefaults
- (instancetype)initWithSuiteName:(NSString *)suite {
    (void)suite;
    Check(NO, "pane inventory must use the explicitly synchronized CF channel");
    return [super init];
}
- (id)objectForKey:(NSString *)key {
    (void)key;
    Check(NO, "suite cache must not replace the synchronized inventory read");
    return nil;
}
@end

static Boolean HAPaneSynchronize(CFStringRef domain) {
    Check(CFEqual(domain, CFSTR("local.apelin.synthetic-pane-tests")), "synchronize uses writer's App domain");
    gSynchronizations++;
    [gEvents addObject:@"sync"];
    gLastSynchronizationSucceeded = gSynchronizationSucceeds;
    if (gSynchronizationSucceeds) {
        gSynchronizedInventory = gInventory;
    }
    return gSynchronizationSucceeds;
}
static CFPropertyListRef HAPaneCopyAppValue(CFStringRef key, CFStringRef domain) {
    Check(CFEqual(domain, CFSTR("local.apelin.synthetic-pane-tests")), "copy uses writer's App domain");
    Check(CFEqual(key, CFSTR("albumInventory")), "pane reads only the inventory key");
    Check(gLastSynchronizationSucceeded, "copy follows a successful event-boundary synchronization");
    gReads++;
    [gEvents addObject:@"read"];
    return gSynchronizedInventory == nil ? NULL : CFBridgingRetain(gSynchronizedInventory);
}

@interface HAPaneTestSpecifier : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableDictionary *properties;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target
    set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end
@implementation HAPaneTestSpecifier
+ (instancetype)groupSpecifierWithName:(NSString *)name {
    HAPaneTestSpecifier *row = [self new];
    row.name = name;
    row.properties = [NSMutableDictionary dictionary];
    return row;
}
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target
    set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit {
    (void)target; (void)detail; (void)edit;
    Check(cell == PSSwitchCell, "album produces a switch row");
    Check(set == @selector(setPreferenceValue:specifier:), "native preference writer retained");
    Check(get == @selector(readPreferenceValue:), "native preference reader retained");
    return [self groupSpecifierWithName:name];
}
- (void)setProperty:(id)value forKey:(NSString *)key { self.properties[key] = value; }
@end

@interface HAPaneTestListController : NSObject {
@protected
    NSMutableArray *_specifiers;
}
@property (nonatomic, copy) NSString *title;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (id)readPreferenceValue:(id)specifier;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end
@implementation HAPaneTestListController
- (NSArray *)specifiers { return _specifiers; }
- (void)reloadSpecifiers { gReloads++; (void)[self specifiers]; }
- (void)viewDidLoad {}
- (void)viewWillAppear:(BOOL)animated { (void)animated; }
- (void)viewWillDisappear:(BOOL)animated { (void)animated; }
- (id)readPreferenceValue:(id)specifier { (void)specifier; return nil; }
- (void)setPreferenceValue:(id)value specifier:(id)specifier { (void)value; (void)specifier; }
@end

static void (^gInventoryHandler)(int);
static NSUInteger gNotifyRegistrations;
static NSUInteger gNotifyCancellations;
static BOOL gReplyToRequest;
static id gInventoryPublishedOnRequest;
static BOOL gInsideRequest;
static uint32_t HAPanePost(const char *name) {
    Check(strcmp(name, "local.apelin.synthetic-pane-tests/inventoryRequest") == 0,
          "page posts only its inventory request signal");
    gRequests++;
    gReadsAtLastRequest = gReads;
    [gEvents addObject:@"request"];
    if (gReplyToRequest && gInventoryHandler != nil) {
        if (gInsideRequest) {
            Check(NO, "an inventory response must not generate another request");
            return NOTIFY_STATUS_OK;
        }
        gInsideRequest = YES;
        gInventory = gInventoryPublishedOnRequest;
        gInventoryHandler(7);
        gInsideRequest = NO;
    }
    return NOTIFY_STATUS_OK;
}
static uint32_t HAPaneRegister(const char *name, int *token, dispatch_queue_t queue,
                              void (^handler)(int)) {
    (void)queue;
    Check(strcmp(name, "local.apelin.synthetic-pane-tests/inventoryChanged") == 0,
          "pane uses independent inventory signal");
    *token = 7;
    gNotifyRegistrations++;
    gInventoryHandler = [handler copy];
    return NOTIFY_STATUS_OK;
}
static uint32_t HAPaneCancel(int token) {
    Check(token == 7, "pane cancels its own inventory token");
    gNotifyCancellations++;
    gInventoryHandler = nil;
    return NOTIFY_STATUS_OK;
}

// Import the production controller unchanged, with only its framework/storage
// collaborators replaced. No UIKit controller or real preference domain is used.
#define notify_register_dispatch HAPaneRegister
#define notify_cancel HAPaneCancel
#define notify_post HAPanePost
#define CFPreferencesAppSynchronize HAPaneSynchronize
#define CFPreferencesCopyAppValue HAPaneCopyAppValue
#define PSListController HAPaneTestListController
#define PSSpecifier HAPaneTestSpecifier
#define NSUserDefaults HAPaneTestDefaults
#define APELIN_PACKAGE_ID "local.apelin.synthetic-pane-tests"
#import "../PreferenceBundle/Sources/HiddenAlbumAlbumsController.m"
#undef PSListController
#undef PSSpecifier
#undef NSUserDefaults
#undef notify_register_dispatch
#undef notify_cancel
#undef notify_post
#undef CFPreferencesAppSynchronize
#undef CFPreferencesCopyAppValue

static NSDictionary *Album(NSString *identifier, NSString *title) {
    return @{ @"id": identifier, @"title": title };
}
static NSArray *Rows(HiddenAlbumAlbumsController *pane) { return [pane specifiers]; }
static HAPaneTestSpecifier *Row(HiddenAlbumAlbumsController *pane, NSUInteger index) {
    return Rows(pane)[index];
}
static void BecomeActive(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
}

static void TestValidation(void) {
    for (id invalid in @[@"not-an-array", @42, @{}, [NSNull null]]) {
        gInventory = invalid;
        HiddenAlbumAlbumsController *pane = [HiddenAlbumAlbumsController new];
        @try {
            Check(Rows(pane).count == 2, "invalid outer value renders the empty state");
            Check(Row(pane, 1).properties[@"footerText"] != nil, "empty state includes guidance");
        } @catch (NSException *exception) {
            (void)exception;
            Check(NO, "invalid outer inventory must not throw");
        }
    }
    gInventory = @[[NSNull null], @"invalid-entry", @7, @{},
        @{@"id": @7, @"title": @"invalid-id"},
        @{@"id": @"invalid-title", @"title": @9},
        Album(@"", @"empty-id"), Album(@"empty-title", @""),
        Album(@"SYNTHETIC-A", @"Album A"), Album(@"SYNTHETIC-A", @"Duplicate")];
    HiddenAlbumAlbumsController *pane = [HiddenAlbumAlbumsController new];
    @try {
        Check(Rows(pane).count == 2, "malformed and duplicate entries are omitted");
        HAPaneTestSpecifier *row = Row(pane, 1);
        Check([row.name isEqualToString:@"Album A"], "first valid album title retained");
        Check([row.properties[@"key"] isEqualToString:@"hide.SYNTHETIC-A"], "identifier maps to the same preference key");
        Check([row.properties[@"defaults"] isEqualToString:@APELIN_PACKAGE_ID], "switch uses original domain");
        Check([row.properties[@"default"] isEqual:@NO], "switch default remains off");
        Check([row.properties[@"PostNotification"] isEqualToString:@APELIN_PACKAGE_ID @"/changed"], "switch retains setting notification");
    } @catch (NSException *exception) {
        (void)exception;
        Check(NO, "malformed inventory elements must not throw");
    }
    gInventory = @[@{}, Album(@"", @"invalid")];
    pane = [HiddenAlbumAlbumsController new];
    @try {
        Check(Rows(pane).count == 2 && Row(pane, 1).properties[@"footerText"] != nil,
              "all-invalid array also renders the empty state");
    } @catch (NSException *exception) {
        (void)exception;
        Check(NO, "all-invalid inventory must not throw");
    }
    // Ownership is independent of a caller's mutable dictionary/strings.
    NSMutableString *identifier = [@"SYNTHETIC-MUTABLE" mutableCopy];
    NSMutableString *title = [@"Original" mutableCopy];
    NSArray *validated = HAValidatedAlbumInventory(@[Album(identifier, title)]);
    [identifier appendString:@"-CHANGED"];
    [title appendString:@"-CHANGED"];
    Check([validated[0][@"id"] isEqualToString:@"SYNTHETIC-MUTABLE"], "validated identifier owns immutable snapshot");
    Check([validated[0][@"title"] isEqualToString:@"Original"], "validated title owns immutable snapshot");
    Check(HAValidatedAlbumInventory(nil) == nil, "missing outer value is unavailable, not an explicit empty inventory");
    Check(HAValidatedAlbumInventory(@[@{}, @42]) == nil, "wholly malformed nonempty array is unavailable, not empty");
    Check([HAValidatedAlbumInventory(@[]) isEqualToArray:@[]], "valid empty array remains an explicit empty inventory");
}

static void TestRefresh(void) {
    gInventory = nil;
    HiddenAlbumAlbumsController *pane = [HiddenAlbumAlbumsController new];
    [pane viewDidLoad];
    [pane viewWillAppear:NO];
    Check(Rows(pane).count == 2, "first display can be empty");
    gInventory = @[Album(@"SYNTHETIC-A", @"Album A")];
    NSUInteger before = gReloads;
    BecomeActive();
    Check(gReloads == before + 1, "foreground event invalidates stale rows");
    Check([Row(pane, 1).name isEqualToString:@"Album A"], "foreground event replaces initial empty state");
    Check(gNotifyRegistrations == 1 && gInventoryHandler != nil,
          "inventory observer registers once");
    [pane viewDidLoad];
    Check(gNotifyRegistrations == 1, "view reload never duplicates inventory listener");
    gInventory = @[Album(@"SYNTHETIC-A", @"Signal A")];
    gInventoryHandler(7);
    Check([Row(pane, 1).name isEqualToString:@"Signal A"], "inventory signal refreshes visible page");
    gInventory = @[Album(@"SYNTHETIC-A", @"Album A")];
    gInventoryHandler(7);

    NSArray *cachedRows = Rows(pane);
    before = gReloads;
    gInventory = @[Album(@"SYNTHETIC-A", @"Album A")];
    BecomeActive();
    [pane viewWillAppear:NO];
    Check(gReloads == before && Rows(pane) == cachedRows, "equal inventory does not rebuild rows");
    NSUInteger reads = gReads;
    NSUInteger synchronizations = gSynchronizations;
    NSUInteger requests = gRequests;
    for (NSUInteger i = 0; i < 10000; i++) (void)Rows(pane);
    Check(gReads == reads && Rows(pane) == cachedRows, "10000 specifier cache hits do not reread preferences");
    Check(gSynchronizations == synchronizations && gRequests == requests,
          "10000 specifier cache hits do not synchronize or request inventory");

    [pane viewWillDisappear:NO];
    reads = gReads;
    synchronizations = gSynchronizations;
    requests = gRequests;
    gInventory = @[Album(@"SYNTHETIC-B", @"Album B")];
    BecomeActive();
    gInventoryHandler(7);
    Check(gReads == reads, "off-page controller ignores foreground and inventory refresh");
    Check(gSynchronizations == synchronizations && gRequests == requests,
          "off-page events do not synchronize or request inventory");
    [pane viewWillAppear:NO];
    Check([Row(pane, 1).name isEqualToString:@"Album B"], "reopening refreshes reused controller");

    gInventory = @[Album(@"SYNTHETIC-B", @"Renamed B"), Album(@"SYNTHETIC-A", @"Album A")];
    BecomeActive();
    Check(Rows(pane).count == 3 && [Row(pane, 1).name isEqualToString:@"Renamed B"], "rename and count change refresh the list");
    gInventory = @[Album(@"SYNTHETIC-A", @"Album A"), Album(@"SYNTHETIC-B", @"Renamed B")];
    BecomeActive();
    Check([Row(pane, 1).name isEqualToString:@"Album A"], "same-count reorder refreshes the list");
    gInventory = @[];
    BecomeActive();
    Check(Rows(pane).count == 2 && Row(pane, 1).properties[@"footerText"] != nil, "valid empty update removes old switches");

    __weak id weakPane = pane;
    pane = nil;
    Check(weakPane == nil, "event observers do not retain the controller");
    Check(gNotifyCancellations == 1 && gInventoryHandler == nil,
          "deallocation cancels inventory listener");
    BecomeActive();
}

static void TestPersistentCacheAndFailures(void) {
    // Simulate a stale process cache without touching cfprefsd or a real plist.
    gSynchronizedInventory = @[Album(@"SYNTHETIC-STALE", @"Stale cache")];
    gInventory = @[Album(@"SYNTHETIC-SAVED", @"Saved inventory")];
    [gEvents removeAllObjects];
    NSUInteger requests = gRequests;
    HiddenAlbumAlbumsController *pane = [HiddenAlbumAlbumsController new];
    [pane viewDidLoad];
    Check([Row(pane, 1).name isEqualToString:@"Saved inventory"], "first rendering uses persisted inventory without a Photos reply");
    Check([gEvents isEqualToArray:@[@"sync", @"read"]], "first rendering synchronizes before reading the persisted inventory");
    Check(gRequests == requests, "specifier rendering alone never requests or launches Photos");
    NSString *footer = Row(pane, 0).properties[@"footerText"];
    Check([footer containsString:@"自动更新"] && [footer containsString:@"上次保存"], "footer explains automatic updates and retained cached results");

    NSArray *cachedRows = Rows(pane);
    [gEvents removeAllObjects];
    [pane viewWillAppear:NO];
    Check([gEvents isEqualToArray:@[@"sync", @"read", @"request"]], "appearance reads saved inventory before posting a request");
    Check(Rows(pane) == cachedRows, "a request with no Photos responder keeps cached rows available");
    Check(gRequests == requests + 1 && gReadsAtLastRequest == gReads, "appearance posts one request after the read");

    gInventory = @[Album(@"SYNTHETIC-FRESH", @"Fresh inventory")];
    Check([Row(pane, 1).name isEqualToString:@"Saved inventory"], "specifier cache does not silently reread changed storage");
    [gEvents removeAllObjects];
    BecomeActive();
    Check([gEvents isEqualToArray:@[@"sync", @"read", @"request"]], "visible foreground synchronizes and reads before requesting");
    Check([Row(pane, 1).name isEqualToString:@"Fresh inventory"], "event boundary invalidates a stale process preference cache");
    cachedRows = Rows(pane);
    NSArray *cachedInventory = pane.ha_albumInventory;
    NSUInteger reloads = gReloads;
    requests = gRequests;
    for (id malformed in @[[NSNull null], @"broken", @{}, @42, @[@{}, @42]]) {
        gInventory = malformed == [NSNull null] ? nil : malformed;
        [gEvents removeAllObjects];
        gInventoryHandler(7);
        Check(pane.ha_albumInventory == cachedInventory && Rows(pane) == cachedRows,
              "missing or malformed outer data preserves the last valid snapshot and rows");
        Check(gReloads == reloads && gRequests == requests,
              "unavailable response neither reloads rows nor echoes an inventory request");
        Check([gEvents isEqualToArray:@[@"sync", @"read"]], "inventoryChanged only synchronizes and reads");
    }

    gInventory = @[Album(@"SYNTHETIC-UNSAVED", @"Must not replace cache")];
    gSynchronizationSucceeds = NO;
    NSUInteger reads = gReads;
    [gEvents removeAllObjects];
    gInventoryHandler(7);
    Check([gEvents isEqualToArray:@[@"sync"]] && gReads == reads,
          "failed synchronization never copies a potentially stale preference value");
    Check(Rows(pane) == cachedRows && pane.ha_albumInventory == cachedInventory && gReloads == reloads,
          "failed synchronization preserves cached inventory without rebuilding");
    [gEvents removeAllObjects];
    BecomeActive();
    Check([gEvents isEqualToArray:@[@"sync", @"request"]] && gReads == reads,
          "foreground still requests a retry when persisted cache synchronization fails");
    Check(Rows(pane) == cachedRows, "failed foreground synchronization keeps visible cached rows");
    gSynchronizationSucceeds = YES;
    gInventory = @[Album(@"SYNTHETIC-RECOVERED", @"Recovered")];
    gInventoryHandler(7);
    Check([Row(pane, 1).name isEqualToString:@"Recovered"], "later natural response recovers from a synchronization failure");

    requests = gRequests;
    gInventory = @[];
    gInventoryHandler(7);
    Check([pane.ha_albumInventory isEqualToArray:@[]] && Rows(pane).count == 2,
          "explicit valid empty response removes cached album switches");
    Check([Row(pane, 1).properties[@"footerText"] containsString:@"当前没有"],
          "valid empty inventory is distinguished from missing first-time inventory");
    Check(gRequests == requests, "even an empty inventory response never requests again");
    [pane viewWillDisappear:NO];
}

static void TestRequestResponseDoesNotEcho(void) {
    gInventory = @[Album(@"SYNTHETIC-SAVED", @"Saved")];
    gReplyToRequest = YES;
    gInventoryPublishedOnRequest = @[Album(@"SYNTHETIC-RESPONSE", @"Response")];
    HiddenAlbumAlbumsController *pane = [HiddenAlbumAlbumsController new];
    [pane viewDidLoad];
    NSUInteger requests = gRequests;
    [gEvents removeAllObjects];
    [pane viewWillAppear:NO];
    Check(gRequests == requests + 1, "appearance plus synchronous response emits only one request");
    Check([gEvents isEqualToArray:@[@"sync", @"read", @"request", @"sync", @"read"]],
          "request response only rereads persisted inventory without a signal loop");
    Check([Row(pane, 1).name isEqualToString:@"Response"], "response refreshes the same visible controller");
    Check(gReads == gReadsAtLastRequest + 1, "the response adds precisely one synchronized read");

    gInventoryPublishedOnRequest = @[Album(@"SYNTHETIC-RESPONSE", @"Foreground response")];
    requests = gRequests;
    BecomeActive();
    Check(gRequests == requests + 1 && [Row(pane, 1).name isEqualToString:@"Foreground response"],
          "visible foreground also requests only once with immediate response");
    [pane viewWillDisappear:NO];
    NSUInteger reads = gReads;
    NSUInteger synchronizations = gSynchronizations;
    requests = gRequests;
    BecomeActive();
    gInventoryHandler(7);
    Check(gRequests == requests && gReads == reads && gSynchronizations == synchronizations,
          "hidden page neither requests nor reads even with an installed responder");
    gReplyToRequest = NO;
    gInventoryPublishedOnRequest = nil;
    __weak id weakPane = pane;
    pane = nil;
    Check(weakPane == nil && gInventoryHandler == nil, "response listener remains weak and cancels on controller release");
}

int main(void) {
    @autoreleasepool {
        gEvents = [NSMutableArray array];
        TestValidation();
        TestRefresh();
        TestPersistentCacheAndFailures();
        TestRequestResponseDoesNotEcho();
        printf("Synthetic album pane tests: %lu assertions, %lu failures.\n",
               (unsigned long)gAssertions, (unsigned long)gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
