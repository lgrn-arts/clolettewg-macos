/* SPDX-License-Identifier: MIT
 *
 * IPCClient.m — see header. Pure BSD sockets + NSJSONSerialization;
 * nothing newer than OS X 10.9 is used.
 *
 * Protocol notes
 * --------------
 * Wire format (one JSON object per line, server replies with one line each):
 *
 *   request:  {"cmd":"<cmd>","token":"<shared-secret>", ...extras...}
 *   response: {"ok":true,  "data":{...}} | {"ok":false, "error":"..."}
 *
 * Every request — including the first message on a connection — must carry
 * the `token`. Earlier versions of this client only sent `cmd=auth` as a
 * separate first message, which did not match the server's protocol and
 * caused every "up" / "down" / "status" to fail with "authentication
 * failed". The current server accepts arbitrary commands as long as
 * `token` is present and correct.
 */

#import "IPCClient.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#define SOCKET_PATH "/var/run/awg-client.sock"

@implementation AWGStatus

- (instancetype)init {
    if ((self = [super init])) {
        _state = @"disconnected";
    }
    return self;
}

- (NSString *)stateText {
    if ([_state isEqualToString:@"connected"]) {
        return [NSString stringWithFormat:@"Connected%@", _iface ? [NSString stringWithFormat:@" (%@)", _iface] : @""];
    }
    if ([_state isEqualToString:@"connecting"]) {
        return @"Connecting… (waiting for handshake)";
    }
    return @"Disconnected";
}

@end

@implementation IPCClient {
    NSString *_token;
}

- (instancetype)initWithToken:(NSString *)token {
    if ((self = [super init])) {
        _token = [(token ?: @"") copy];
    }
    return self;
}

// Build the full request dict with the token attached so each command can
// be sent standalone (the server checks the token on every command, not
// just the first message).
- (NSMutableDictionary *)requestWithCmd:(NSString *)cmd extras:(NSDictionary *)extras {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"cmd"] = cmd;
    if (_token.length > 0) {
        r[@"token"] = _token;
    }
    for (NSString *k in extras) {
        if (extras[k] != nil) {
            r[k] = extras[k];
        }
    }
    return r;
}

- (NSDictionary *)rawRequest:(NSDictionary *)req timeout:(NSTimeInterval)timeout {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"socket: %s", strerror(errno)] };
    }

    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        NSString *why = [NSString stringWithFormat:@"%s", strerror(errno)];
        if (errno == ECONNREFUSED || errno == ENOENT || errno == EACCES) {
            why = @"service is not running";
        }
        return @{ @"ok": @NO, @"error": why };
    }

    NSData *payload = [NSJSONSerialization dataWithJSONObject:req options:0 error:NULL];
    if (!payload) {
        close(fd);
        return @{ @"ok": @NO, @"error": @"request encoding failed" };
    }
    NSMutableData *line = [payload mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

    ssize_t wrote = write(fd, line.bytes, line.length);
    if (wrote != (ssize_t)line.length) {
        close(fd);
        return @{ @"ok": @NO, @"error": @"write failed" };
    }

    // read one JSON line (up to 8 MB for configs/logs)
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    while (buf.length < 8 * 1024 * 1024) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) {
            break;
        }
        [buf appendBytes:chunk length:(NSUInteger)n];
        if (memchr(buf.bytes, '\n', buf.length)) {
            break;
        }
    }
    close(fd);

    NSRange nl = [buf rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
                          options:0 range:NSMakeRange(0, buf.length)];
    NSData *json = nl.location == NSNotFound ? buf : [buf subdataWithRange:NSMakeRange(0, nl.location)];
    if (!json.length) {
        return @{ @"ok": @NO, @"error": @"empty response (timeout?)" };
    }
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return @{ @"ok": @NO, @"error": @"malformed response" };
    }
    return obj;
}

- (BOOL)auth {
    NSDictionary *r = [self rawRequest:[self requestWithCmd:@"auth" extras:nil] timeout:10.0];
    return [r[@"ok"] boolValue];
}

- (NSDictionary *)upTunnel:(NSString *)name conf:(NSString *)conf error:(NSString **)err {
    NSDictionary *r = [self rawRequest:[self requestWithCmd:@"up"
                                                       extras:@{ @"name": name ?: @"", @"conf": conf ?: @"" }]
                              timeout:45.0];
    if (![r[@"ok"] boolValue] && err) {
        *err = [NSString stringWithFormat:@"%@", r[@"error"] ?: @"unknown error"];
    }
    return r;
}

- (BOOL)down {
    NSDictionary *r = [self rawRequest:[self requestWithCmd:@"down" extras:nil] timeout:30.0];
    return [r[@"ok"] boolValue];
}

- (AWGStatus *)status {
    AWGStatus *st = [[AWGStatus alloc] init];
    NSDictionary *r = [self rawRequest:[self requestWithCmd:@"status" extras:nil] timeout:10.0];
    if (![r[@"ok"] boolValue]) {
        st.state = @"disconnected";
        return st;
    }
    NSDictionary *d = r[@"data"];
    if (![d isKindOfClass:[NSDictionary class]]) {
        return st;
    }
    st.name     = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
    st.state    = d[@"state"] ?: @"disconnected";
    st.iface    = d[@"iface"];
    st.endpoint = d[@"endpoint"];
    st.handshake = [d[@"last_handshake"] longLongValue];
    st.txBytes   = [d[@"tx_bytes"] longLongValue];
    st.rxBytes   = [d[@"rx_bytes"] longLongValue];
    return st;
}

- (NSArray *)logLines:(NSUInteger)n {
    NSDictionary *r = [self rawRequest:[self requestWithCmd:@"log"
                                                     extras:@{ @"n": @(n) }]
                              timeout:10.0];
    if (![r[@"ok"] boolValue]) {
        return @[];
    }
    NSDictionary *d = r[@"data"];
    NSArray *lines = d[@"lines"];
    return [lines isKindOfClass:[NSArray class]] ? lines : @[];
}

@end
