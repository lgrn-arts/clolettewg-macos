/* SPDX-License-Identifier: MIT
 *
 * AppDelegate.m — the Nanami UI.
 *
 * No nib files, so everything here is built by hand and laid out with
 * explicit frames. ARC is on.
 *
 * Everything must exist in the 10.9 SDK. In practice that rules out:
 *   +[NSButton buttonWithTitle:...] and +[NSTextField labelWithString:]
 *       10.12+, so use initWithFrame
 *   NSStatusItem.button               10.10+, so use -setTitle
 *   NSColor.labelColor and friends    10.10+, so use colorWithCalibratedWhite
 *   -[NSTextField setAlignment:]      not on NSTextField in the 10.9 SDK,
 *                                     so centre by arithmetic
 * If you're used to writing for a modern SDK, those are the ones that bite.
 */

#import "AppDelegate.h"
#import "IPCClient.h"
#import "TunnelStore.h"
#import "HelperInstaller.h"

#import <objc/runtime.h>
#import <time.h>

// About panel credit. Change this one string to re-brand.
static NSString *const kCreditLine = @"Brought to you by TCD";

// ---- small constructors (10.9-safe) ------------------------------------

static NSButton *MakeButton(NSString *title, SEL action, id target, NSRect frame) {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    [b setTitle:title];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setButtonType:NSMomentaryPushInButton];
    [b setTarget:target];
    [b setAction:action];
    return b;
}

static NSTextField *MakeLabel(NSString *text, NSRect frame) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    [f setStringValue:text];
    [f setEditable:NO];
    [f setSelectable:NO];
    [f setBordered:NO];
    [f setBezeled:NO];
    [f setDrawsBackground:NO];
    return f;
}

@interface AppDelegate ()

@property (strong) NSWindow *window;

@property (strong) NSTableView *tunnelTable;
@property (strong) NSButton *connectButton;
@property (strong) NSTextField *statusField;
@property (strong) NSProgressIndicator *spinner;
@property (strong) NSTextField *detailField;
@property (strong) NSTextView *logView;
@property (strong) NSTextField *serviceField;
@property (strong) NSButton *installButton;
@property (strong) NSButton *uninstallButton;
@property (strong) NSButton *addButton;
@property (strong) NSButton *editButton;
@property (strong) NSButton *removeButton;
@property (strong) NSButton *keysButton;
@property (strong) NSButton *diagButton;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *statusMenu;
// Greyed-out first line of the menu bar menu, shows the current state.
@property (strong) NSMenuItem *statusMenuTitle;
// "Connect to ▸" submenu listing every saved tunnel.
@property (strong) NSMenuItem *tunnelsMenuItem;
// Built once at startup. refreshStatusItem fires every 2s, so it only swaps
// between these two rather than re-rendering.
@property (strong) NSImage *menuIconActive;
@property (strong) NSImage *menuIconIdle;
// Sits over the tunnel list when it's empty.
@property (strong) NSTextField *emptyHint;

@property (copy) NSString *token;
@property (copy) NSString *activeTunnel;
// Live endpoint, so diagnostics can run `route -n get` against it.
@property (copy) NSString *lastEndpoint;
@property (copy) NSString *lastState;
@property (strong) NSTimer *pollTimer;
@property (assign) BOOL busy;

@end

@implementation AppDelegate

// ------------------------------------------------------------------ app

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    [self buildMainMenu];
    [self buildWindow];
    [self buildStatusItem];
    [self refreshServiceState];
    [self reloadTunnels];
    [self updateControls];

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(pollTick)
                                                    userInfo:nil
                                                     repeats:YES];
    [self pollTick];

    [self maybeShowFirstRunGuide];
}

// On a fresh Mac there's nothing installed and nothing imported, so you get
// an empty list and a Connect button that does nothing. Walk through the two
// steps that actually matter instead.
- (void)maybeShowFirstRunGuide {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:@"NanamiDidShowWelcome"]) {
        return;
    }
    // Otherwise leave them alone.
    if ([[TunnelStore sharedStore] tunnelNames].count > 0 ||
        [HelperInstaller serviceInstalled]) {
        [ud setBool:YES forKey:@"NanamiDidShowWelcome"];
        return;
    }
    [ud setBool:YES forKey:@"NanamiDidShowWelcome"];

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Welcome to Nanami";
    a.informativeText = @"Nanami connects this Mac to AmneziaWG servers.\n\n"
                        @"Two quick steps:\n"
                        @"1. Install the system service — it asks for your "
                        @"password once and runs in the background.\n"
                        @"2. Import a .conf file from your provider, select it, "
                        @"and press Connect.\n\n"
                        @"Install the system service now?";
    [a addButtonWithTitle:@"Install"];
    [a addButtonWithTitle:@"Not now"];
    if ([a runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    [self installService:nil];
    // Step two, if the install worked and there is still nothing to connect to.
    if ([HelperInstaller serviceInstalled] &&
        [[TunnelStore sharedStore] tunnelNames].count == 0) {
        [self addTunnel:nil];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    (void)app;
    if (!visible) {
        [self.window makeKeyAndOrderFront:nil];
    }
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    (void)note;
    [self.pollTimer invalidate];
}

- (void)pollTick {
    if (self.busy) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
        AWGStatus *st = [ipc status];
        NSArray *logs = [ipc logLines:120];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyStatus:st logs:logs];
        });
    });
}

