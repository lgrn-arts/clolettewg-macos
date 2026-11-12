#import "CWGConstants.h"

NSString * const CWGAppBundlePath = @"/Applications/CloletteWG.app";
NSString * const CWGServiceLabel = @"com.narek.clolettewg.daemon";
NSString * const CWGHelperPath = @"/Library/PrivilegedHelperTools/com.narek.clolettewg.daemon";
NSString * const CWGLaunchdPlistPath = @"/Library/LaunchDaemons/com.narek.clolettewg.daemon.plist";
NSString * const CWGStateDirectory = @"/Library/Application Support/CloletteWG";
NSString * const CWGTokenPath = @"/Library/Application Support/CloletteWG/token";
NSString * const CWGVersionStampPath = @"/Library/Application Support/CloletteWG/VERSION";
NSString * const CWGLaunchdLogPath = @"/Library/Application Support/CloletteWG/launchd.log";
NSString * const CWGSocketPath = @"/var/run/clolette-wg.sock";

NSString *CWGAppVersion(void) {
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"unknown";
}

NSString *CWGValidatedTunnelName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length < 1 || trimmed.length > 15) {
        return nil;
    }
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar c = [trimmed characterAtIndex:i];
        BOOL valid = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!valid) {
            return nil;
        }
    }
    return trimmed;
}
