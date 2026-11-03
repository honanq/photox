// SPDX-License-Identifier: MIT
// The production inventory worker, with in-memory PhotoKit/preferences/notify
// substitutes. Never contacts a real library or reads/writes real preferences.
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <notify.h>
#import <stdatomic.h>

static NSUInteger gQueries, gTitleReads, gWrites, gSignals, gRegistrations, gCancellations;
static BOOL gSyncSucceeds = YES;
static PHAuthorizationStatus gStatus = PHAuthorizationStatusAuthorized;
static NSArray *gAlbumResult, *gSmartResult, *gStored;
static dispatch_block_t gRequest;
static dispatch_semaphore_t gWriteSignal, gSyncStarted, gSyncRelease;
static BOOL gSyncFinished;
static id gLastQueryLibrary;
static NSUInteger gAssertions, gFailures;
static char kMainQueueKey;

static void Check(BOOL passed, const char *message) {
    gAssertions++;
    if (!passed) { gFailures++; fprintf(stderr, "FAIL: %s\n", message); }
}

@interface HAInventoryTestFetchOptions : NSObject
@property (nonatomic, strong) id photoLibrary;
@end
@implementation HAInventoryTestFetchOptions
@end

@interface HAInventoryTestCollection : NSObject
@property (nonatomic, copy) NSString *localIdentifier;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic) PHAssetCollectionSubtype assetCollectionSubtype;
+ (NSArray *)fetchAssetCollectionsWithType:(PHAssetCollectionType)type
                                 subtype:(PHAssetCollectionSubtype)subtype options:(id)options;
@end
@implementation HAInventoryTestCollection
- (NSString *)localizedTitle { gTitleReads++; return _localizedTitle; }
+ (NSArray *)fetchAssetCollectionsWithType:(PHAssetCollectionType)type
                                 subtype:(PHAssetCollectionSubtype)subtype options:(id)options {
    Check(![NSThread isMainThread], "queries stay off main");
    Check(subtype == PHAssetCollectionSubtypeAny &&
          [options isKindOfClass:[HAInventoryTestFetchOptions class]] &&
          [(HAInventoryTestFetchOptions *)options photoLibrary] != nil,
          "every metadata query has explicit library options");
    gLastQueryLibrary = [(HAInventoryTestFetchOptions *)options photoLibrary];
    gQueries++;
    return type == PHAssetCollectionTypeAlbum ? gAlbumResult : gSmartResult;
}
@end

@interface HAInventoryTestDetails : NSObject
@property (nonatomic, strong) NSArray *fetchResultAfterChanges;
@end
@implementation HAInventoryTestDetails
@end

@interface HAInventoryTestChange : NSObject
@property (nonatomic, strong) NSArray *beforeAlbums;
@property (nonatomic, strong) NSArray *beforeSmart;
@property (nonatomic, strong) HAInventoryTestDetails *albums;
@property (nonatomic, strong) HAInventoryTestDetails *smart;
- (HAInventoryTestDetails *)changeDetailsForFetchResult:(NSArray *)result;
@end
@implementation HAInventoryTestChange
- (HAInventoryTestDetails *)changeDetailsForFetchResult:(NSArray *)result {
    if (result == self.beforeAlbums) return self.albums;
    if (result == self.beforeSmart) return self.smart;
    return nil;
}
@end

@protocol HAInventoryTestObserver <NSObject>
- (void)photoLibraryDidChange:(HAInventoryTestChange *)change;
@end

@interface HAInventoryTestLibrary : NSObject
@property (nonatomic, strong) NSError *unavailabilityReason;
@property (nonatomic, weak) id observer;
@property (nonatomic) NSUInteger unregisters;
+ (instancetype)sharedPhotoLibrary;
+ (instancetype)px_appPhotoLibrary;
+ (PHAuthorizationStatus)authorizationStatusForAccessLevel:(PHAccessLevel)level;
- (void)registerChangeObserver:(id)observer;
- (void)unregisterChangeObserver:(id)observer;
@end
static HAInventoryTestLibrary *gAppLibrary;
static BOOL gAppContextAvailable = YES;
@implementation HAInventoryTestLibrary
+ (instancetype)sharedPhotoLibrary {
    static HAInventoryTestLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = [self new]; });
    return library;
}
+ (instancetype)px_appPhotoLibrary {
    return gAppContextAvailable ? (gAppLibrary ?: [self sharedPhotoLibrary]) : nil;
}
+ (PHAuthorizationStatus)authorizationStatusForAccessLevel:(PHAccessLevel)level {
    Check(level == PHAccessLevelReadWrite, "never asks for authorization");
    return gStatus;
}
- (void)registerChangeObserver:(id)observer { self.observer = observer; gRegistrations++; }
- (void)unregisterChangeObserver:(id)observer {
    Check(observer == self.observer, "unregister own observer");
    self.observer = nil;
    self.unregisters++;
}
@end