- (void)applyStatus:(AWGStatus *)st logs:(NSArray *)logs {
    NSString *state = st.state ?: @"disconnected";
    BOOL changed = ![state isEqualToString:self.lastState];
    self.lastState = state;

    // Only rebuild the tunnels submenu when the live tunnel actually changes —
    // doing it on every poll would thrash a menu the user has open.
    NSString *prevActive = self.activeTunnel;
    if (![st.name isEqualToString:(prevActive ?: @"")]) {
        self.activeTunnel = st.name;
        [self rebuildTunnelsSubmenu];
    }

    self.statusField.stringValue = [st stateText];
    [self.spinner stopAnimation:nil];
    [self.spinner setHidden:YES];

    NSMutableString *detail = [NSMutableString string];
    if (![state isEqualToString:@"disconnected"]) {
        if (st.endpoint) {
            [detail appendFormat:@"Server: %@\n", st.endpoint];
        }
        if (st.handshake > 0) {
            // "3s ago" reads far better than a bare clock time, and makes a
            // stalled tunnel obvious at a glance.
            NSTimeInterval ago =
                [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)st.handshake;
            if (ago < 0) {
                ago = 0;
            }
            NSString *rel;
            if (ago < 5) {
                rel = @"just now";
            } else if (ago < 90) {
                rel = [NSString stringWithFormat:@"%.0f seconds ago", ago];
            } else if (ago < 5400) {
                rel = [NSString stringWithFormat:@"%.0f minutes ago", ago / 60.0];
            } else {
                rel = [NSString stringWithFormat:@"%.1f hours ago", ago / 3600.0];
            }
            [detail appendFormat:@"Last handshake: %@\n", rel];
        } else {
            [detail appendString:@"Handshake: not yet\n"];
        }
        [detail appendFormat:@"Sent: %@   Received: %@",
            [self bytesText:st.txBytes], [self bytesText:st.rxBytes]];
        self.activeTunnel = st.name;
        // st.endpoint is "host:port"; diagnostics only needs the address.
        self.lastEndpoint = st.endpoint ?: nil;
    } else {
        self.activeTunnel = nil;
        self.lastEndpoint = nil;
    }
    self.detailField.stringValue = detail;

    [self updateControls];

    if (changed || logs) {
        [self renderLog:logs];
        [self refreshStatusItem];
    }
}

- (NSString *)bytesText:(long long)b {
    if (b < 1024) return [NSString stringWithFormat:@"%lld B", b];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    if (b < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", b / 1073741824.0];
}

- (void)renderLog:(NSArray *)logs {
    NSMutableString *text = [NSMutableString string];
    if (logs.count == 0) {
        [text appendString:@"(no service log yet)"];
    } else {
        for (NSString *ln in logs) {
            [text appendFormat:@"%@\n", ln];
        }
    }
    [self.logView setString:text];
    NSRange end = NSMakeRange([[self.logView string] length], 0);
    [self.logView scrollRangeToVisible:end];
}

// ------------------------------------------------------------------ actions

- (void)toggleConnect:(id)sender {
    (void)sender;
    if (self.busy) {
        return;
    }
    BOOL active = [self.lastState isEqualToString:@"connected"] ||
                  [self.lastState isEqualToString:@"connecting"];
    if (!active) {
        NSString *sel = [self selectedTunnel];
        if (!sel) {
            [self alert:@"No tunnel selected" text:@"Import a .conf file first (＋ Import)."];
            return;
        }
        [self connectToTunnel:sel];
    } else {
        [self disconnectWithCompletion:nil];
    }
}

// Brings a named tunnel up. Split out of toggleConnect so the menu bar can
// connect to an arbitrary tunnel without driving the table selection.
- (void)connectToTunnel:(NSString *)name {
    NSString *conf = [[TunnelStore sharedStore] confForTunnel:name];
    if (!conf) {
        return;
    }
    if (![self ensureService]) {
        return;
    }
    self.busy = YES;
    [self.spinner startAnimation:nil];
    [self.spinner setHidden:NO];
    self.statusField.stringValue = @"Connecting…";
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
        NSString *err = nil;
        [ipc upTunnel:name conf:conf error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self.spinner stopAnimation:nil];
            [self.spinner setHidden:YES];
            if (err) {
                self.statusField.stringValue = @"Failed";
                [self alert:[NSString stringWithFormat:@"Could not connect to %@", name] text:err];
            }
            [self updateControls];
            [self pollTick];
        });
    });
}

