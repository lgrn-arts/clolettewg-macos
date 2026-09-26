/* SPDX-License-Identifier: MIT
 *
 * IPCClient.h — talks to the privileged awgd over /var/run/awg-client.sock.
 * Newline-delimited JSON, first message must be {"cmd":"auth","name":token}.
 * All calls are synchronous (called from background queues).
 */

#import <Foundation/Foundation.h>

@interface AWGStatus : NSObject
@property (copy) NSString *name;
@property (copy) NSString *state;      // disconnected | connecting | connected
@property (copy) NSString *iface;
@property (copy) NSString *endpoint;
@property (nonatomic) long long handshake; // unix ts, 0 = none yet
@property (nonatomic) long long txBytes;
@property (nonatomic) long long rxBytes;
- (NSString *)stateText;
@end

@interface IPCClient : NSObject
- (instancetype)initWithToken:(NSString *)token;
- (NSDictionary *)rawRequest:(NSDictionary *)req timeout:(NSTimeInterval)timeout;
- (BOOL)auth;
- (NSDictionary *)upTunnel:(NSString *)name conf:(NSString *)conf error:(NSString **)err;
- (BOOL)down;
- (AWGStatus *)status;
- (NSArray *)logLines:(NSUInteger)n;
@end
