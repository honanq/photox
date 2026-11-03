// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The album list, on a page of its own: one switch per album the tweak collected
// from the Albums tab. Each switch is stored in the com.simon.hidden-album domain
// as "hide.<localIdentifier>", which is what the tweak reads to leave that album
// out of the Albums page.
#import <Preferences/PSListController.h>
#import <notify.h>

// Treat malformed/stale values as an empty inventory. Keep the first valid
// record for an identifier, and own immutable strings for the cached snapshot.
static NSArray<NSDictionary *> *HAValidatedAlbumInventory(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
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
    return [albums copy];
}

@interface HiddenAlbumAlbumsController : PSListController
@property (nonatomic, strong) NSUserDefaults *ha_inventoryDefaults;
@property (nonatomic, copy) NSArray<NSDictionary *> *ha_albumInventory;
@property (nonatomic) BOOL ha_pageVisible;
@property (nonatomic) int ha_inventoryNotifyToken;
@property (nonatomic) BOOL ha_inventoryNotifyRegistered;
@end

@implementation HiddenAlbumAlbumsController

- (NSArray<NSDictionary *> *)ha_readAlbumInventory {
    if (self.ha_inventoryDefaults == nil) {
        self.ha_inventoryDefaults = [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
    }
    return HAValidatedAlbumInventory([self.ha_inventoryDefaults objectForKey:@"albumInventory"]);
}

- (void)ha_refreshAlbumInventory {
    NSArray<NSDictionary *> *albums = [self ha_readAlbumInventory];
    if ([self.ha_albumInventory isEqualToArray:albums]) {
        return;
    }
    self.ha_albumInventory = albums;
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray array];
        if (self.ha_albumInventory == nil) {
            self.ha_albumInventory = [self ha_readAlbumInventory];
        }
        NSArray<NSDictionary *> *albums = self.ha_albumInventory;

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"相簿（勾选＝隐藏）"];
        [group setProperty:@"勾选的相簿会从照片 App 的「相簿」页移除。列表在打开一次相簿页后更新。"
                   forKey:@"footerText"];
        [specifiers addObject:group];

        if (albums.count == 0) {
            PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@""];
            [empty setProperty:@"先打开一次照片 App 的「相簿」页，再回到这里，就会列出你的相簿。"
                        forKey:@"footerText"];
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
}

- (void)viewWillDisappear:(BOOL)animated {
    self.ha_pageVisible = NO;
    [super viewWillDisappear:animated];
}

- (void)ha_applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.ha_pageVisible) {
        [self ha_refreshAlbumInventory];
    }
}

- (void)dealloc {
    if (_ha_inventoryNotifyRegistered) {
        notify_cancel(_ha_inventoryNotifyToken);
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
