#import "CWGStatusItemView.h"

@implementation CWGStatusItemView

- (BOOL)acceptsFirstMouse {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!self.image) return;
    NSRect frame = NSMakeRect((self.bounds.size.width - 18.0) / 2.0,
                              (self.bounds.size.height - 18.0) / 2.0, 18.0, 18.0);
    [self.image drawInRect:frame fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    if (!self.connecting) return;

    [[NSColor controlTextColor] setFill];
    CGFloat dotSize = 2.0;
    CGFloat gap = 2.0;
    CGFloat startX = (self.bounds.size.width - (dotSize * 3.0 + gap * 2.0)) / 2.0;
    CGFloat y = (self.bounds.size.height - dotSize) / 2.0 - 2.0;
    for (NSUInteger index = 0; index < 3; index++) {
        NSRect dot = NSMakeRect(startX + index * (dotSize + gap), y, dotSize, dotSize);
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.leftAction) self.leftAction();
}

- (void)rightMouseDown:(NSEvent *)event {
    (void)event;
    if (self.rightAction) self.rightAction();
}

@end
