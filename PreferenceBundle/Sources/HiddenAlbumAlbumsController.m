// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The album list, on a page of its own: one switch per album Photos persisted.
// Each switch is stored in the com.simon.hidden-album domain as
// "hide.<localIdentifier>", which is what the tweak reads to leave that album
// out of the Albums page.
#import <Preferences/PSListController.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

// nil means unavailable/malformed outer data, not an explicit empty inventory.
// Keep the first valid record per identifier and own immutable snapshot strings.
static NSArray<NSDictionary *> *HAValidatedAlbumInventory(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSMutableArray<NSDictionary *> *albums = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id identifier = item[@"id"];
        id title = item[@"title"];
        if (![identifier isKindOfClass:[NSString class]] ||
            ![title isKindOfClass:[NSString class]] ||
            [identifier length] == 0 || [title length] == 0 ||
            [seen containsObject:identifier]) {
            continue;
        }
        NSString *ownedIdentifier = [identifier copy];
        [seen addObject:ownedIdentifier];
        [albums addObject:@{@"id": ownedIdentifier, @"title": [title copy]}];
    }
    // A nonempty but wholly malformed payload is unavailable, not proof that
    // every album was deleted. Only an explicit [] may clear the old cache.
    return [(NSArray *)value count] != 0 && albums.count == 0 ? nil : [albums copy];
}

@interface HiddenAlbumAlbumsController : PSListController
@property (nonatomic, copy) NSArray<NSDictionary *> *ha_albumInventory;
@property (nonatomic) BOOL ha_pageVisible;
@property (nonatomic) int ha_inventoryNotifyToken;
@property (nonatomic) BOOL ha_inventoryNotifyRegistered;
@end

@implementation HiddenAlbumAlbumsController

- (NSArray<NSDictionary *> *)ha_readAlbumInventory {
    // Match Photos' App-domain writer and refresh its process-local CF cache
    // only at first load or an event boundary, never on a specifier cache hit.
    CFStringRef domain = CFSTR(APELIN_PACKAGE_ID);
    if (!CFPreferencesAppSynchronize(domain)) {
        return nil;
    }
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("albumInventory"), domain));
    return HAValidatedAlbumInventory(value);
}

- (void)ha_refreshAlbumInventory {
    NSArray<NSDictionary *> *albums = [self ha_readAlbumInventory];
    if (albums == nil || [self.ha_albumInventory isEqualToArray:albums]) {
        return;
    }
    self.ha_albumInventory = albums;
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)ha_requestAlbumInventory {
    // A signal to an already running Photos process, never an app launch.
    // The response listener only rereads storage, so requests cannot echo.
    notify_post(APELIN_PACKAGE_ID "/inventoryRequest");
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray array];
        if (self.ha_albumInventory == nil) {
            self.ha_albumInventory = [self ha_readAlbumInventory];
        }
        NSArray<NSDictionary *> *albums = self.ha_albumInventory;

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"相簿（勾选＝隐藏）"];
        [group setProperty:@"勾选的相簿会从照片 App 的「相簿」页隐藏。照片 App 运行时自动更新列表；未运行时显示上次保存的清单。"
                   forKey:@"footerText"];
        [specifiers addObject:group];

        if (albums.count == 0) {
            PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@""];
            NSString *message = self.ha_albumInventory == nil
                ? @"暂无已保存的清单。请打开「照片」App 一次完成采集，无需进入「相簿」页。照片未运行时无法取得最新列表。"
                : @"当前没有可列出的相簿。照片 App 运行时会自动更新；未运行时显示上次保存的结果。";
            [empty setProperty:message forKey:@"footerText"];
            [specifiers addObject:empty];
        }

        for (NSDictionary *album in albums) {
            NSString *identifier = album[@"id"];
            NSString *title = album[@"title"];
            PSSpecifier *specifier =
                [PSSpecifier preferenceSpecifierNamed:title
                                              target:self
                                                 set:@selector(setPreferenceValue:specifier:)
                                                 get:@selector(readPreferenceValue:)
                                              detail:nil
                                                cell:PSSwitchCell
                                                edit:nil];
            [specifier setProperty:[@"hide." stringByAppendingString:identifier] forKey:@"key"];
            [specifier setProperty:@APELIN_PACKAGE_ID forKey:@"defaults"];
            [specifier setProperty:@NO forKey:@"default"];
            [specifier setProperty:@APELIN_PACKAGE_ID @"/changed" forKey:@"PostNotification"];
            [specifiers addObject:specifier];
        }

        _specifiers = specifiers;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择相簿";
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(ha_applicationDidBecomeActive:)
                  name:UIApplicationDidBecomeActiveNotification object:nil];
    if (!self.ha_inventoryNotifyRegistered) {
        __weak HiddenAlbumAlbumsController *weakSelf = self;
        int token = 0;
        uint32_t status = notify_register_dispatch(APELIN_PACKAGE_ID "/inventoryChanged",
            &token, dispatch_get_main_queue(), ^(int notificationToken) {
                (void)notificationToken;
                HiddenAlbumAlbumsController *controller = weakSelf;
                if (controller.ha_pageVisible) {
                    [controller ha_refreshAlbumInventory];
                }
            });
        if (status == NOTIFY_STATUS_OK) {
            self.ha_inventoryNotifyToken = token;
            self.ha_inventoryNotifyRegistered = YES;
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.ha_pageVisible = YES;
    [self ha_refreshAlbumInventory];
    [self ha_requestAlbumInventory];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.ha_pageVisible = NO;
    [super viewWillDisappear:animated];
}

- (void)ha_applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.ha_pageVisible) {
        [self ha_refreshAlbumInventory];
        [self ha_requestAlbumInventory];
    }
}

- (void)dealloc {
    if (_ha_inventoryNotifyRegistered) {
        notify_cancel(_ha_inventoryNotifyToken);
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
