#import <Cocoa/Cocoa.h>

@interface CWGStatusItemView : NSView
@property (nonatomic, retain) NSImage *image;
@property (nonatomic, assign) BOOL connecting;
@property (nonatomic, copy) void (^leftAction)(void);
@property (nonatomic, copy) void (^rightAction)(void);
@end
