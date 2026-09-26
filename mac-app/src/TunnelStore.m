/* SPDX-License-Identifier: MIT
 *
 * TunnelStore.m — plist persistence; nothing newer than 10.6 APIs.
 */

#import "TunnelStore.h"

@implementation TunnelStore {
    NSMutableDictionary *_tunnels; // name -> conf text
    NSString *_path;
}

+ (instancetype)sharedStore {
    static TunnelStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[TunnelStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                         @"Library/Application Support/Nanami"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        _path = [dir stringByAppendingPathComponent:@"Tunnels.plist"];

        // The app used to store tunnels under .../AwgClient. Adopt the old
        // file on first run under the new name so that renaming the product
        // never loses a user's configuration.
        if (![[NSFileManager defaultManager] fileExistsAtPath:_path]) {
            NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:
                                @"Library/Application Support/AwgClient/Tunnels.plist"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) {
                [[NSFileManager defaultManager] copyItemAtPath:legacy
                                                        toPath:_path
                                                         error:NULL];
            }
        }

        _tunnels = [NSMutableDictionary dictionaryWithContentsOfFile:_path] ?:
                   [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)flush {
    [_tunnels writeToFile:_path atomically:YES];
}

- (NSArray *)tunnelNames {
    return [[_tunnels allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)confForTunnel:(NSString *)name {
    return _tunnels[name];
}

- (void)saveTunnel:(NSString *)name conf:(NSString *)conf {
    _tunnels[name] = conf;
    [self flush];
}

- (void)removeTunnel:(NSString *)name {
    [_tunnels removeObjectForKey:name];
    [self flush];
}

- (NSString *)uniqueNameForBase:(NSString *)base {
    NSString *clean = [[base componentsSeparatedByCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"-"];
    clean = [[clean stringByDeletingPathExtension] stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceCharacterSet]];
    if (clean.length == 0) {
        clean = @"Tunnel";
    }
    if (_tunnels[clean] == nil) {
        return clean;
    }
    for (NSUInteger i = 2; i < 1000; i++) {
        NSString *cand = [NSString stringWithFormat:@"%@ %lu", clean, (unsigned long)i];
        if (_tunnels[cand] == nil) {
            return cand;
        }
    }
    return [NSString stringWithFormat:@"%@ %lu", clean, (unsigned long)[NSDate timeIntervalSinceReferenceDate]];
}

@end
