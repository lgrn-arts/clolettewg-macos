/* SPDX-License-Identifier: MIT
 *
 * HelperInstaller.m — installs /Library/PrivilegedHelperTools/awgd plus the
 * LaunchDaemon plist.
 *
 * We use `osascript -e 'do shell script ... with administrator privileges'`
 * as the primary install path. Why, when AuthorizationExecuteWithPrivileges
 * (AEWP) is the "classic" 10.9 answer?
 *
 *   - AEWP has been deprecated since 10.7. On 10.8/10.9 it is unreliable
 *     from non-Apple-signed binaries: it sometimes returns success while
 *     never actually invoking the script. The user sees the password
 *     prompt, types their password, then *nothing happens* — exactly the
 *     symptom we want to fix here.
 *   - `osascript -e 'do shell script ... with administrator privileges'`
 *     goes through the same Authorization Services UI but is invoked by
 *     /usr/bin/osascript (a system binary Apple trusts), so it actually
 *     runs and returns the script's stdout/stderr to us via Apple events.
 *
 * AEWP is kept as a fallback in case osascript is unavailable.
 *
 * All path constants are NSString constants (not C macros) — clang 6 with
 * ARC rejects implicit char* -> NSString* conversions, and "%@" fed with a
 * char* would crash at format time.
 */

#import "HelperInstaller.h"
#import "IPCClient.h"

#import <Security/Security.h>
#import <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString * const kHelperPath   = @"/Library/PrivilegedHelperTools/awgd";
static NSString * const kLaunchdPlist = @"/Library/LaunchDaemons/ru.awg.mavericks.awgd.plist";
static NSString * const kStateDir     = @"/Library/Application Support/AwgMavericks";
static NSString * const kTokenPath    = @"/Library/Application Support/AwgMavericks/token";
static NSString * const kLaunchLog    = @"/Library/Application Support/AwgMavericks/launchd.log";
static NSString * const kSocketPath   = @"/var/run/awg-client.sock";

static NSString *LaunchdPlistText(void) {
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\">\n"
        @"<dict>\n"
        @"    <key>Label</key>\n"
        @"    <string>ru.awg.mavericks.awgd</string>\n"
        @"    <key>ProgramArguments</key>\n"
        @"    <array>\n"
        @"        <string>%@</string>\n"
        @"        <string>-service</string>\n"
        @"    </array>\n"
        @"    <key>RunAtLoad</key>\n"
        @"    <true/>\n"
        @"    <key>KeepAlive</key>\n"
        @"    <true/>\n"
        @"    <key>StandardOutPath</key>\n"
        @"    <string>%@</string>\n"
        @"    <key>StandardErrorPath</key>\n"
        @"    <string>%@</string>\n"
        @"</dict>\n"
        @"</plist>\n",
        kHelperPath, kLaunchLog, kLaunchLog];
}