// Tears the current tunnel down. The completion runs on the main queue after
// the daemon has answered, which lets the caller chain a fresh connect.
- (void)disconnectWithCompletion:(void (^)(void))completion {
    self.busy = YES;
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
        [ipc down];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self updateControls];
            [self pollTick];
            if (completion) {
                completion();
            }
        });
    });
}

// Menu bar: connect to a chosen tunnel, switching away from the live one.
- (void)statusConnectTunnel:(id)sender {
    NSString *name = [sender representedObject];
    if (!name || self.busy) {
        return;
    }
    if ([name isEqualToString:(self.activeTunnel ?: @"")]) {
        [self disconnectWithCompletion:nil];
        return;
    }
    // keep the table in step with the menu
    NSUInteger idx = [[[TunnelStore sharedStore] tunnelNames] indexOfObject:name];
    if (idx != NSNotFound) {
        [self.tunnelTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSInteger)idx]
                     byExtendingSelection:NO];
    }
    BOOL active = [self.lastState isEqualToString:@"connected"] ||
                  [self.lastState isEqualToString:@"connecting"];
    if (active) {
        [self disconnectWithCompletion:^{
            [self connectToTunnel:name];
        }];
    } else {
        [self connectToTunnel:name];
    }
}

- (void)addTunnel:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel setAllowedFileTypes:[NSArray arrayWithObjects:@"conf", @"awg", @"txt", nil]];
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton) {
            return;
        }
        NSArray *urls = [panel URLs];
        NSURL *pickedURL = [urls count] > 0 ? [urls firstObject] : nil;
        NSString *path = [pickedURL path];
        if (path) {
            [self importFile:path];
        }
    }];
}

- (void)importFile:(NSString *)path {
    NSError *rdErr = nil;
    NSString *conf = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&rdErr];
    if (!conf) {
        [self alert:@"Cannot read file" text:rdErr.localizedDescription];
        return;
    }
    BOOL ok = NO;
    NSString *verr = [self validateConfText:conf ok:&ok];
    if (!ok) {
        [self alert:@"Invalid configuration" text:verr ?: @"unknown error"];
        return;
    }
    NSString *base = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *name = [[TunnelStore sharedStore] uniqueNameForBase:base];
    [[TunnelStore sharedStore] saveTunnel:name conf:conf];
    [self reloadTunnels];
}

- (void)editTunnel:(id)sender {
    (void)sender;
    NSString *sel = [self selectedTunnel];
    if (!sel) {
        return;
    }
    NSString *conf = [[TunnelStore sharedStore] confForTunnel:sel];
    if (!conf) {
        return;
    }
    [self presentEditorForName:sel conf:conf];
}

- (void)removeTunnel:(id)sender {
    (void)sender;
    NSString *sel = [self selectedTunnel];
    if (!sel) {
        return;
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"Delete tunnel “%@”?", sel];
    a.informativeText = @"The configuration will be removed from this Mac.";
    [a addButtonWithTitle:@"Delete"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    [[TunnelStore sharedStore] removeTunnel:sel];
    [self reloadTunnels];
}

- (void)generateKeys:(id)sender {
    (void)sender;
    BOOL ok = NO;
    NSString *priv = [self runBundledAwg:@[ @"-genkey" ] stdin:nil ok:&ok];
    if (!ok) {
        [self alert:@"Key generation failed" text:priv ?: @"Could not run the bundled awgd."];
        return;
    }
    NSString *pub = [self runBundledAwg:@[ @"-pubkey" ] stdin:priv ok:&ok];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"New key pair";
    a.informativeText = [NSString stringWithFormat:
        @"Private key:\n%@\n\nPublic key:\n%@", priv, (ok && pub) ? pub : @"(error)"];
    [a addButtonWithTitle:@"Copy Public Key"];
    [a addButtonWithTitle:@"Done"];
    if ([a runModal] == NSAlertFirstButtonReturn && pub) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:pub forType:NSPasteboardTypeString];
    }
}

