#import "CWGTunnelStore.h"
#import "CWGConstants.h"

@interface CWGTunnelStore ()
@property (nonatomic, retain) NSMutableDictionary *tunnels;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation CWGTunnelStore

- (id)init {
    self = [super init];
    if (self) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *directory = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"CloletteWG"];
        NSFileManager *files = [NSFileManager defaultManager];
        [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [files setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0700] forKey:NSFilePosixPermissions]
                ofItemAtPath:directory error:NULL];
        self.storagePath = [directory stringByAppendingPathComponent:@"Tunnels.plist"];

        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:self.storagePath];
        self.tunnels = [NSMutableDictionary dictionary];
        for (id key in saved) {
            id value = [saved objectForKey:key];
            if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]] && CWGValidatedTunnelName(key)) {
                [self.tunnels setObject:value forKey:key];
            }
        }
    }
    return self;
}

- (NSArray *)tunnelNames {
    @synchronized (self) {
        return [[self.tunnels allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NSString *)configurationForTunnel:(NSString *)name {
    @synchronized (self) {
        return [self.tunnels objectForKey:name];
    }
}

- (BOOL)writeTunnels:(NSError **)error {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.tunnels
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    if (!data) {
        return NO;
    }
    BOOL written = [data writeToFile:self.storagePath options:NSDataWritingAtomic error:error];
    if (written) {
        [[NSFileManager defaultManager] setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0600]
                                                                                 forKey:NSFilePosixPermissions]
                                         ofItemAtPath:self.storagePath error:NULL];
    }
    return written;
}

- (BOOL)saveConfiguration:(NSString *)configuration name:(NSString *)name error:(NSError **)error {
    NSString *validName = CWGValidatedTunnelName(name);
    if (!validName || ![configuration isKindOfClass:[NSString class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"CloletteWG.TunnelStore" code:1
                                     userInfo:[NSDictionary dictionaryWithObject:@"Invalid tunnel name or configuration."
                                                                          forKey:NSLocalizedDescriptionKey]];
        }
        return NO;
    }
    @synchronized (self) {
        NSString *previous = [self.tunnels objectForKey:validName];
        [self.tunnels setObject:configuration forKey:validName];
        if (![self writeTunnels:error]) {
            if (previous) {
                [self.tunnels setObject:previous forKey:validName];
            } else {
                [self.tunnels removeObjectForKey:validName];
            }
            return NO;
        }
    }
    return YES;
}

- (BOOL)removeTunnel:(NSString *)name error:(NSError **)error {
    @synchronized (self) {
        NSString *previous = [self.tunnels objectForKey:name];
        if (!previous) {
            return YES;
        }
        [self.tunnels removeObjectForKey:name];
        if (![self writeTunnels:error]) {
            [self.tunnels setObject:previous forKey:name];
            return NO;
        }
    }
    return YES;
}

@end