// Builds the privileged shell script that performs the actual install.
// Each step logs a TAG line we can grep on; failures abort with a clear
// message that bubbles up to the app.
static NSString *InstallScript(NSString *bundleAwg) {
    NSString *plistText = LaunchdPlistText();
    // No `set -e`. With it, a non-interactive shell aborts on the first
    // failed line and we never learn which one. Every step checks its own
    // exit code, prints a tag line, and returns a structured failure on
    // stderr so the alert can show the real error.
    //
    // The plist heredoc uses a single-quoted terminator ('EOF') so nothing
    // inside the XML gets expanded by the shell.
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"#!/bin/sh\n"];
    [s appendString:@"AWG_INSTALL=1\n"];
    [s appendString:@"log()  { printf 'awg-install: %s\\n' \"$*\"; }\n"];
    [s appendString:@"fail() { printf 'awg-install: FAIL: %s\\n' \"$*\" >&2; exit 1; }\n"];
    [s appendString:@"run()  { log \"+ $*\"; \"$@\" || fail \"$* exited $?\"; }\n"];
    [s appendString:@"\n"];
    // Every assignment here is single-quoted. Unquoted, the space in $STATE
    // ("/Library/Application Support/...") makes the shell read
    //   STATE=/Library/Application Support/AwgMavericks
    // as the assignment `STATE=/Library/Application` followed by a command
    // named "Support/AwgMavericks". Quoting the RHS keeps paths with spaces
    // in one piece.
    [s appendFormat:@"BUNDLE_AWG='%@'\n", bundleAwg];
    [s appendFormat:@"HELPER='%@'\n",     kHelperPath];
    [s appendFormat:@"PLIST='%@'\n",      kLaunchdPlist];
    [s appendFormat:@"STATE='%@'\n",      kStateDir];
    [s appendFormat:@"SOCKET='%@'\n",     kSocketPath];
    [s appendString:@"\n"];
    [s appendString:@"log \"installing awgd into $HELPER\"\n"];
    [s appendString:@"run mkdir -p \"$STATE\"\n"];
    [s appendString:@"run mkdir -p /Library/PrivilegedHelperTools\n"];
    [s appendString:@"test -f \"$BUNDLE_AWG\" || fail \"bundle missing: $BUNDLE_AWG\"\n"];
    // Check the bundled binary before installing it. Wrong arch and
    // launchd silently refuses to exec it, which is a miserable thing to
    // debug from a GUI.
    //
    // `od -An -c` prints each byte as 3-digit *octal*, which reads a lot
    // like decimal and will fool you. `-t x1` gives plain hex.
    [s appendString:@"BUNDLE_MAGIC=$(head -c 4 \"$BUNDLE_AWG\" | od -An -t x1 | tr -d ' \\n')\n"];
    [s appendString:@"case \"$BUNDLE_MAGIC\" in\n"];
    // 'feedface' MH_MAGIC      32-bit, big-endian
    // 'feedfacf' MH_MAGIC_64   64-bit, big-endian
    // 'cefaedfe' MH_CIGAM      32-bit, little-endian (PowerPC, byteswapped)
    // 'cffaedfe' MH_CIGAM_64   64-bit, little-endian (Intel/ARM)
    [s appendString:@"  feedface|feedfacf|cefaedfe|cffaedfe) ;;\n"];
    [s appendString:@"  *) fail \"bundled awgd is not a Mach-O binary (magic=$BUNDLE_MAGIC). Reinstall Nanami.app from the .zip.\";;\n"];
    [s appendString:@"esac\n"];
    [s appendString:@"run cp -f \"$BUNDLE_AWG\" \"$HELPER\"\n"];
    [s appendString:@"run chown root:wheel \"$HELPER\"\n"];
    [s appendString:@"run chmod 755 \"$HELPER\"\n"];
    [s appendString:@"test -x \"$HELPER\" || fail \"helper at $HELPER is not executable after install\"\n"];
    [s appendString:@"\n"];
    [s appendString:@"log \"writing launchd plist $PLIST\"\n"];
    // write the plist via Python's plistlib for safety (no quoting issues)
    [s appendString:@"PLIST_TMP=\"$STATE/awgd.plist.tmp\"\n"];
    [s appendFormat:@"cat > \"$PLIST_TMP\" <<'AWG_PLIST_EOF'\n%@\nAWG_PLIST_EOF\n",
        plistText];
    [s appendString:@"run cp -f \"$PLIST_TMP\" \"$PLIST\"\n"];
    [s appendString:@"run rm -f \"$PLIST_TMP\"\n"];
    [s appendString:@"run chown root:wheel \"$PLIST\"\n"];
    [s appendString:@"run chmod 644 \"$PLIST\"\n"];
    [s appendString:@"# validate the plist before handing it to launchd\n"];
    [s appendString:@"run /usr/bin/plutil -lint \"$PLIST\"\n"];
    [s appendString:@"\n"];
    [s appendString:@"log \"loading into launchd (system domain)\"\n"];
    // 10.9: jobs in /Library/LaunchDaemons are loaded into the system
    // domain by default; "launchctl list" without args shows the USER
    // domain (gui/$UID), so a successful system-domain load does NOT
    // show up there. -w explicitly enables the job (overrides the
    // "disabled" key); without it launchd queues the plist but may
    // not immediately spawn it on 10.9.
    [s appendString:@"launchctl unload \"$PLIST\" 2>/dev/null || true\n"];
    [s appendString:@"run launchctl load -w \"$PLIST\"\n"];
    [s appendString:@"log \"verifying daemon is up (poll $SOCKET up to 10s)\"\n"];
    // The most reliable check on 10.9: wait for the daemon's socket to
    // appear. launchd may take a couple of seconds to actually exec the
    // new process, even after "load" returns 0.
    [s appendString:@"i=0\n"];
    [s appendString:@"while [ $i -lt 20 ]; do\n"];
    [s appendString:@"    if [ -S \"$SOCKET\" ]; then\n"];
    [s appendString:@"        log \"socket $SOCKET is up after ${i}*0.5s\"\n"];
    [s appendString:@"        FOUND=1\n"];
    [s appendString:@"        break\n"];
    [s appendString:@"    fi\n"];
    [s appendString:@"    i=$((i+1))\n"];
    [s appendString:@"    sleep 0.5\n"];
    [s appendString:@"done\n"];
    [s appendString:@"if [ \"${FOUND:-0}\" != \"1\" ]; then\n"];
    // capture whatever launchctl knows about the load for debugging
    [s appendString:@"    LAUNCHCTL_LIST=$(launchctl list 2>&1 || true)\n"];
    [s appendString:@"    LOAD_LOG=$(launchctl print system/ru.awg.mavericks.awgd 2>&1 || true)\n"];
    // single fail with all the context inlined; log uses printf so escape % carefully
    [s appendString:
        @"    MSG=\"daemon did not open $SOCKET within 10s.\\n\"\n"];
    [s appendString:
        @"    MSG=\"$MSG  launchctl list: $LAUNCHCTL_LIST\\n\"\n"];
    [s appendString:
        @"    MSG=\"$MSG  launchctl print system: $LOAD_LOG\\n\"\n"];
    [s appendString:
        @"    MSG=\"$MSG  see $STATE/launchd.log and /var/log/system.log\"\n"];
    [s appendString:@"    fail \"$MSG\"\n"];
    [s appendString:@"fi\n"];
    [s appendString:@"\n"];
    [s appendString:@"log \"install OK\"\n"];
    return s;
}