// Runs a helper tool and returns its combined output. Only used for
// diagnostics, so a failure here is never fatal.
- (NSString *)runTool:(NSString *)path args:(NSArray *)args {
    NSTask *t = [[NSTask alloc] init];
    [t setLaunchPath:path];
    [t setArguments:args];
    NSPipe *p = [NSPipe pipe];
    [t setStandardOutput:p];
    [t setStandardError:p];
    @try {
        [t launch];
    }
    @catch (NSException *e) {
        return @"(could not run)\n";
    }
    // NSPipe exposes -fileHandleForReading / -fileHandleForWriting (with the
    // -ing); there is no -fileHandleForRead.
    NSData *data = [[p fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

// Puts a support bundle on the clipboard: versions, service state, routing
// table, tail of the log. Nothing sensitive in it apart from tunnel names.
- (void)copyDiagnostics:(id)sender {
    (void)sender;
    NSMutableString *d = [NSMutableString string];

    NSString *appVer =
        [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: @"?";
    [d appendFormat:@"Nanami %@ — OS X %@\n",
        appVer, [[NSProcessInfo processInfo] operatingSystemVersionString]];

    BOOL ok = NO;
    NSString *awgdVer = [self runBundledAwg:@[ @"-version" ] stdin:nil ok:&ok];
    [d appendFormat:@"Engine: %@\n\n",
        (ok && awgdVer.length) ? awgdVer : @"(could not run bundled awgd)"];

    [d appendFormat:@"System service: %@\n",
        [HelperInstaller serviceInstalled] ? @"installed" : @"NOT installed"];
    [d appendFormat:@"Auth token: %@\n", self.token ? @"loaded" : @"MISSING"];
    [d appendFormat:@"State: %@\n", self.lastState ?: @"unknown"];
    [d appendFormat:@"Active tunnel: %@\n", self.activeTunnel ?: @"(none)"];
    [d appendFormat:@"Saved tunnels: %lu\n\n",
        (unsigned long)[[TunnelStore sharedStore] tunnelNames].count];

    // The routing table is the usual culprit when a tunnel comes up but the
    // handshake never completes, so always include it.
    [d appendString:@"--- default route ---\n"];
    [d appendString:[self runTool:@"/sbin/route" args:@[ @"-n", @"get", @"default" ]]];

    NSString *ep = self.lastEndpoint;
    if (ep.length) {
        // st.endpoint arrives as "host:port"; route(8) wants a bare address.
        NSString *host = [[ep componentsSeparatedByString:@":"] firstObject] ?: ep;
        [d appendFormat:@"\n--- route to endpoint %@ ---\n", ep];
        [d appendString:[self runTool:@"/sbin/route" args:@[ @"-n", @"get", host ]]];
    }

    [d appendString:@"\n--- service log (tail) ---\n"];
    IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
    for (NSString *ln in [ipc logLines:80]) {
        [d appendFormat:@"%@\n", ln];
    }

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:d forType:NSPasteboardTypeString];

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Diagnostics copied";
    a.informativeText = @"Version, service state, routing table and the recent "
                        @"service log are on the clipboard. Paste into a message.";
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

- (void)installService:(id)sender {
    (void)sender;
    self.busy = YES;
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *err = nil;
        BOOL ok = [HelperInstaller installWithError:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!ok) {
                [self alert:@"Install failed" text:err ?: @"unknown"];
            }
            [self refreshServiceState];
            [self pollTick];
        });
    });
}

- (void)uninstallService:(id)sender {
    (void)sender;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Remove the system service?";
    a.informativeText = @"The background daemon will be unloaded and deleted; any active tunnel goes down.";
    [a addButtonWithTitle:@"Remove"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    self.busy = YES;
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
        [ipc down];
        NSString *err = nil;
        [HelperInstaller uninstallWithError:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self refreshServiceState];
            [self updateControls];
        });
    });
}

// ------------------------------------------------------------------ helpers

- (NSString *)selectedTunnel {
    NSInteger row = self.tunnelTable.selectedRow;
    if (row < 0) {
        return nil;
    }
    NSArray *names = [[TunnelStore sharedStore] tunnelNames];
    if ((NSUInteger)row >= names.count) {
        return nil;
    }
    return names[row];
}

