#import <Foundation/Foundation.h>

@interface CWGTunnelStore : NSObject
- (NSArray *)tunnelNames;
- (NSString *)configurationForTunnel:(NSString *)name;
- (BOOL)saveConfiguration:(NSString *)configuration name:(NSString *)name error:(NSError **)error;
- (BOOL)removeTunnel:(NSString *)name error:(NSError **)error;
@end
