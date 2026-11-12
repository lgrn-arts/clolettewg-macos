#import "CWGDaemonClient.h"
#import "CWGConstants.h"
#import <errno.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

@implementation CWGTunnelStatus
- (id)init {
    self = [super init];
    if (self) _state = @"disconnected";
    return self;
}
- (BOOL)isActive {
    return [self.state isEqualToString:@"connected"] || [self.state isEqualToString:@"connecting"];
}
- (NSString *)readableState {
    if ([self.state isEqualToString:@"connected"]) {
        return self.interfaceName.length > 0 ? [NSString stringWithFormat:@"Connected (%@)", self.interfaceName] : @"Connected";
    }
    if ([self.state isEqualToString:@"connecting"]) return @"Connecting — waiting for handshake";
    if (self.error.length > 0) return [NSString stringWithFormat:@"Unavailable: %@", self.error];
    return @"Disconnected";
}
@end

@interface CWGDaemonClient ()
@property (nonatomic, copy) NSString *token;
@end

@implementation CWGDaemonClient

- (id)initWithToken:(NSString *)token {
    self = [super init];
    if (self) self.token = token ?: @"";
    return self;
}

- (NSDictionary *)request:(NSDictionary *)request timeout:(NSTimeInterval)timeout {
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) {
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"ok",
                [NSString stringWithFormat:@"socket: %s", strerror(errno)], @"error", nil];
    }
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000.0);
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, [CWGSocketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int code = errno;
        close(descriptor);
        NSString *message = (code == ECONNREFUSED || code == ENOENT || code == EACCES)
                            ? @"Service is not running or access is denied."
                            : [NSString stringWithFormat:@"connect: %s", strerror(code)];
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"ok", message, @"error", nil];
    }

    NSData *payload = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    NSMutableData *line = [payload mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    const unsigned char *cursor = [line bytes];
    NSUInteger remaining = [line length];
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            close(descriptor);
            return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"ok", @"write failed", @"error", nil];
        }
        cursor += written;
        remaining -= (NSUInteger)written;
    }

    NSMutableData *buffer = [NSMutableData data];
    char chunk[4096];
    BOOL foundNewline = NO;
    while ([buffer length] < 8 * 1024 * 1024 && !foundNewline) {
        ssize_t count = read(descriptor, chunk, sizeof(chunk));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)count];
        foundNewline = memchr([buffer bytes], '\n', [buffer length]) != NULL;
    }
    close(descriptor);
    NSRange newline = [buffer rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, [buffer length])];
    NSData *JSON = newline.location == NSNotFound ? buffer : [buffer subdataWithRange:NSMakeRange(0, newline.location)];
    id response = [JSON length] > 0 ? [NSJSONSerialization JSONObjectWithData:JSON options:0 error:NULL] : nil;
    if (![response isKindOfClass:[NSDictionary class]]) {
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"ok",
                @"Empty or malformed daemon response (timeout?).", @"error", nil];
    }
    return response;
}

- (NSDictionary *)authenticatedRequest:(NSString *)command extras:(NSDictionary *)extras timeout:(NSTimeInterval)timeout {
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithObjectsAndKeys:command, @"cmd", self.token, @"token", nil];
    [request addEntriesFromDictionary:extras ?: [NSDictionary dictionary]];
    return [self request:request timeout:timeout];
}

- (BOOL)authenticate {
    if ([self.token length] < 32) return NO;
    NSDictionary *response = [self authenticatedRequest:@"auth" extras:nil timeout:3.0];
    return [[response objectForKey:@"ok"] boolValue];
}

- (CWGTunnelStatus *)status {
    CWGTunnelStatus *status = [[CWGTunnelStatus alloc] init];
    NSDictionary *response = [self authenticatedRequest:@"status" extras:nil timeout:3.0];
    if (![[response objectForKey:@"ok"] boolValue]) {
        status.error = [response objectForKey:@"error"] ?: @"Unknown service error";
        return status;
    }
    NSDictionary *data = [response objectForKey:@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        status.error = @"Malformed status response";
        return status;
    }
    status.name = [data objectForKey:@"name"];
    status.state = [data objectForKey:@"state"] ?: @"disconnected";
    status.interfaceName = [data objectForKey:@"iface"];
    status.endpoint = [data objectForKey:@"endpoint"];
    status.lastHandshake = [[data objectForKey:@"last_handshake"] longLongValue];
    status.transmittedBytes = [[data objectForKey:@"tx_bytes"] longLongValue];
    status.receivedBytes = [[data objectForKey:@"rx_bytes"] longLongValue];
    status.listenPort = [[data objectForKey:@"listen_port"] intValue];
    status.obfuscationEnabled = [[data objectForKey:@"obfuscation_enabled"] boolValue];
    return status;
}

- (BOOL)bringUpTunnel:(NSString *)name configuration:(NSString *)configuration error:(NSString **)error {
    NSDictionary *extras = [NSDictionary dictionaryWithObjectsAndKeys:name ?: @"", @"name", configuration ?: @"", @"conf", nil];
    NSDictionary *response = [self authenticatedRequest:@"up" extras:extras timeout:45.0];
    BOOL ok = [[response objectForKey:@"ok"] boolValue];
    if (!ok && error) *error = [response objectForKey:@"error"] ?: @"Unknown connect error";
    return ok;
}

- (BOOL)bringDownWithError:(NSString **)error {
    NSDictionary *response = [self authenticatedRequest:@"down" extras:nil timeout:30.0];
    BOOL ok = [[response objectForKey:@"ok"] boolValue];
    if (!ok && error) *error = [response objectForKey:@"error"] ?: @"Unknown disconnect error";
    return ok;
}

- (NSArray *)logLines:(NSUInteger)count error:(NSString **)error {
    NSDictionary *extras = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:count] forKey:@"n"];
    NSDictionary *response = [self authenticatedRequest:@"log" extras:extras timeout:5.0];
    if (![[response objectForKey:@"ok"] boolValue]) {
        if (error) *error = [response objectForKey:@"error"] ?: @"Unknown log error";
        return [NSArray array];
    }
    NSArray *lines = [[response objectForKey:@"data"] objectForKey:@"lines"];
    return [lines isKindOfClass:[NSArray class]] ? lines : [NSArray array];
}

@end