- (void)reloadTunnels {
    [self.tunnelTable reloadData];
    NSUInteger count = [[TunnelStore sharedStore] tunnelNames].count;
    if (self.emptyHint) {
        [self.emptyHint setHidden:(count > 0)];
    }
    [self rebuildTunnelsSubmenu];
    if (self.tunnelTable.selectedRow < 0 && count > 0) {
        [self.tunnelTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                     byExtendingSelection:NO];
    }
    [self updateControls];
}

- (void)updateControls {
    BOOL connecting = [self.lastState isEqualToString:@"connecting"];
    BOOL connected  = [self.lastState isEqualToString:@"connected"];
    BOOL active = connecting || connected;
    BOOL hasSel = [self selectedTunnel] != nil;
    BOOL service = [HelperInstaller serviceInstalled] && self.token != nil;

    self.connectButton.title = active ? @"Disconnect" : @"Connect";
    self.connectButton.enabled = !self.busy && (active || (service && hasSel));
    self.addButton.enabled = !self.busy;
    self.editButton.enabled = !self.busy && hasSel;
    self.removeButton.enabled = !self.busy && hasSel;
    self.keysButton.enabled = !self.busy;
    self.installButton.enabled = !self.busy;
    self.uninstallButton.enabled = !self.busy && [HelperInstaller serviceInstalled];

    NSString *selTitle = [self selectedTunnel] ?: @"—";
    self.window.title = [NSString stringWithFormat:
        @"Nanami — %@ · %@", selTitle, self.lastState ?: @"disconnected"];
    [self refreshStatusItem];
}

- (void)refreshServiceState {
    self.token = [HelperInstaller readToken];
    if ([HelperInstaller serviceInstalled]) {
        IPCClient *ipc = [[IPCClient alloc] initWithToken:self.token];
        BOOL running = [ipc auth];
        self.serviceField.stringValue = running
            ? @"System service: installed and running"
            : @"System service: installed, but not responding";
    } else {
        self.serviceField.stringValue = @"System service: not installed";
    }
    [self updateControls];
}

