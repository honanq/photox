// SPDX-License-Identifier: MIT
//
// A bootstrap path (/Library/..., /usr/bin/x) as this process must open it,
// on roothide and rootless from one source. Copied from Apelin's
// apelin-bootstrap-paths skill; the root is found at run time and never stored.
#pragma once

#import <Foundation/Foundation.h>
#import <dlfcn.h>

static inline NSString *_Nullable ApelinBootstrapRoot(void) {
#ifdef APELIN_BOOTSTRAP_ROOTHIDE
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts =
            [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
    });
    return root;
#else
    return @"/var/jb";
#endif
}

static inline NSString *_Nullable ApelinBootstrapPath(NSString *_Nonnull path) {
    NSString *root = ApelinBootstrapRoot();
    return root == nil ? nil : [root stringByAppendingString:path];
}
