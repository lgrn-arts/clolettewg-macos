/* SPDX-License-Identifier: MIT
 *
 * HelperInstaller.h — installs /Library/PrivilegedHelperTools/awgd plus the
 * LaunchDaemon plist, using AuthorizationExecuteWithPrivileges (one admin
 * password prompt). Deprecated in newer macOS but perfectly reliable on
 * 10.9 Mavericks.
 */

#import <Foundation/Foundation.h>

@interface HelperInstaller : NSObject

+ (NSString *)bundledAwgPath;        // awgd inside the app bundle
+ (BOOL)serviceInstalled;            // helper binary + plist present
+ (BOOL)serviceRunning;              // socket reachable & auth ok
+ (NSString *)readToken;             // from /Library/Application Support/...
+ (BOOL)installWithError:(NSString **)err;   // copies + loads (prompts)
+ (BOOL)uninstallWithError:(NSString **)err; // unloads + removes (prompts)

@end