- (BOOL)ensureService {
    if ([HelperInstaller serviceInstalled] && self.token) {
        return YES;
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"The system service is not installed";
    a.informativeText = @"Install it now? You will be asked for the administrator password once.";
    [a addButtonWithTitle:@"Install"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) {
        return NO;
    }
    NSString *err = nil;
    BOOL ok = [HelperInstaller installWithError:&err];
    [self refreshServiceState];
    if (!ok) {
        [self alert:@"Install failed" text:err ?: @"unknown"];
    }
    return ok;
}

// Runs the awgd binary bundled in the app. On success returns trimmed stdout
// and sets *okOut to YES; on failure returns stderr text and *okOut = NO.
- (NSString *)runBundledAwg:(NSArray *)args stdin:(NSString *)input ok:(BOOL *)okOut {
    if (okOut) {
        *okOut = NO;
    }
    NSString *awg = [HelperInstaller bundledAwgPath];
    if (!awg) {
        return @"awgd helper binary not found in the app bundle";
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = awg;
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    NSPipe *inPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    if (input) {
        [[inPipe fileHandleForWriting] writeData:[input dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [[inPipe fileHandleForWriting] closeFile];
    [task launch];
    NSData *out = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *outText = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus == 0) {
        if (okOut) {
            *okOut = YES;
        }
        return [outText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *errText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    return errText.length ? errText : @"unknown error";
}

- (NSString *)validateConfText:(NSString *)conf ok:(BOOL *)okOut {
    // -validate reads a file path; pass the text via stdin using /dev/stdin
    return [self runBundledAwg:@[ @"-validate", @"/dev/stdin" ] stdin:conf ok:okOut];
}

- (void)alert:(NSString *)title text:(NSString *)text {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = text ?: @"";
    [a runModal];
}

// ------------------------------------------------------------------ editor sheet

- (void)presentEditorForName:(NSString *)name conf:(NSString *)conf {
    NSRect frame = NSMakeRect(0, 0, 560, 420);
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:frame
                        styleMask:NSTitledWindowMask | NSClosableWindowMask
                          backing:NSBackingStoreBuffered
                            defer:NO];
    [sheet setTitle:[NSString stringWithFormat:@"Edit — %@", name]];

    NSRect textFrame = NSMakeRect(12, 46, frame.size.width - 24, frame.size.height - 58);

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:textFrame];
    [sv setHasVerticalScroller:YES];
    [sv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSTextView *tv = [[NSTextView alloc] initWithFrame:[[sv contentView] bounds]];
    [tv setString:conf];
    [tv setFont:[NSFont userFixedPitchFontOfSize:12]];
    [tv setRichText:NO];
    [tv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [sv setDocumentView:tv];

    NSButton *save = MakeButton(@"Save", @selector(editorSave:), self,
        NSMakeRect(frame.size.width - 176, 10, 80, 28));
    save.autoresizingMask = NSViewMinXMargin;
    NSButton *cancel = MakeButton(@"Cancel", @selector(editorCancel:), self,
        NSMakeRect(frame.size.width - 90, 10, 80, 28));
    cancel.autoresizingMask = NSViewMinXMargin;

    [[sheet contentView] addSubview:sv];
    [[sheet contentView] addSubview:save];
    [[sheet contentView] addSubview:cancel];

    objc_setAssociatedObject(sheet, "editorText", tv, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(sheet, "editorName", name, OBJC_ASSOCIATION_RETAIN);

    [self.window beginSheet:sheet completionHandler:nil];
}

- (void)editorSave:(id)sender {
    NSWindow *sheet = ((NSView *)sender).window;
    NSTextView *tv = objc_getAssociatedObject(sheet, "editorText");
    NSString *name = objc_getAssociatedObject(sheet, "editorName");
    NSString *text = [tv string] ?: @"";
    [self.window endSheet:sheet];

    BOOL ok = NO;
    NSString *verr = [self validateConfText:text ok:&ok];
    if (!ok) {
        [self alert:@"Invalid configuration" text:verr ?: @"unknown error"];
        return;
    }
    [[TunnelStore sharedStore] saveTunnel:name conf:text];
    [self reloadTunnels];
}

- (void)editorCancel:(id)sender {
    NSWindow *sheet = ((NSView *)sender).window;
    [self.window endSheet:sheet];
}

// ------------------------------------------------------------------ menus

// No nib file is used, so the menu bar is built in code (10.9-safe).
- (void)buildMainMenu {
    NSMenu *menubar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Nanami" action:nil keyEquivalent:@""];
    [menubar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About Nanami" action:@selector(showAbout:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Nanami" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Nanami" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [menubar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] init];
    [editMenu setTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu];

    NSMenuItem *winItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    [menubar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winItem setSubmenu:winMenu];

    [NSApp setMainMenu:menubar];
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Nanami";
    a.informativeText = @"AmneziaWG (obfuscated WireGuard) client for OS X 10.9 Mavericks.\n"
                        @"Version 1.4 — engine awgd 1.4.\n\n"
                        @"Engine: awgd (Go port of wireguard-go + AmneziaWG obfuscation).\n"
                        @"License: GPLv2 (engine), MIT (original AmneziaWG/wireguard-go code).";

    // Credit gets its own view, since NSAlert won't style part of
    // informativeText differently. Centred by arithmetic because
    // -setAlignment: isn't on NSTextField in the 10.9 SDK.
    const CGFloat accW = 340;
    NSTextField *credit =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 4, accW, 16)];
    [credit setStringValue:kCreditLine];
    [credit setBezeled:NO];
    [credit setDrawsBackground:NO];
    [credit setEditable:NO];
    [credit setSelectable:NO];
    [credit setFont:[NSFont systemFontOfSize:11]];
    [credit setTextColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1.0]];
    [credit sizeToFit];
    {
        NSRect cf = [credit frame];
        cf.origin.x = (accW - cf.size.width) / 2.0;
        [credit setFrame:cf];
    }

    NSView *acc = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, accW, [credit frame].size.height + 8)];
    [acc addSubview:credit];
    [a setAccessoryView:acc];

    [a runModal];
}

// ------------------------------------------------------------------ UI construction

- (void)buildWindow {
    NSRect winFrame = NSMakeRect(0, 0, 780, 520);
    self.window = [[NSWindow alloc] initWithContentRect:winFrame
                        styleMask:NSTitledWindowMask | NSClosableWindowMask |
                                  NSMiniaturizableWindowMask | NSResizableWindowMask
                          backing:NSBackingStoreBuffered
                            defer:NO];
    [self.window setTitle:@"Nanami"];
    [self.window center];
    NSView *root = [self.window contentView];

    // --- left: tunnel list ---
    CGFloat topY = winFrame.size.height - 44;
    self.addButton    = MakeButton(@"＋ Import", @selector(addTunnel:),    self, NSMakeRect(16,  topY, 86, 26));
    self.editButton   = MakeButton(@"Edit",      @selector(editTunnel:),   self, NSMakeRect(108, topY, 50, 26));
    self.removeButton = MakeButton(@"－",         @selector(removeTunnel:), self, NSMakeRect(162, topY, 36, 26));
    self.keysButton   = MakeButton(@"Keys…",     @selector(generateKeys:), self, NSMakeRect(202, topY, 64, 26));

    NSRect listFrame = NSMakeRect(16, 56, 250, winFrame.size.height - 112);
    NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:listFrame];
    [listScroll setHasVerticalScroller:YES];
    [listScroll setBorderType:NSBezelBorder];
    [listScroll setAutoresizingMask:NSViewHeightSizable];

    self.tunnelTable = [[NSTableView alloc] initWithFrame:listScroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [col setWidth:220];
    [self.tunnelTable addTableColumn:col];
    [self.tunnelTable setHeaderView:nil];
    [self.tunnelTable setDelegate:self];
    [self.tunnelTable setDataSource:self];
    [self.tunnelTable setAllowsEmptySelection:NO];
    [self.tunnelTable setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [listScroll setDocumentView:self.tunnelTable];

    // Empty-state hint, centred over the list, hidden once a tunnel exists.
    // Kept to one line: MakeLabel gives a plain NSTextField, which clips, and
    // making it wrap needs NSCell calls I can't compile-check against 10.9.
    self.emptyHint = MakeLabel(@"No tunnels yet — use ＋ Import",
        NSMakeRect(listFrame.origin.x + 4, listFrame.origin.y + 40,
                   listFrame.size.width - 8, 20));
    [self.emptyHint setFont:[NSFont systemFontOfSize:12]];
    [self.emptyHint setTextColor:[NSColor colorWithCalibratedWhite:0.45 alpha:1.0]];
    self.emptyHint.autoresizingMask = NSViewMinYMargin;

    // --- right: status pane ---
    CGFloat rx = 284, rw = winFrame.size.width - rx - 16;

    self.statusField = MakeLabel(@"Disconnected", NSMakeRect(rx, winFrame.size.height - 64, rw - 130, 22));
    [self.statusField setFont:[NSFont boldSystemFontOfSize:16]];
    self.statusField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    self.connectButton = MakeButton(@"Connect", @selector(toggleConnect:), self,
        NSMakeRect(winFrame.size.width - 140, winFrame.size.height - 70, 124, 34));
    [self.connectButton setKeyEquivalent:@"\r"];
    self.connectButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:
        NSMakeRect(winFrame.size.width - 162, winFrame.size.height - 62, 18, 18)];
    [self.spinner setStyle:NSProgressIndicatorSpinningStyle];
    [self.spinner setHidden:YES];
    self.spinner.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;

    self.detailField = MakeLabel(@"", NSMakeRect(rx, winFrame.size.height - 158, rw, 84));
    [self.detailField setFont:[NSFont systemFontOfSize:12]];
    [self.detailField setTextColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
    self.detailField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    NSBox *logBox = [[NSBox alloc] initWithFrame:NSMakeRect(rx, 56, rw, winFrame.size.height - 224)];
    [logBox setTitle:@"Service log"];
    logBox.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSScrollView *logScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [logScroll setHasVerticalScroller:YES];
    [logScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    self.logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, logBox.bounds.size.width - 30, 200)];
    [self.logView setEditable:NO];
    [self.logView setRichText:NO];
    [self.logView setFont:[NSFont userFixedPitchFontOfSize:11]];
    self.logView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [logScroll setDocumentView:self.logView];
    [logBox setContentView:logScroll];

    // --- bottom bar ---
    self.serviceField = MakeLabel(@"System service: not installed",
        NSMakeRect(16, 20, 340, 18));
    [self.serviceField setFont:[NSFont systemFontOfSize:11]];
    [self.serviceField setTextColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1.0]];
    self.serviceField.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;

    self.installButton = MakeButton(@"Install…", @selector(installService:), self,
        NSMakeRect(winFrame.size.width - 250, 14, 90, 26));
    self.installButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.uninstallButton = MakeButton(@"Uninstall", @selector(uninstallService:), self,
        NSMakeRect(winFrame.size.width - 154, 14, 90, 26));
    self.uninstallButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;

    self.diagButton = MakeButton(@"Copy Diagnostics", @selector(copyDiagnostics:), self,
        NSMakeRect(winFrame.size.width - 300, 14, 140, 26));
    self.diagButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;

    NSArray *views = @[ self.addButton, self.editButton, self.removeButton, self.keysButton,
                        listScroll, self.statusField, self.connectButton, self.spinner,
                        self.detailField, logBox, self.serviceField,
                        self.installButton, self.uninstallButton, self.diagButton,
                        self.emptyHint ];
    for (NSView *v in views) {
        [root addSubview:v];
    }

    [self.window makeKeyAndOrderFront:nil];
}

// ------------------------------------------------------------------ status item

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusMenu = [[NSMenu alloc] init];

    // App icon in the menu bar instead of a text abbreviation.
    // NSApplicationIcon is the bundled Nanami.icns; copy before resizing so
    // we don't resize the shared cached image in place.
    NSImage *src = [[NSImage imageNamed:@"NSApplicationIcon"] copy];
    if (src) {
        [src setSize:NSMakeSize(16, 16)];
        self.menuIconActive = src;

        NSImage *faded = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [faded lockFocus];
        [src drawInRect:NSMakeRect(0, 0, 16, 16)
               fromRect:NSZeroRect
              operation:NSCompositeSourceOver
               fraction:0.45];
        [faded unlockFocus];
        self.menuIconIdle = faded;
    } else {
        // Running unbundled (e.g. straight from the toolchain): fall back.
        [self.statusItem setTitle:@"Nanami"];
    }

    // Live status as the first, disabled, menu line.
    self.statusMenuTitle = [[NSMenuItem alloc] initWithTitle:@"Not connected"
                                                      action:nil keyEquivalent:@""];
    [self.statusMenuTitle setEnabled:NO];
    [self.statusMenu addItem:self.statusMenuTitle];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    // Tunnels submenu, rebuilt whenever the store changes.
    self.tunnelsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Connect to" action:nil keyEquivalent:@""];
    NSMenu *tunSub = [[NSMenu alloc] init];
    [self.tunnelsMenuItem setSubmenu:tunSub];
    [self.statusMenu addItem:self.tunnelsMenuItem];

    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:@"Connect / Disconnect"
                                                    action:@selector(toggleConnect:)
                                             keyEquivalent:@"c"];
    [toggle setTarget:self];
    [self.statusMenu addItem:toggle];

    NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"Open Nanami"
                                                  action:@selector(showWindow:)
                                           keyEquivalent:@"o"];
    [show setTarget:self];
    [self.statusMenu addItem:show];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Nanami"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    [quit setTarget:NSApp];
    [self.statusMenu addItem:quit];

    [self.statusItem setMenu:self.statusMenu];
    [self refreshStatusItem];
}

