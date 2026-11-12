#import <Foundation/Foundation.h>

extern NSString * const CWGAppBundlePath;
extern NSString * const CWGServiceLabel;
extern NSString * const CWGHelperPath;
extern NSString * const CWGLaunchdPlistPath;
extern NSString * const CWGStateDirectory;
extern NSString * const CWGTokenPath;
extern NSString * const CWGVersionStampPath;
extern NSString * const CWGLaunchdLogPath;
extern NSString * const CWGSocketPath;

NSString *CWGAppVersion(void);
NSString *CWGValidatedTunnelName(NSString *name);
