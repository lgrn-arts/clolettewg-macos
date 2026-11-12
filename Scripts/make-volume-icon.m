#import <Cocoa/Cocoa.h>

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101400
#define CWGCompositingOperation NSCompositingOperationSourceOver
#define CWGPNGFileType NSBitmapImageFileTypePNG
#else
#define CWGCompositingOperation NSCompositeSourceOver
#define CWGPNGFileType NSPNGFileType
#endif

int main(int argc, const char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "usage: make-volume-icon backdrop.icns output.png size\n");
        return 2;
    }
    @autoreleasepool {
        NSImage *backdrop = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSInteger size = [[NSString stringWithUTF8String:argv[3]] integerValue];
        if (!backdrop || size < 16 || size > 1024) {
            fprintf(stderr, "invalid icon input or size\n");
            return 1;
        }

        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        if (!bitmap) return 1;

        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [backdrop drawInRect:NSMakeRect(0, 0, size, size) fromRect:NSZeroRect
                   operation:CWGCompositingOperation fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        NSData *PNG = [bitmap representationUsingType:CWGPNGFileType properties:[NSDictionary dictionary]];
        return [PNG writeToFile:output atomically:YES] ? 0 : 1;
    }
}