- (void)refreshStatusItem {
    BOOL connected  = [self.lastState isEqualToString:@"connected"];
    BOOL connecting = [self.lastState isEqualToString:@"connecting"];

    NSString *line = @"Not connected";
    if (connecting) {
        line = [NSString stringWithFormat:@"Connecting to %@…", self.activeTunnel ?: @"tunnel"];
    } else if (connected) {
        line = [NSString stringWithFormat:@"Connected to %@", self.activeTunnel ?: @"tunnel"];
    }
    if (self.statusMenuTitle) {
        [self.statusMenuTitle setTitle:line];
    }
    // Swap pre-rendered artwork: full colour when live, dimmed when idle.
    if (self.menuIconActive && self.menuIconIdle) {
        [self.statusItem setImage:(connected || connecting) ? self.menuIconActive
                                                            : self.menuIconIdle];
    }
}

// Rebuilds the "Connect to ▸" submenu from the tunnel store.
- (void)rebuildTunnelsSubmenu {
    NSMenu *sub = [self.tunnelsMenuItem submenu];
    if (!sub) {
        return;
    }
    [sub removeAllItems];
    NSArray *names = [[TunnelStore sharedStore] tunnelNames];
    if (names.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"(no tunnels)"
                                                      action:nil keyEquivalent:@""];
        [none setEnabled:NO];
        [sub addItem:none];
        return;
    }
    for (NSString *n in names) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:n
                                                    action:@selector(statusConnectTunnel:)
                                             keyEquivalent:@""];
        [it setTarget:self];
        [it setRepresentedObject:n];
        if ([n isEqualToString:(self.activeTunnel ?: @"")]) {
            [it setState:NSOnState];
        }
        [sub addItem:it];
    }
}

- (void)showWindow:(id)sender {
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

// ------------------------------------------------------------------ table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)[[TunnelStore sharedStore] tunnelNames].count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    (void)tableView;
    (void)col;
    NSArray *names = [[TunnelStore sharedStore] tunnelNames];
    if ((NSUInteger)row >= names.count) {
        return nil;
    }
    NSString *name = names[row];
    if ([name isEqualToString:self.activeTunnel]) {
        return [@"● " stringByAppendingString:name];
    }
    return name;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    (void)note;
    [self updateControls];
}

@end
