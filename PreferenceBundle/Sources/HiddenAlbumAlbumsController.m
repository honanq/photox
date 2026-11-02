// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The album list, on a page of its own: one switch per album the tweak collected
// from the Albums tab. Each switch is stored in the com.simon.hidden-album domain
// as "hide.<localIdentifier>", which is what the tweak reads to leave that album
// out of the Albums page.
#import <Preferences/PSListController.h>

@interface HiddenAlbumAlbumsController : PSListController
@end

@implementation HiddenAlbumAlbumsController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray array];

        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@APELIN_PACKAGE_ID];
        NSArray<NSDictionary *> *albums = [defaults objectForKey:@"albumInventory"];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"相簿（勾选＝隐藏）"];
        [group setProperty:@"勾选的相簿会从照片 App 的「相簿」页移除。列表在打开一次相簿页后更新。"
                   forKey:@"footerText"];
        [specifiers addObject:group];

        if (![albums isKindOfClass:[NSArray class]] || albums.count == 0) {
            PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@""];
            [empty setProperty:@"先打开一次照片 App 的「相簿」页，再回到这里，就会列出你的相簿。"
                        forKey:@"footerText"];
            [specifiers addObject:empty];
        }

        for (NSDictionary *album in albums) {
            NSString *identifier = album[@"id"];
            NSString *title = album[@"title"];
            if (identifier.length == 0 || title.length == 0) {
                continue;
            }
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
}

@end
