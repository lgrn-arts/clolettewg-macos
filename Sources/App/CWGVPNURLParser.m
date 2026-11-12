#import "CWGVPNURLParser.h"
#import <stdint.h>
#import <string.h>
#import <zlib.h>

static NSString * const CWGVPNURLDomain = @"CloletteWG.VPNURL";

@implementation CWGParsedVPNURL
@end

@implementation CWGVPNURLParser

static NSError *CWGVPNError(NSUInteger code, NSString *description) {
    return [NSError errorWithDomain:CWGVPNURLDomain code:(NSInteger)code
                           userInfo:[NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey]];
}

static uint32_t CWGReadBigEndianUInt32(const unsigned char *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static NSData *CWGInflateRawDeflate(NSData *payload, NSUInteger expectedSize) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), sizeof(stream)) != Z_OK) {
        return nil;
    }

    NSUInteger capacity = MAX((NSUInteger)256 * 1024, expectedSize);
    NSMutableData *output = [NSMutableData dataWithLength:capacity];
    stream.next_in = (Bytef *)[payload bytes];
    stream.avail_in = (uInt)[payload length];
    stream.next_out = (Bytef *)[output mutableBytes];
    stream.avail_out = (uInt)[output length];
    int result = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    if (result != Z_STREAM_END || stream.total_out == 0) {
        return nil;
    }
    [output setLength:(NSUInteger)stream.total_out];
    return output;
}

static NSData *CWGDecodedPayload(NSData *raw) {
    if ([raw length] <= 10) {
        return raw;
    }
    const unsigned char *bytes = [raw bytes];
    uint32_t expectedSize = CWGReadBigEndianUInt32(bytes);
    if (expectedSize == 0 || expectedSize > 16 * 1024 * 1024) {
        return raw;
    }
    NSData *deflate = [raw subdataWithRange:NSMakeRange(6, [raw length] - 10)];
    NSData *inflated = CWGInflateRawDeflate(deflate, expectedSize);
    return inflated ?: raw;
}

+ (NSString *)sanitizedTunnelName:(NSString *)name {
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < [name length] && [clean length] < 15; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL valid = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (valid) {
            [clean appendFormat:@"%C", c];
        }
    }
    return [clean length] > 0 ? clean : @"imported";
}

+ (CWGParsedVPNURL *)parseURL:(NSString *)URLString error:(NSError **)error {
    NSString *trimmed = [URLString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"vpn://"]) {
        if (error) *error = CWGVPNError(1, @"Not a vpn:// URL.");
        return nil;
    }

    NSString *body = [trimmed substringFromIndex:6];
    body = [[body componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    body = [body stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    body = [body stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while ([body length] % 4 != 0) {
        body = [body stringByAppendingString:@"="];
    }
    NSData *raw = [body length] > 0 ? [[NSData alloc] initWithBase64EncodedString:body options:0] : nil;
    if (!raw) {
        if (error) *error = CWGVPNError(2, @"The vpn:// payload is not valid base64url.");
        return nil;
    }

    id root = [NSJSONSerialization JSONObjectWithData:CWGDecodedPayload(raw) options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (error) *error = CWGVPNError(3, @"The decoded payload is not valid Amnezia JSON or uses unsupported compression.");
        return nil;
    }
    NSArray *containers = [root objectForKey:@"containers"];
    if (![containers isKindOfClass:[NSArray class]]) {
        if (error) *error = CWGVPNError(4, @"The link has no Amnezia containers. It may be a subscription, not an AWG connection.");
        return nil;
    }

    NSDictionary *selected = nil;
    for (id candidate in containers) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSString *kind = [candidate objectForKey:@"container"];
        if ([kind isEqualToString:@"amnezia-awg"] || [kind isEqualToString:@"amnezia-awg2"]) {
            selected = candidate;
            break;
        }
    }
    if (!selected) {
        if (error) *error = CWGVPNError(5, @"No AmneziaWG container (amnezia-awg or amnezia-awg2) was found.");
        return nil;
    }

    NSDictionary *awg = [selected objectForKey:@"awg"];
    if (![awg isKindOfClass:[NSDictionary class]]) {
        awg = [selected objectForKey:@"amnezia-awg"];
    }
    if (![awg isKindOfClass:[NSDictionary class]] || [awg count] == 0) {
        if (error) *error = CWGVPNError(6, @"The AmneziaWG container has no protocol configuration.");
        return nil;
    }

    NSString *lastConfig = [awg objectForKey:@"last_config"];
    if (![lastConfig isKindOfClass:[NSString class]] || [lastConfig length] == 0) {
        if (error) *error = CWGVPNError(7, @"The link has no AWG client config. Export a client connection, not full-access/admin config.");
        return nil;
    }
    NSData *lastData = [lastConfig dataUsingEncoding:NSUTF8StringEncoding];
    id client = [NSJSONSerialization JSONObjectWithData:lastData options:0 error:NULL];
    if (![client isKindOfClass:[NSDictionary class]]) {
        if (error) *error = CWGVPNError(8, @"The AWG last_config value is not valid JSON.");
        return nil;
    }
    NSString *configuration = [client objectForKey:@"config"];
    if (![configuration isKindOfClass:[NSString class]] || [configuration length] == 0) {
        if (error) *error = CWGVPNError(9, @"The AWG client config has no native config.");
        return nil;
    }

    NSString *description = [root objectForKey:@"description"];
    if (![description isKindOfClass:[NSString class]]) description = @"imported";
    CWGParsedVPNURL *parsed = [[CWGParsedVPNURL alloc] init];
    parsed.name = [self sanitizedTunnelName:description];
    parsed.configuration = configuration;
    return parsed;
}

@end
