#import <Cocoa/Cocoa.h>
#import "CWGAppDelegate.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CWGAppDelegate *delegate = [[CWGAppDelegate alloc] init];
        [application setDelegate:delegate];
        [application run];
    }
    return 0;
}
