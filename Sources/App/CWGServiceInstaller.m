#import "CWGServiceInstaller.h"
#import "CWGConstants.h"
#import "CWGDaemonClient.h"

@implementation CWGServiceInstaller

+ (NSString *)token {
    NSString *token = [NSString stringWithContentsOfFile:CWGTokenPath encoding:NSUTF8StringEncoding error:NULL];
    token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [token length] >= 32 ? token : nil;
}

+ (CWGServiceState)serviceState {
    NSBundle *bundle = [NSBundle mainBundle];
    if ([bundle pathForResource:@"clolettewgd" ofType:nil] == nil ||
        [bundle pathForResource:@"clolettewgd-modern" ofType:nil] == nil ||
        [bundle pathForResource:@"com.clolettewg.daemon" ofType:@"plist"] == nil ||
        [bundle pathForResource:@"install-service" ofType:@"sh"] == nil) {
        return CWGServiceStateIncompleteBundle;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:CWGHelperPath] || ![files fileExistsAtPath:CWGLaunchdPlistPath]) {
        return CWGServiceStateMissing;
    }
    BOOL legacyMatches = [files contentsEqualAtPath:CWGHelperPath andPath:[bundle pathForResource:@"clolettewgd" ofType:nil]];
    BOOL modernMatches = [files contentsEqualAtPath:CWGHelperPath andPath:[bundle pathForResource:@"clolettewgd-modern" ofType:nil]];
    if (!legacyMatches && !modernMatches) return CWGServiceStateNeedsUpdate;
    NSString *stamp = [NSString stringWithContentsOfFile:CWGVersionStampPath encoding:NSUTF8StringEncoding error:NULL];
    stamp = [stamp stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![stamp isEqualToString:CWGAppVersion()]) return CWGServiceStateNeedsUpdate;
    CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:[self token]];
    return [client authenticate] ? CWGServiceStateReady : CWGServiceStateNotRunning;
}

static NSString *CWGShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *CWGAppleScriptQuote(NSString *value) {
    value = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    value = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", value];
}

+ (BOOL)runInstallerAction:(NSString *)action error:(NSString **)error {
    NSString *script = [[NSBundle mainBundle] pathForResource:@"install-service" ofType:@"sh"];
    if (!script) {
        if (error) *error = @"The bundled service installer is missing.";
        return NO;
    }
    NSString *resources = [script stringByDeletingLastPathComponent];
    NSString *command = [NSString stringWithFormat:@"%@ %@ %@ %@ %@",
                         CWGShellQuote(script), CWGShellQuote(action), CWGShellQuote(resources),
                         CWGShellQuote(CWGAppVersion()), CWGShellQuote(CWGServiceLabel)];
    NSString *source = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", CWGAppleScriptQuote(command)];
    NSDictionary *scriptError = nil;
    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:source];
    NSAppleEventDescriptor *output = [appleScript executeAndReturnError:&scriptError];
    if (scriptError) {
        NSNumber *number = [scriptError objectForKey:NSAppleScriptErrorNumber];
        if (error) {
            *error = [number integerValue] == -128 ? @"Cancelled." :
                     ([scriptError objectForKey:NSAppleScriptErrorMessage] ?: @"Administrator authorization failed.");
        }
        return NO;
    }
    NSString *text = [[output stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text hasSuffix:@"ok"]) return YES;
    if (error) *error = text.length > 0 ? text : @"Installer returned no output.";
    return NO;
}

+ (BOOL)installWithError:(NSString **)error {
    return [self runInstallerAction:@"install" error:error];
}

+ (BOOL)uninstallWithError:(NSString **)error {
    return [self runInstallerAction:@"uninstall" error:error];
}

@end
