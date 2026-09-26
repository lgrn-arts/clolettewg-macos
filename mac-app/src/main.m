/* SPDX-License-Identifier: MIT
 *
 * main.m — entry point. The app has no nib file, so the delegate is
 * installed by hand and NSApp is run explicitly. ARC, 10.9 SDK.
 */

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:delegate];
        [NSApp run];
        return 0;
    }
}
