#import <Foundation/Foundation.h>

typedef enum {
    CWGServiceStateReady = 0,
    CWGServiceStateMissing,
    CWGServiceStateNeedsUpdate,
    CWGServiceStateNotRunning,
    CWGServiceStateIncompleteBundle
} CWGServiceState;

@interface CWGServiceInstaller : NSObject
+ (NSString *)token;
+ (CWGServiceState)serviceState;
+ (BOOL)installWithError:(NSString **)error;
+ (BOOL)uninstallWithError:(NSString **)error;
@end
