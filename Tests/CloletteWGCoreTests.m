#import <Foundation/Foundation.h>
#import "CWGVPNURLParser.h"
#import "CWGConstants.h"

static NSUInteger failures = 0;

static void CWGExpect(BOOL condition, NSString *message) {
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
    }
}

static NSString *CWGFixture(NSString *directory, NSString *name) {
    NSString *path = [[directory stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"txt"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

static void CWGExpectValid(NSString *URLString, NSString *expectedName, NSString *directory) {
    (void)directory;
    NSError *error = nil;
    CWGParsedVPNURL *parsed = [CWGVPNURLParser parseURL:URLString error:&error];
    CWGExpect(parsed != nil, [NSString stringWithFormat:@"valid URL rejected: %@", error]);
    CWGExpect([parsed.name isEqualToString:expectedName], @"wrong decoded name");
    CWGExpect([parsed.configuration rangeOfString:@"[Interface]"].location != NSNotFound, @"missing native config");
    CWGExpect([parsed.configuration rangeOfString:@"Endpoint = 198.51.100.1:64298"].location != NSNotFound, @"wrong endpoint");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: CloletteWGCoreTests fixtures-directory\n");
            return 2;
        }
        NSString *fixtures = [NSString stringWithUTF8String:argv[1]];
        NSString *modern = CWGFixture(fixtures, @"modern");
        NSString *legacy = CWGFixture(fixtures, @"legacy");
        NSString *plain = CWGFixture(fixtures, @"plain");
        NSString *awg2 = CWGFixture(fixtures, @"awg2");
        CWGExpectValid(modern, @"fixturephone", fixtures);
        CWGExpectValid(legacy, @"fixturephone", fixtures);
        CWGExpectValid(plain, @"fixturephone", fixtures);
        CWGExpectValid(awg2, @"fixturephone", fixtures);

        NSMutableString *wrapped = [[modern substringToIndex:80] mutableCopy];
        [wrapped appendString:@"\n"];
        [wrapped appendString:[modern substringFromIndex:80]];
        CWGExpectValid(wrapped, @"fixturephone", fixtures);

        NSError *error = nil;
        CWGExpect([CWGVPNURLParser parseURL:@"https://example.com" error:&error] == nil && error.code == 1, @"missing prefix accepted");
        error = nil;
        CWGExpect([CWGVPNURLParser parseURL:@"vpn://not-base64-at-all!!!" error:&error] == nil && error.code == 2, @"bad base64 accepted");
        error = nil;
        CWGExpect([CWGVPNURLParser parseURL:@"vpn://AAAA" error:&error] == nil && error.code == 3, @"bad JSON accepted");

        CWGExpect([[CWGVPNURLParser sanitizedTunnelName:@"My Phone!"] isEqualToString:@"MyPhone"], @"name sanitization");
        CWGExpect([[CWGVPNURLParser sanitizedTunnelName:@"abcdefghij1234567890"] isEqualToString:@"abcdefghij12345"], @"name clipping");
        CWGExpect([[CWGVPNURLParser sanitizedTunnelName:@"!!!"] isEqualToString:@"imported"], @"name fallback");
        CWGExpect([CWGValidatedTunnelName(@"  narek_ios  ") isEqualToString:@"narek_ios"], @"name trimming");
        CWGExpect(CWGValidatedTunnelName(@"a234567890123456") == nil, @"long name accepted");
        CWGExpect(CWGValidatedTunnelName(@"name/slash") == nil, @"slash accepted");

        if (failures) {
            fprintf(stderr, "%lu test(s) failed\n", (unsigned long)failures);
            return 1;
        }
        printf("CloletteWG core tests passed\n");
    }
    return 0;
}
