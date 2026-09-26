/* SPDX-License-Identifier: MIT
 *
 * AppDelegate.h — the whole UI of the Nanami client for OS X Mavericks.
 */

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate,
                                   NSTableViewDataSource,
                                   NSTableViewDelegate,
                                   NSWindowDelegate>

@end