static void TestSet(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    Check(CFEqual(key, CFSTR("albumInventory")) &&
          CFEqual(domain, CFSTR("local.apelin.synthetic-inventory")), "writes only test inventory");
    Check(![NSThread isMainThread], "writes stay off main");
    gWrites++;
    gStored = [(__bridge NSArray *)value copy];
}
static Boolean TestSync(CFStringRef domain) {
    Check(CFEqual(domain, CFSTR("local.apelin.synthetic-inventory")), "synchronize test domain");
    if (gSyncStarted != nil) {
        dispatch_semaphore_signal(gSyncStarted);
        long result = dispatch_semaphore_wait(gSyncRelease,
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        Check(result == 0, "in-flight synchronization is released by the test");
        gSyncFinished = YES;
    }
    return gSyncSucceeds;
}
static uint32_t TestNotify(const char *name) {
    Check(strcmp(name, "local.apelin.synthetic-inventory/inventoryChanged") == 0,
          "only successful response signal");
    gSignals++;
    if (gWriteSignal != nil) dispatch_semaphore_signal(gWriteSignal);
    return NOTIFY_STATUS_OK;
}
static uint32_t TestRegister(const char *name, int *token, dispatch_queue_t queue,
                             notify_handler_t handler) {
    Check(strcmp(name, "local.apelin.synthetic-inventory/inventoryRequest") == 0,
          "request and response have different names");
    *token = 17;
    gRequest = ^{ dispatch_async(queue, ^{ handler(17); }); };
    return NOTIFY_STATUS_OK;
}
static uint32_t TestCancel(int token) {
    Check(token == 17, "cancel own request listener");
    gCancellations++;
    gRequest = nil;
    return NOTIFY_STATUS_OK;
}

#define PHPhotoLibrary HAInventoryTestLibrary
#define PHFetchOptions HAInventoryTestFetchOptions
#define PHPhotoLibraryChangeObserver HAInventoryTestObserver
#define PHAssetCollection HAInventoryTestCollection
#define PHFetchResult NSArray
#define PHFetchResultChangeDetails HAInventoryTestDetails
#define PHChange HAInventoryTestChange
#define CFPreferencesSetAppValue TestSet
#define CFPreferencesAppSynchronize TestSync
#define notify_post TestNotify
#define notify_register_dispatch TestRegister
#define notify_cancel TestCancel
#define APELIN_PACKAGE_ID "local.apelin.synthetic-inventory"
#import "../Sources/HAAlbumInventory.m"
#undef PHPhotoLibrary
#undef PHFetchOptions
#undef PHPhotoLibraryChangeObserver
#undef PHAssetCollection
#undef PHFetchResult
#undef PHFetchResultChangeDetails
#undef PHChange
#undef CFPreferencesSetAppValue
#undef CFPreferencesAppSynchronize
#undef notify_post
#undef notify_register_dispatch
#undef notify_cancel

static HAInventoryTestCollection *Album(NSString *identifier, NSString *title) {
    HAInventoryTestCollection *album = [HAInventoryTestCollection new];
    album.localIdentifier = identifier;
    album.localizedTitle = title;
    album.assetCollectionSubtype = PHAssetCollectionSubtypeSmartAlbumFavorites;
    return album;
}
static void Refresh(HAAlbumInventoryWorker *worker) {
    dispatch_sync(worker.queue, ^{ [worker refreshOnQueue]; });
}
static void Drain(HAAlbumInventoryWorker *worker) { dispatch_sync(worker.queue, ^{}); }
static void Change(HAAlbumInventoryWorker *worker, NSArray *albums, NSArray *smart) {
    HAInventoryTestChange *change = [HAInventoryTestChange new];
    change.beforeAlbums = worker.albums;
    change.beforeSmart = worker.smartAlbums;
    if (albums != nil) {
        change.albums = [HAInventoryTestDetails new];
        change.albums.fetchResultAfterChanges = albums;
    }
    if (smart != nil) {
        change.smart = [HAInventoryTestDetails new];
        change.smart.fetchResultAfterChanges = smart;
    }
    [worker photoLibraryDidChange:change];
    Drain(worker);
}
static void WaitForWrite(HAAlbumInventoryWorker *worker) {
    long result = dispatch_semaphore_wait(gWriteSignal,
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    Check(result == 0, "event produces a write without a timer or polling");
    Drain(worker);
    gWriteSignal = nil;
}

static void RunTests(void) {
    HAAlbumInventoryWorker *worker = [HAAlbumInventoryWorker new];
    HAInventoryTestLibrary *library = [HAInventoryTestLibrary sharedPhotoLibrary];
    gAlbumResult = @[Album(@"B", @"Beta"), Album(@"A", @"Alpha")];
    gSmartResult = @[Album(@"S", @"Smart"), Album(@"A", @"Alpha")];
    Check(gQueries == 0, "constructor never opens library");
    for (NSUInteger status = PHAuthorizationStatusNotDetermined;
         status <= PHAuthorizationStatusLimited; status++) {
        if (status == PHAuthorizationStatusAuthorized) continue;
        gStatus = status;
        Refresh(worker);
    }
    Check(gQueries == 0 && gWrites == 0, "unauthorized status never queries or erases cache");
    gStatus = PHAuthorizationStatusAuthorized;
    library.unavailabilityReason = [NSError errorWithDomain:@"synthetic" code:1 userInfo:nil];
    Refresh(worker);
    Check(gQueries == 0 && gWrites == 0, "unavailable library preserves cache");
    library.unavailabilityReason = nil;
    gAppContextAvailable = NO;
    Refresh(worker);
    Check(gQueries == 0 && gWrites == 0, "missing app context never falls back to an implicit library");
    gAppContextAvailable = YES;
    Refresh(worker);
    Check(gQueries == 2 && gRegistrations == 1 && gWrites == 1 && gSignals == 1,
          "startup queries ordinary and smart metadata independently of UI");
    Check(gStored.count == 3 && [gStored[0][@"id"] isEqual:@"A"],
          "metadata is deduplicated and stably sorted");
    Refresh(worker);
    Check(gWrites == 1 && gRegistrations == 1, "unchanged lifecycle refresh never rewrites or reregisters");
    NSUInteger queries = gQueries, reads = gTitleReads;
    for (NSUInteger i = 0; i < 10000; i++) {
        [worker photoLibraryDidChange:[HAInventoryTestChange new]];
    }
    Drain(worker);
    Check(gQueries == queries && gTitleReads == reads && gWrites == 1,
          "10000 unrelated asset events do not query, rescan or write");

    Change(worker, @[Album(@"B", @"Renamed")], nil);
    Check(gQueries == queries && gWrites == 2 && gStored.count == 3,
          "album rename consumes change result without a new query");
    Change(worker, @[], @[]);
    Check(gStored.count == 0 && gWrites == 3, "authoritative empty results clear deleted albums");
    gAlbumResult = nil;
    Refresh(worker);
    Check(gWrites == 3, "nil fetch never clears successful snapshot");
    gAlbumResult = @[Album(nil, @"Pending")];
    Refresh(worker);
    Check(gWrites == 3, "unready identifier never publishes partial inventory");
    reads = gTitleReads;
    queries = gQueries;
    for (NSUInteger i = 0; i < 10000; i++) {
        [worker photoLibraryDidChange:[HAInventoryTestChange new]];
    }
    Drain(worker);
    Check(gTitleReads == reads && gQueries == queries && gWrites == 3,
          "10000 unrelated events never rescan incomplete metadata");
    gAlbumResult = @[Album(@"P", @"Ready")];
    gSmartResult = @[];
    Refresh(worker);
    Check(gWrites == 4 && [gStored[0][@"id"] isEqual:@"P"], "next lifecycle event recovers metadata");

    NSUInteger signals = gSignals;
    gSyncSucceeds = NO;
    gAlbumResult = @[Album(@"F", @"Failed")];
    Refresh(worker);
    Check(gWrites == 5 && gSignals == signals && worker.published == nil,
          "failed synchronization cannot signal or poison dedup cache");
    gSyncSucceeds = YES;
    queries = gQueries;
    reads = gTitleReads;
    Change(worker, nil, nil);
    Check(gWrites == 6 && gSignals == signals + 1 && gQueries == queries && gTitleReads == reads,
          "next library event retries failed publication without a query or rescan");
    gSyncSucceeds = NO;
    gAlbumResult = @[Album(@"X", @"Unsaved")];
    Refresh(worker);
    gSyncSucceeds = YES;
    gAlbumResult = @[Album(@"F", @"Failed")];
    Refresh(worker);
    Check(gWrites == 8 && [gStored[0][@"id"] isEqual:@"F"],
          "returning to prior successful content overwrites failed in-memory value");

    gAlbumResult = @[Album(@"UNTITLED", nil)];
    HAInventoryTestCollection *unsupported = Album(@"UTILITY", @"Utility");
    unsupported.assetCollectionSubtype = PHAssetCollectionSubtypeSmartAlbumVideos;
    gSmartResult = @[unsupported];
    Refresh(worker);
    Check(gStored.count == 1 && [gStored[0][@"title"] isEqual:@"未命名相簿"],
          "nil title gets a safe label and unsupported smart cards are excluded");
    gAlbumResult = @[Album(@"UNTITLED", @"Recovered title")];
    Refresh(worker);
    gAlbumResult = @[Album(@"UNTITLED", nil)];
    Refresh(worker);
    Check([gStored[0][@"title"] isEqual:@"Recovered title"],
          "temporarily missing title retains the last known label");
    gSmartResult = @[];

    queries = gQueries;
    gAlbumResult = @[Album(@"BURST", @"Burst")];
    gWriteSignal = dispatch_semaphore_create(0);
    dispatch_suspend(worker.queue);
    for (NSUInteger i = 0; i < 10000; i++) [worker requestRefresh];
    dispatch_resume(worker.queue);
    WaitForWrite(worker);
    Check(gQueries == queries + 2 && [gStored[0][@"id"] isEqual:@"BURST"],
          "10000 queued refresh requests merge into one pair of metadata fetches");
    gAlbumResult = @[Album(@"REQUEST", @"Request")];
    gWriteSignal = dispatch_semaphore_create(0);
    gRequest();
    WaitForWrite(worker);
    Check([gStored[0][@"id"] isEqual:@"REQUEST"], "pane request refreshes a running reader");

    HAInventoryTestLibrary *replacement = [HAInventoryTestLibrary new];
    gAppLibrary = replacement;
    Refresh(worker);
    Check(library.unregisters == 1 && worker.library == replacement &&
          gRegistrations == 2 && gLastQueryLibrary == replacement,
          "library switch moves observer and binds every fetch to the new context");
    library = replacement;
    queries = gQueries;
    NSUInteger writes = gWrites;
    gAlbumResult = @[Album(@"DRAIN", @"In flight")];
    gSyncStarted = dispatch_semaphore_create(0);
    gSyncRelease = dispatch_semaphore_create(0);
    [worker requestRefresh];
    Check(dispatch_semaphore_wait(gSyncStarted,
              dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
          "stop test begins during an actual in-flight synchronization");
    [worker stopWithCompletion:^{
        Check(gSyncFinished, "stop completion waits until in-flight synchronization finishes");
        Check(dispatch_get_specific(&kMainQueueKey) == &kMainQueueKey,
              "stop completion returns to main queue after draining");
        [worker requestRefresh];
        [worker photoLibraryDidChange:[HAInventoryTestChange new]];
        Drain(worker);
        Check(gQueries == queries + 2 && gWrites == writes + 1, "stopped reader rejects new work");
        Check(gCancellations == 1 && library.unregisters == 1, "stop releases both observers");
        printf("Synthetic inventory tests: %lu assertions, %lu failures; three 10000-event checks.\n",
               (unsigned long)gAssertions, (unsigned long)gFailures);
        exit(gFailures == 0 ? 0 : 1);
    }];
    dispatch_semaphore_signal(gSyncRelease);
}

int main(void) {
    dispatch_queue_set_specific(dispatch_get_main_queue(), &kMainQueueKey, &kMainQueueKey, NULL);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { RunTests(); }
    });
    dispatch_main();
}
