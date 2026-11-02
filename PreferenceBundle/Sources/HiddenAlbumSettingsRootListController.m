// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The settings pane: rows come from Root.plist, values are read and written by
// PSListController in the com.simon.hidden-album domain, and each change posts
// com.simon.hidden-album/changed for the tweak.
#import <Preferences/PSListController.h>

@interface HiddenAlbumSettingsRootListController : PSListController
@end

@implementation HiddenAlbumSettingsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"隐藏相册隐藏";
}

@end
