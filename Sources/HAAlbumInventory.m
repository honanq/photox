// SPDX-License-Identifier: MIT
#import "HAAlbumInventory.h"
#import <Photos/Photos.h>
#import <notify.h>
#import <stdatomic.h>

// Photos runs in multi-library mode. Never use an implicit singleton library
// or nil fetch options: bind queries to the host's own current library.
@interface PHPhotoLibrary (HAInventoryContext)
+ (PHPhotoLibrary *)px_appPhotoLibrary;
@end
@interface PHFetchOptions (HAInventoryContext)
@property (nonatomic, strong) PHPhotoLibrary *photoLibrary;
@end

// Photos alone owns this reader. It fetches collection identifiers/titles, never
// assets, counts, thumbnails or authentication state. Settings reads the cache.
@interface HAAlbumInventoryWorker : NSObject <PHPhotoLibraryChangeObserver> {
    atomic_bool _stopping;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t refreshSource;
@property (nonatomic, strong) PHPhotoLibrary *library;
@property (nonatomic, strong) PHFetchResult<PHAssetCollection *> *albums;
@property (nonatomic, strong) PHFetchResult<PHAssetCollection *> *smartAlbums;
@property (nonatomic, copy) NSArray<NSDictionary *> *candidate;
@property (nonatomic, copy) NSArray<NSDictionary *> *published;
@property (nonatomic) int requestToken;
- (void)requestRefresh;
- (void)refreshOnQueue;
- (void)rebuildOnQueue;
- (void)publishOnQueue;
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end

@implementation HAAlbumInventoryWorker

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_stopping, false);
        _requestToken = -1;
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attributes = dispatch_queue_attr_make_with_qos_class(attributes, QOS_CLASS_UTILITY, 0);
        _queue = dispatch_queue_create(APELIN_PACKAGE_ID ".inventory", attributes);
        _refreshSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, _queue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_refreshSource, ^{
            [weakSelf refreshOnQueue];
        });
        dispatch_resume(_refreshSource);
        int token = -1;
        if (notify_register_dispatch(APELIN_PACKAGE_ID "/inventoryRequest", &token, _queue,
                ^(int deliveredToken) {
                    (void)deliveredToken;
                    [weakSelf requestRefresh];
                }) == NOTIFY_STATUS_OK) {
            _requestToken = token;
        }
    }
    return self;
}

- (void)requestRefresh {
    if (!atomic_load_explicit(&_stopping, memory_order_relaxed)) {
        // Merge a burst of lifecycle/pane requests; no timer or polling loop.
        dispatch_source_merge_data(self.refreshSource, 1);
    }
}

- (void)refreshOnQueue {
    if (atomic_load_explicit(&_stopping, memory_order_relaxed)) {
        return;
    }
    // Do not prompt for or change authorization. A temporarily unavailable or
    // unauthorized library must never erase the last successfully saved list.
    if ([PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite] !=
        PHAuthorizationStatusAuthorized) {
        return;
    }
    if (![PHPhotoLibrary respondsToSelector:@selector(px_appPhotoLibrary)] ||
        ![PHFetchOptions instancesRespondToSelector:@selector(setPhotoLibrary:)]) {
        return;
    }
    PHPhotoLibrary *library = [PHPhotoLibrary px_appPhotoLibrary];
    if (library == nil || library.unavailabilityReason != nil) {
        return;
    }
    if (self.library != library) {
        [self.library unregisterChangeObserver:self];
        self.library = library;
        self.albums = nil;
        self.smartAlbums = nil;
        self.candidate = nil;
        self.published = nil;
        // Observe before fetching so a change during the fetch is not missed.
        [library registerChangeObserver:self];
    }
    PHFetchOptions *options = [PHFetchOptions new];
    options.photoLibrary = library;
    PHFetchResult *albums = [PHAssetCollection
        fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                             subtype:PHAssetCollectionSubtypeAny options:options];
    PHFetchResult *smartAlbums = [PHAssetCollection
        fetchAssetCollectionsWithType:PHAssetCollectionTypeSmartAlbum
                             subtype:PHAssetCollectionSubtypeAny options:options];
    if (albums == nil || smartAlbums == nil || library.unavailabilityReason != nil) {
        return;
    }
    self.albums = albums;
    self.smartAlbums = smartAlbums;
    [self rebuildOnQueue];
}

