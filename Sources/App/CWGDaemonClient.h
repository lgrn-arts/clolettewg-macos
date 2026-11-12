#import <Foundation/Foundation.h>

@interface CWGTunnelStatus : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *state;
@property (nonatomic, copy) NSString *interfaceName;
@property (nonatomic, copy) NSString *endpoint;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, assign) long long lastHandshake;
@property (nonatomic, assign) long long transmittedBytes;
@property (nonatomic, assign) long long receivedBytes;
@property (nonatomic, assign) int listenPort;
@property (nonatomic, assign, getter=isObfuscationEnabled) BOOL obfuscationEnabled;
- (BOOL)isActive;
- (NSString *)readableState;
@end

@interface CWGDaemonClient : NSObject
- (id)initWithToken:(NSString *)token;
- (BOOL)authenticate;
- (CWGTunnelStatus *)status;
- (BOOL)bringUpTunnel:(NSString *)name configuration:(NSString *)configuration error:(NSString **)error;
- (BOOL)bringDownWithError:(NSString **)error;
- (NSArray *)logLines:(NSUInteger)count error:(NSString **)error;
@end
