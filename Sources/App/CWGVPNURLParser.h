#import <Foundation/Foundation.h>

@interface CWGParsedVPNURL : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *configuration;
@end

@interface CWGVPNURLParser : NSObject
+ (CWGParsedVPNURL *)parseURL:(NSString *)URLString error:(NSError **)error;
+ (NSString *)sanitizedTunnelName:(NSString *)name;
@end
