// SPDX-License-Identifier: MIT
// Synthetic pane lifecycle tests: no Photos, real preferences, or on-screen UI.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <notify.h>
#import <string.h>

static id gInventory;
static NSUInteger gReads;
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

@interface HAPaneTestDefaults : NSObject
- (instancetype)initWithSuiteName:(NSString *)suite;
- (id)objectForKey:(NSString *)key;
@end
@implementation HAPaneTestDefaults
- (instancetype)initWithSuiteName:(NSString *)suite {
    Check([suite isEqualToString:@"local.apelin.synthetic-pane-tests"], "inventory uses package domain");
    return [super init];
}
- (id)objectForKey:(NSString *)key {
    Check([key isEqualToString:@"albumInventory"], "pane reads only the inventory key");
    gReads++;
    return gInventory;
}
@end

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
    for (NSUInteger i = 0; i < 10000; i++) (void)Rows(pane);
    Check(gReads == reads && Rows(pane) == cachedRows, "10000 specifier cache hits do not reread defaults");

    [pane viewWillDisappear:NO];
    reads = gReads;
    gInventory = @[Album(@"SYNTHETIC-B", @"Album B")];
    BecomeActive();
    gInventoryHandler(7);
    Check(gReads == reads, "off-page controller ignores foreground and inventory refresh");
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

int main(void) {
    @autoreleasepool {
        TestValidation();
        TestRefresh();
        printf("Synthetic album pane tests: %lu assertions, %lu failures.\n",
               (unsigned long)gAssertions, (unsigned long)gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