- (void)rebuildOnQueue {
    NSArray<NSDictionary *> *previous = self.candidate ?: self.published;
    self.candidate = nil;
    if (self.albums == nil || self.smartAlbums == nil) {
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *previousTitles = nil;
    NSMutableArray<NSDictionary *> *inventory = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (PHFetchResult *result in @[self.albums, self.smartAlbums]) {
        BOOL smartResult = result == self.smartAlbums;
        for (PHAssetCollection *collection in result) {
            // Other smart collections belong to Media Types/Utilities, not the
            // concrete My Albums card layout our per-album switch controls.
            if (smartResult) {
                PHAssetCollectionSubtype subtype = collection.assetCollectionSubtype;
                if (subtype != PHAssetCollectionSubtypeSmartAlbumUserLibrary &&
                    subtype != PHAssetCollectionSubtypeSmartAlbumFavorites) {
                    continue;
                }
            }
            NSString *identifier = collection.localIdentifier;
            if (identifier.length == 0) {
                return;  // An unidentifiable row is not proof of an empty library.
            }
            if ([seen containsObject:identifier]) {
                continue;
            }
            // Build the old-title index only when a title is actually missing.
            // Fully titled or duplicate rows need no fallback lookup or scan.
            NSString *title = collection.localizedTitle;
            if (title.length == 0) {
                if (previousTitles == nil) {
                    previousTitles = [NSMutableDictionary dictionary];
                    for (NSDictionary *album in previous) {
                        previousTitles[album[@"id"]] = album[@"title"];
                    }
                }
                title = previousTitles[identifier] ?: @"未命名相簿";
            }
            [seen addObject:identifier];
            [inventory addObject:@{@"id": identifier, @"title": title}];
        }
    }
    // PhotoKit's fetch order is not the pane's ordering contract. Stable sorting
    // prevents unrelated library changes from rewriting an equivalent list.
    [inventory sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult titleOrder = [a[@"title"] localizedStandardCompare:b[@"title"]];
        return titleOrder == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : titleOrder;
    }];
    self.candidate = inventory;
    [self publishOnQueue];
}

- (void)publishOnQueue {
    NSArray<NSDictionary *> *inventory = self.candidate;
    if (atomic_load_explicit(&_stopping, memory_order_relaxed) || inventory == nil ||
        self.library.unavailabilityReason != nil ||
        [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite] !=
            PHAuthorizationStatusAuthorized || [self.published isEqualToArray:inventory]) {
        return;
    }
    CFPreferencesSetAppValue(CFSTR("albumInventory"), (__bridge CFPropertyListRef)inventory,
                             CFSTR(APELIN_PACKAGE_ID));
    if (CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID))) {
        self.published = inventory;
        notify_post(APELIN_PACKAGE_ID "/inventoryChanged");
    } else {
        // Even if this was a failed write of B after successful A, returning to
        // A must synchronize again: cfprefsd may still hold unsaved B in memory.
        self.published = nil;
    }
}

- (void)photoLibraryDidChange:(PHChange *)changeInstance {
    if (atomic_load_explicit(&_stopping, memory_order_relaxed)) {
        return;
    }
    dispatch_async(self.queue, ^{
        if (atomic_load_explicit(&self->_stopping, memory_order_relaxed)) {
            return;
        }
        if (self.albums == nil || self.smartAlbums == nil) {
            [self requestRefresh];
            return;
        }
        PHFetchResultChangeDetails *albums = [changeInstance changeDetailsForFetchResult:self.albums];
        PHFetchResultChangeDetails *smart = [changeInstance changeDetailsForFetchResult:self.smartAlbums];
        if (albums == nil && smart == nil) {
            // Asset-only events do not rescan metadata. A failed synchronization
            // may retry on the next real event without requerying collections.
            if (self.published == nil) {
                [self publishOnQueue];
            }
            return;
        }
        if (albums != nil) self.albums = albums.fetchResultAfterChanges;
        if (smart != nil) self.smartAlbums = smart.fetchResultAfterChanges;
        [self rebuildOnQueue];
    });
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    atomic_store_explicit(&_stopping, true, memory_order_relaxed);
    dispatch_async(self.queue, ^{
        if (self.requestToken != -1) {
            notify_cancel(self.requestToken);
            self.requestToken = -1;
        }
        dispatch_source_cancel(self.refreshSource);
        [self.library unregisterChangeObserver:self];
        // This runs after any in-flight synchronization without blocking main.
        if (completion != nil) dispatch_async(dispatch_get_main_queue(), completion);
    });
}
@end

static HAAlbumInventoryWorker *HAInventoryWorker(void) {
    static HAAlbumInventoryWorker *worker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ worker = [HAAlbumInventoryWorker new]; });
    return worker;
}

void HAStartAlbumInventory(void) {
    [HAInventoryWorker() requestRefresh];
}

void HARefreshAlbumInventory(void) {
    [HAInventoryWorker() requestRefresh];
}

void HAStopAlbumInventory(dispatch_block_t completion) {
    [HAInventoryWorker() stopWithCompletion:completion];
}
