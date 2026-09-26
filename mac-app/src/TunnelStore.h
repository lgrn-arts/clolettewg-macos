/* SPDX-License-Identifier: MIT
 *
 * TunnelStore.h — list of saved tunnels (name -> .conf text), persisted in
 * ~/Library/Application Support/Nanami/Tunnels.plist
 * (migrated from .../AwgClient on first run).
 */

#import <Foundation/Foundation.h>

@interface TunnelStore : NSObject

@property (readonly, strong) NSArray *tunnelNames;

+ (instancetype)sharedStore;
- (NSString *)confForTunnel:(NSString *)name;
- (void)saveTunnel:(NSString *)name conf:(NSString *)conf;
- (void)removeTunnel:(NSString *)name;
- (NSString *)uniqueNameForBase:(NSString *)base;

@end