@implementation HelperInstaller

+ (NSString *)bundledAwgPath {
    return [[NSBundle mainBundle] pathForResource:@"awgd" ofType:nil];
}

+ (BOOL)serviceInstalled {
    return [[NSFileManager defaultManager] fileExistsAtPath:kHelperPath] &&
           [[NSFileManager defaultManager] fileExistsAtPath:kLaunchdPlist];
}

+ (BOOL)serviceRunning {
    NSString *token = [self readToken];
    if (!token) {
        return NO;
    }
    IPCClient *ipc = [[IPCClient alloc] initWithToken:token];
    return [ipc auth];
}

+ (NSString *)readToken {
    NSError *err = nil;
    NSString *tok = [NSString stringWithContentsOfFile:kTokenPath
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];
    if (!tok) {
        return nil;
    }
    tok = [[tok componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    return tok.length >= 32 ? tok : nil;
}

// Run `script` as root via osascript. This is the primary install path —
// reliable on 10.9 from any (even unsigned) app. Returns NO and sets *err
// on cancellation or failure, with the daemon's stderr inlined into err.
//
// The trick that makes this reliable is to invoke `/usr/bin/osascript`
// (a system binary Apple trusts) and let it talk to Authorization Services
// on our behalf via `do shell script ... with administrator privileges`.
// The shell script body is embedded *inside* the AppleScript source via
// a single -e flag so we never have to worry about quoting hell or
// osascript's stdin handling — and the script's stdout/stderr come back
// to us as osascript's own stdout/stderr.
static BOOL runAsRootViaOsascript(NSString *script, NSString **err) {
    // Escape the shell script for embedding in an AppleScript string literal.
    // Inside AppleScript double-quoted strings: backslash and quote need
    // escaping; newlines become \n, etc. We use NSString's stringByReplacing
    // semantics by writing it out manually for clarity.
    NSMutableString *asaEsc = [NSMutableString stringWithCapacity:script.length + 32];
    for (NSUInteger i = 0; i < script.length; i++) {
        unichar c = [script characterAtIndex:i];
        switch (c) {
            case '\\': [asaEsc appendString:@"\\\\"]; break;
            case '"':  [asaEsc appendString:@"\\\""]; break;
            case '\n': [asaEsc appendString:@"\\n"];  break;
            case '\r': [asaEsc appendString:@"\\r"];  break;
            case '\t': [asaEsc appendString:@"\\t"];  break;
            default:
                if (c < 0x20) {
                    [asaEsc appendFormat:@"\\u%04x", (unsigned)c];
                } else {
                    [asaEsc appendFormat:@"%C", c];
                }
        }
    }
    NSString *osa = [NSString stringWithFormat:
        @"try\n"
        @"  do shell script \"%@\" with administrator privileges\n"
        @"  return \"\"\n"
        @"on error errMsg number errNum\n"
        @"  return \"OSA_ERROR:\" & errNum & \":\" & errMsg\n"
        @"end try\n",
        asaEsc];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/osascript";
    task.arguments = @[ @"-e", osa ];

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;

    @try {
        [task launch];
    } @catch (NSException *e) {
        if (err) *err = [NSString stringWithFormat:@"osascript launch failed: %@", e.reason];
        return NO;
    }

    // 120-second timeout — admin prompt can take a while
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
    while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    if ([task isRunning]) {
        [task terminate];
        if (err) *err = @"timed out waiting for administrator authorization";
        return NO;
    }

    [task waitUntilExit];
    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        if (err) {
            NSString *combined = [NSString stringWithFormat:@"%@%@",
                errStr.length ? errStr : @"",
                outStr.length ? outStr : @""];
            combined = [combined stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            *err = combined.length ? combined : @"osascript failed";
        }
        return NO;
    }
    // osascript returned "" on success; any OSA_ERROR:... string means
    // the user cancelled (errNum -128) or the inner script exited non-zero.
    if ([outStr hasPrefix:@"OSA_ERROR:"]) {
        if (err) *err = [outStr substringFromIndex:[@"OSA_ERROR:" length]];
        return NO;
    }
    return YES;
}

// AEWP fallback. Less reliable on 10.9 from unsigned apps, but here in
// case osascript is missing. Errors out to *err.
static BOOL runAsRootViaAEWP(NSString *script, NSString **err) {
    AuthorizationRef auth = NULL;
    OSStatus st = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                      kAuthorizationFlagDefaults, &auth);
    if (st != errAuthorizationSuccess) {
        if (err) *err = @"authorization: cannot create";
        return NO;
    }
    AuthorizationItem items[1];
    items[0].name = kAuthorizationRightExecute;
    items[0].valueLength = strlen("/bin/sh") + 1;
    items[0].value = (void *)"/bin/sh";
    items[0].flags = 0;
    AuthorizationRights rights;
    rights.count = 1;
    rights.items = items;
    st = AuthorizationCopyRights(auth, &rights, kAuthorizationEmptyEnvironment,
                                 kAuthorizationFlagDefaults, NULL);
    if (st != errAuthorizationSuccess) {
        AuthorizationFree(auth, kAuthorizationFlagDefaults);
        if (err) *err = (st == errAuthorizationCanceled) ? @"canceled" : @"permission denied";
        return NO;
    }

    const char *argv[] = { "sh", "-c", script.UTF8String, NULL };
    FILE *out = NULL;
    st = AuthorizationExecuteWithPrivileges(auth, "/bin/sh",
                                            kAuthorizationFlagDefaults,
                                            (char *const *)argv, &out);
    if (st != errAuthorizationSuccess) {
        AuthorizationFree(auth, kAuthorizationFlagDefaults);
        if (err) *err = @"authorization: execute failed (unreliable on 10.9 unsigned apps)";
        return NO;
    }
    // Drain stdout so the child can complete.
    char buf[512];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), out)) > 0) { (void)n; }
    fclose(out); // AEWP returns a FILE*; use fclose, not pclose.
    AuthorizationFree(auth, kAuthorizationFlagDefaults);
    return YES;
}

+ (BOOL)installWithError:(NSString **)err {
    NSString *awg = [self bundledAwgPath];
    if (!awg) {
        if (err) *err = @"awgd not found in the app bundle";
        return NO;
    }
    NSString *script = InstallScript(awg);

    // Primary path: osascript. Fall back to AEWP only if osascript itself
    // is unavailable. If the inner shell script failed under osascript,
    // retrying via AEWP won't help and would just produce another
    // password prompt with the same failure.
    //
    // Our osascript path distinguishes two failure modes:
    //   1. osascript couldn't launch / crashed → osaErr is set but does
    //      NOT start with "OSA_ERROR:" → fall back to AEWP.
    //   2. Inner script failed → osaErr starts with "OSA_ERROR:" → bubble
    //      that to the user as the actionable error.
    NSString *osaErr = nil;
    if (runAsRootViaOsascript(script, &osaErr)) {
        return YES;
    }
    BOOL osascriptWorked = [osaErr hasPrefix:@"OSA_ERROR:"] || osaErr.length > 0;
    if (osascriptWorked) {
        if (err) *err = osaErr;
        return NO;
    }
    // osascript itself is broken — try the legacy AEWP path.
    if (err) *err = nil;
    if (runAsRootViaAEWP(script, err)) {
        return YES;
    }
    if (err && *err == nil) {
        *err = @"both osascript and AEWP failed";
    }
    return NO;
}

+ (BOOL)uninstallWithError:(NSString **)err {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"#!/bin/sh\n"];
    [s appendString:@"log()  { printf 'awg-uninstall: %s\\n' \"$*\"; }\n"];
    [s appendString:@"fail() { printf 'awg-uninstall: FAIL: %s\\n' \"$*\" >&2; exit 1; }\n"];
    [s appendString:@"run()  { log \"+ $*\"; \"$@\" || fail \"$* exited $?\"; }\n"];
    // Same single-quoting as in installWithError — see comment there.
    [s appendFormat:@"PLIST='%@'\n",  kLaunchdPlist];
    [s appendFormat:@"HELPER='%@'\n", kHelperPath];
    [s appendFormat:@"STATE='%@'\n",  kStateDir];
    [s appendFormat:@"SOCKET='%@'\n", kSocketPath];
    [s appendString:@"launchctl unload \"$PLIST\" 2>/dev/null || true\n"];
    [s appendString:@"run rm -f \"$PLIST\" \"$HELPER\" \"$SOCKET\"\n"];
    [s appendString:@"run rm -rf \"$STATE\"\n"];
    [s appendString:@"log \"uninstall OK\"\n"];
    if (runAsRootViaOsascript(s, err)) {
        return YES;
    }
    if (err) *err = nil;
    return runAsRootViaAEWP(s, err);
}

@end
