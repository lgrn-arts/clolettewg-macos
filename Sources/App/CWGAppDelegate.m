#import "CWGAppDelegate.h"
#import "CWGConstants.h"
#import "CWGDaemonClient.h"
#import "CWGServiceInstaller.h"
#import "CWGTunnelStore.h"
#import "CWGVPNURLParser.h"

@interface CWGAppDelegate ()
@property (nonatomic, retain) NSStatusItem *statusItem;
@property (nonatomic, retain) NSTimer *refreshTimer;
@property (nonatomic, retain) CWGTunnelStore *store;
@property (nonatomic, retain) NSWindow *aboutWindow;
@property (nonatomic, retain) NSWindow *statusWindow;
@property (nonatomic, retain) NSWindow *logWindow;
@property (nonatomic, assign) BOOL refreshInFlight;
@property (nonatomic, assign) BOOL operationInFlight;
@end

@implementation CWGAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    if (![[[[NSBundle mainBundle] bundlePath] stringByStandardizingPath] isEqualToString:CWGAppBundlePath]) {
        [self showWrongLocationAlert];
        [NSApp terminate:nil];
        return;
    }

    self.store = [[CWGTunnelStore alloc] init];
    [self installEditMenu];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self.statusItem setHighlightMode:YES];
    [self refreshStatus];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [self performSelector:@selector(offerSetupIfNeeded) withObject:nil afterDelay:0.1];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (CWGDaemonClient *)daemonClient {
    return [[CWGDaemonClient alloc] initWithToken:[CWGServiceInstaller token]];
}

- (void)refreshStatus {
    if (self.refreshInFlight) return;
    NSString *token = [CWGServiceInstaller token];
    if (!token) {
        CWGTunnelStatus *status = [[CWGTunnelStatus alloc] init];
        BOOL installed = [[NSFileManager defaultManager] fileExistsAtPath:CWGHelperPath];
        status.error = installed ? @"Service token is unreadable — run Install or Repair Service" : @"Service is not installed";
        [self applyStatus:status];
        return;
    }
    self.refreshInFlight = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *status = [client status];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshInFlight = NO;
            [self applyStatus:status];
        });
    });
}

- (void)applyStatus:(CWGTunnelStatus *)status {
    NSString *imageName = [status isActive] ? @"menubar-icon-a" : @"menubar-icon-na";
    NSImage *image = [[NSBundle mainBundle] pathForResource:imageName ofType:@"png"] ?
                     [NSImage imageNamed:imageName] : nil;
    [image setSize:NSMakeSize(18.0, 18.0)];
    [image setTemplate:NO];
    [self.statusItem setImage:image];
    [self.statusItem setTitle:@""];
    NSString *tooltip = [status isActive] && [status.name length] > 0
                        ? [NSString stringWithFormat:@"CloletteWG: %@ — %@", status.name, [status readableState]]
                        : [NSString stringWithFormat:@"CloletteWG: %@", [status readableState]];
    [self.statusItem setToolTip:tooltip];
    [self rebuildMenuWithStatus:status];
}

- (void)rebuildMenuWithStatus:(CWGTunnelStatus *)status {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"CloletteWG"];
    NSString *summary = [status.name length] > 0
                        ? [NSString stringWithFormat:@"%@ — %@", status.name, [status readableState]]
                        : [status readableState];
    NSMenuItem *summaryItem = [[NSMenuItem alloc] initWithTitle:summary action:NULL keyEquivalent:@""];
    [summaryItem setEnabled:NO];
    [menu addItem:summaryItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSArray *names = [self.store tunnelNames];
    if ([names count] == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"(no tunnels — import below)" action:NULL keyEquivalent:@""];
        [empty setEnabled:NO];
        [menu addItem:empty];
    }
    for (NSString *name in names) {
        BOOL active = [status isActive] && [status.name isEqualToString:name];
        NSString *title = [NSString stringWithFormat:@"%@%@", active ? @"✓  " : @"   ", name];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(toggleTunnel:) keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:name];
        [item setSubmenu:[self tunnelMenuForName:name]];
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [self addActionToMenu:menu title:@"Import .conf file…" key:@"i" selector:@selector(importFile:)];
    [self addActionToMenu:menu title:@"Paste vpn:// URL…" key:@"v" selector:@selector(pasteVPNURL:)];
    [self addActionToMenu:menu title:@"Show full status" key:@"s" selector:@selector(showStatus:)];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addActionToMenu:menu title:@"Install or Repair Service…" key:@"" selector:@selector(offerSetupIfNeeded)];
    [self addActionToMenu:menu title:@"Uninstall Service…" key:@"" selector:@selector(uninstallService:)];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addActionToMenu:menu title:@"About CloletteWG" key:@"" selector:@selector(showAbout:)];
    [self addActionToMenu:menu title:@"Quit" key:@"q" selector:@selector(quitApplication:)];
    [self.statusItem setMenu:menu];
}

- (void)addActionToMenu:(NSMenu *)menu title:(NSString *)title key:(NSString *)key selector:(SEL)selector {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    [item setTarget:self];
    [menu addItem:item];
}

- (NSMenu *)tunnelMenuForName:(NSString *)name {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:name];
    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:@"Edit config…" action:@selector(editTunnel:) keyEquivalent:@""];
    [edit setTarget:self];
    [edit setRepresentedObject:name];
    [menu addItem:edit];
    NSMenuItem *delete = [[NSMenuItem alloc] initWithTitle:@"Delete" action:@selector(deleteTunnel:) keyEquivalent:@""];
    [delete setTarget:self];
    [delete setRepresentedObject:name];
    [menu addItem:delete];
    return menu;
}

- (BOOL)ensureServiceReady {
    CWGServiceState state = [CWGServiceInstaller serviceState];
    if (state == CWGServiceStateReady) return YES;
    if (state == CWGServiceStateIncompleteBundle) {
        [self alert:@"The app bundle is incomplete. Reinstall CloletteWG from the original DMG."];
    } else {
        [self offerSetupIfNeeded];
    }
    return NO;
}

- (void)toggleTunnel:(NSMenuItem *)sender {
    if (self.operationInFlight || ![self ensureServiceReady]) return;
    NSString *name = [sender representedObject];
    NSString *configuration = [self.store configurationForTunnel:name];
    if (!configuration) return;
    NSString *token = [CWGServiceInstaller token];
    self.operationInFlight = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *current = [client status];
        NSString *error = nil;
        BOOL ok;
        if ([current isActive] && [current.name isEqualToString:name]) {
            ok = [client bringDownWithError:&error];
        } else {
            ok = [client bringUpTunnel:name configuration:configuration error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationInFlight = NO;
            if (!ok) [self alert:[NSString stringWithFormat:@"Tunnel operation failed:\n\n%@", error ?: @"Unknown error"]];
            [self refreshStatus];
        });
    });
}

- (void)importFile:(id)sender {
    (void)sender;
    if (![self ensureServiceReady]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:@"conf"]];
    [panel setDirectoryURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"]]];
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSOKButton) return;
    NSURL *URL = [[panel URLs] objectAtIndex:0];
    NSString *name = CWGValidatedTunnelName([[URL lastPathComponent] stringByDeletingPathExtension]);
    if (!name) {
        [self alert:@"Tunnel name must match [A-Za-z0-9_-]{1,15}."];
        return;
    }
    NSString *configuration = [NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:NULL];
    if (![self validConfiguration:configuration]) {
        [self alert:@"The file is not a readable AWG/WireGuard configuration with [Interface] and [Peer] sections."];
        return;
    }
    [self saveImportedConfiguration:configuration name:name];
}

- (void)pasteVPNURL:(id)sender {
    (void)sender;
    if (![self ensureServiceReady]) return;
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:@"Paste vpn:// URL"];
    [dialog setInformativeText:@"Paste the Amnezia connection key (starts with vpn://)"];
    [dialog addButtonWithTitle:@"Import"];
    [dialog addButtonWithTitle:@"Cancel"];
    NSTextView *input = [self textViewInScrollViewForDialog:dialog height:120.0];
    [NSApp activateIgnoringOtherApps:YES];
    [[dialog window] makeFirstResponder:input];
    if ([dialog runModal] != NSAlertFirstButtonReturn) return;

    NSError *parseError = nil;
    CWGParsedVPNURL *parsed = [CWGVPNURLParser parseURL:[input string] error:&parseError];
    if (!parsed) {
        [self alert:[NSString stringWithFormat:@"Could not decode vpn:// URL.\n\n%@", [parseError localizedDescription]]];
        return;
    }
    NSString *name = CWGValidatedTunnelName(parsed.name);
    if (!name || ![self validConfiguration:parsed.configuration]) {
        [self alert:@"The decoded tunnel name or native configuration is invalid."];
        return;
    }
    [self saveImportedConfiguration:parsed.configuration name:name];
}

- (BOOL)validConfiguration:(NSString *)configuration {
    return [configuration isKindOfClass:[NSString class]] &&
           [configuration rangeOfString:@"[Interface]"].location != NSNotFound &&
           [configuration rangeOfString:@"[Peer]"].location != NSNotFound &&
           [configuration lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024 * 1024;
}

- (void)saveImportedConfiguration:(NSString *)configuration name:(NSString *)name {
    NSError *error = nil;
    if (![self.store saveConfiguration:configuration name:name error:&error]) {
        [self alert:[NSString stringWithFormat:@"Could not save the tunnel:\n\n%@", [error localizedDescription]]];
        return;
    }
    [self alert:[NSString stringWithFormat:@"Imported tunnel: %@", name]];
    [self refreshStatus];
}

- (NSTextView *)textViewInScrollViewForDialog:(NSAlert *)dialog height:(CGFloat)height {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, height)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    NSTextView *text = [[NSTextView alloc] initWithFrame:[scroll bounds]];
    [text setRichText:NO];
    [text setFont:[NSFont userFixedPitchFontOfSize:11.0]];
    [text setAutomaticDataDetectionEnabled:NO];
    [text setAutomaticLinkDetectionEnabled:NO];
    [text setAutomaticQuoteSubstitutionEnabled:NO];
    [text setAutomaticDashSubstitutionEnabled:NO];
    [text setAutomaticTextReplacementEnabled:NO];
    [text setAutomaticSpellingCorrectionEnabled:NO];
    [[text textContainer] setWidthTracksTextView:YES];
    [[text textContainer] setContainerSize:NSMakeSize(520, CGFLOAT_MAX)];
    [scroll setDocumentView:text];
    [dialog setAccessoryView:scroll];
    return text;
}

- (void)editTunnel:(NSMenuItem *)sender {
    NSString *name = [sender representedObject];
    NSString *configuration = [self.store configurationForTunnel:name];
    if (!configuration) return;
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:[NSString stringWithFormat:@"Edit %@", name]];
    [dialog setInformativeText:@"Restart the tunnel after saving to apply changes."];
    NSTextView *editor = [self textViewInScrollViewForDialog:dialog height:340.0];
    [editor setString:configuration];
    [dialog addButtonWithTitle:@"Save"];
    [dialog addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([dialog runModal] != NSAlertFirstButtonReturn) return;
    if (![self validConfiguration:[editor string]]) {
        [self alert:@"The edited configuration must retain [Interface] and [Peer] sections."];
        return;
    }
    NSError *error = nil;
    if ([self.store saveConfiguration:[editor string] name:name error:&error]) {
        [self alert:[NSString stringWithFormat:@"Saved %@. Restart the tunnel to apply changes.", name]];
    } else {
        [self alert:[NSString stringWithFormat:@"Save failed:\n\n%@", [error localizedDescription]]];
    }
}

- (void)deleteTunnel:(NSMenuItem *)sender {
    NSString *name = [sender representedObject];
    NSAlert *confirm = [[NSAlert alloc] init];
    [confirm setMessageText:[NSString stringWithFormat:@"Delete %@?", name]];
    [confirm setInformativeText:@"The saved configuration will be removed from this Mac."];
    [confirm addButtonWithTitle:@"Delete"];
    [confirm addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSString *token = [CWGServiceInstaller token];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *status = [client status];
        NSString *serviceError = nil;
        if ([status isActive] && [status.name isEqualToString:name]) {
            [client bringDownWithError:&serviceError];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (serviceError) {
                [self alert:[NSString stringWithFormat:@"Disconnect before deleting failed:\n\n%@", serviceError]];
                return;
            }
            NSError *error = nil;
            if (![self.store removeTunnel:name error:&error]) {
                [self alert:[NSString stringWithFormat:@"Delete failed:\n\n%@", [error localizedDescription]]];
            }
            [self refreshStatus];
        });
    });
}

static NSString *CWGFormatBytes(long long value) {
    double amount = (double)value;
    NSArray *units = [NSArray arrayWithObjects:@"B", @"KiB", @"MiB", @"GiB", @"TiB", nil];
    NSUInteger unit = 0;
    while (amount >= 1024.0 && unit + 1 < [units count]) {
        amount /= 1024.0;
        unit++;
    }
    return [NSString stringWithFormat:@"%.1f %@", amount, [units objectAtIndex:unit]];
}

- (void)showStatus:(id)sender {
    (void)sender;
    if (![self ensureServiceReady]) return;
    NSString *token = [CWGServiceInstaller token];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *status = [client status];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentStatusWindowWithStatus:status];
        });
    });
}

- (NSTextField *)statusLabel:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text];
    [label setFont:bold ? [NSFont boldSystemFontOfSize:11.0] : [NSFont systemFontOfSize:11.0]];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    return label;
}

- (void)addStatusRowToView:(NSView *)view title:(NSString *)title value:(NSString *)value y:(CGFloat)y {
    [view addSubview:[self statusLabel:title frame:NSMakeRect(20, y, 125, 20) bold:NO]];
    [view addSubview:[self statusLabel:value.length > 0 ? value : @"—" frame:NSMakeRect(150, y, 290, 20) bold:YES]];
}

- (NSButton *)windowButton:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return button;
}

- (void)presentStatusWindowWithStatus:(CWGTunnelStatus *)status {
    [self.statusWindow close];
    self.statusWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 360)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];
    [self.statusWindow setTitle:@"CloletteWG Status"];
    [self.statusWindow setReleasedWhenClosed:NO];
    NSView *content = [self.statusWindow contentView];

    NSColor *dotColor = [NSColor grayColor];
    if ([status.state isEqualToString:@"connected"]) {
        dotColor = [NSColor colorWithCalibratedRed:0.12 green:0.65 blue:0.20 alpha:1.0];
    } else if ([status.state isEqualToString:@"connecting"]) {
        dotColor = [NSColor orangeColor];
    }
    NSImage *dotImage = [[NSImage alloc] initWithSize:NSMakeSize(14, 14)];
    [dotImage lockFocus];
    [dotColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 14, 14)] fill];
    [dotImage unlockFocus];
    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(21, 318, 14, 14)];
    [dot setImage:dotImage];
    [content addSubview:dot];
    NSTextField *state = [self statusLabel:[status readableState] frame:NSMakeRect(46, 310, 394, 24) bold:YES];
    [state setFont:[NSFont boldSystemFontOfSize:14.0]];
    [content addSubview:state];

    NSString *handshake = @"Never";
    if (status.lastHandshake > 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        handshake = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)status.lastHandshake]];
    }
    [self addStatusRowToView:content title:@"Tunnel" value:status.name y:262];
    [self addStatusRowToView:content title:@"Endpoint" value:status.endpoint y:230];
    [self addStatusRowToView:content title:@"Listen port" value:status.listenPort > 0 ? [NSString stringWithFormat:@"%d", status.listenPort] : @"—" y:198];
    [self addStatusRowToView:content title:@"Last handshake" value:handshake y:166];
    [self addStatusRowToView:content title:@"Received" value:CWGFormatBytes(status.receivedBytes) y:134];
    [self addStatusRowToView:content title:@"Transmitted" value:CWGFormatBytes(status.transmittedBytes) y:102];
    [self addStatusRowToView:content title:@"AWG obfuscation" value:status.obfuscationEnabled ? @"Enabled" : @"Disabled / default" y:70];
    [content addSubview:[self windowButton:@"Daemon Log…" frame:NSMakeRect(20, 20, 120, 28) action:@selector(showDaemonLog:)]];
    [content addSubview:[self windowButton:@"Close" frame:NSMakeRect(360, 20, 80, 28) action:@selector(closeStatusWindow:)]];
    [self.statusWindow center];
    [NSApp activateIgnoringOtherApps:YES];
    [self.statusWindow makeKeyAndOrderFront:self];
    [self.statusWindow orderFrontRegardless];
}

- (void)closeStatusWindow:(id)sender {
    (void)sender;
    [self.statusWindow close];
}

- (void)showDaemonLog:(id)sender {
    (void)sender;
    NSString *token = [CWGServiceInstaller token];
    if (!token) {
        [self alert:@"The service token is unavailable."];
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        NSString *error = nil;
        NSArray *lines = [client logLines:200 error:&error];
        NSString *text = lines.count > 0 ? [lines componentsJoinedByString:@"\n"] : (error ?: @"The daemon log is empty.");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentLogWindowWithText:text];
        });
    });
}

- (void)presentLogWindowWithText:(NSString *)text {
    [self.logWindow close];
    self.logWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 420)
                                                styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
                                                  backing:NSBackingStoreBuffered defer:NO];
    [self.logWindow setTitle:@"CloletteWG Daemon Log"];
    [self.logWindow setReleasedWhenClosed:NO];
    NSView *content = [self.logWindow contentView];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 56, 616, 352)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    NSTextView *view = [[NSTextView alloc] initWithFrame:[scroll bounds]];
    [view setEditable:NO];
    [view setFont:[NSFont userFixedPitchFontOfSize:11.0]];
    [view setString:text];
    [scroll setDocumentView:view];
    [content addSubview:scroll];
    NSButton *close = [self windowButton:@"Close" frame:NSMakeRect(540, 14, 88, 28) action:@selector(closeLogWindow:)];
    [close setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:close];
    [self.logWindow center];
    [NSApp activateIgnoringOtherApps:YES];
    [self.logWindow makeKeyAndOrderFront:self];
    [self.logWindow orderFrontRegardless];
}

- (void)closeLogWindow:(id)sender {
    (void)sender;
    [self.logWindow close];
}

- (void)offerSetupIfNeeded {
    CWGServiceState state = [CWGServiceInstaller serviceState];
    if (state == CWGServiceStateReady) {
        [self refreshStatus];
        return;
    }
    if (state == CWGServiceStateIncompleteBundle) {
        [self alert:@"The app bundle is incomplete. Reinstall CloletteWG from the original DMG."];
        return;
    }
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:state == CWGServiceStateNeedsUpdate ? @"CloletteWG service update required" : @"CloletteWG needs a one-time setup"];
    [dialog setInformativeText:@"One administrator prompt will install or repair the root daemon and its launchd service. Connections afterwards do not ask for a password.\n\nThe daemon is copied to /Library/PrivilegedHelperTools; your tunnel configurations stay in your home folder."];
    [dialog addButtonWithTitle:state == CWGServiceStateNeedsUpdate ? @"Update…" : @"Install…"];
    [dialog addButtonWithTitle:@"Not Now"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([dialog runModal] != NSAlertFirstButtonReturn) return;
    NSString *error = nil;
    BOOL ok = [CWGServiceInstaller installWithError:&error];
    [self alert:ok ? @"Setup complete. CloletteWG is ready." : [NSString stringWithFormat:@"Setup failed:\n\n%@", error ?: @"Unknown error"]];
    [self refreshStatus];
}

- (void)uninstallService:(id)sender {
    (void)sender;
    NSAlert *confirm = [[NSAlert alloc] init];
    [confirm setMessageText:@"Uninstall the CloletteWG service?"];
    [confirm setInformativeText:@"The active tunnel will be disconnected and the root daemon removed. Saved tunnel configurations will be kept."];
    [confirm addButtonWithTitle:@"Uninstall…"];
    [confirm addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;
    [[self daemonClient] bringDownWithError:NULL];
    NSString *error = nil;
    BOOL ok = [CWGServiceInstaller uninstallWithError:&error];
    [self alert:ok ? @"The service was removed. Saved tunnels were kept." : [NSString stringWithFormat:@"Uninstall failed:\n\n%@", error ?: @"Unknown error"]];
    [self refreshStatus];
}

- (void)showAbout:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    if (!self.aboutWindow) self.aboutWindow = [self makeAboutWindow];
    [self.aboutWindow makeKeyAndOrderFront:self];
    [self.aboutWindow orderFrontRegardless];
}

- (NSTextField *)aboutLabel:(NSString *)text frame:(NSRect)frame font:(NSFont *)font {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text];
    [label setFont:font];
    [label setAlignment:NSCenterTextAlignment];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [[label cell] setWraps:YES];
    return label;
}

- (NSButton *)aboutLink:(NSString *)text frame:(NSRect)frame action:(SEL)action {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [paragraph setAlignment:NSCenterTextAlignment];
    NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:11.0], NSFontAttributeName,
        [NSColor colorWithCalibratedRed:0.10 green:0.50 blue:0.95 alpha:1.0], NSForegroundColorAttributeName,
        paragraph, NSParagraphStyleAttributeName,
        [NSNumber numberWithInteger:NSUnderlineStyleSingle], NSUnderlineStyleAttributeName, nil];
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setAttributedTitle:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    [button setAlignment:NSCenterTextAlignment];
    [button setBordered:NO];
    [button setTarget:self];
    [button setAction:action];
    return button;
}

- (NSWindow *)makeAboutWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 520)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"About CloletteWG"];
    [window setReleasedWhenClosed:NO];
    NSView *content = [window contentView];

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(232, 400, 96, 96)];
    [icon setImage:[NSImage imageNamed:@"AppIcon"] ?: [NSApp applicationIconImage]];
    [icon setImageScaling:NSImageScaleProportionallyUpOrDown];
    [content addSubview:icon];
    [content addSubview:[self aboutLabel:@"CloletteWG" frame:NSMakeRect(20, 362, 520, 28) font:[NSFont boldSystemFontOfSize:18]]];
    NSString *build = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] ?: CWGAppVersion();
    NSString *version = [NSString stringWithFormat:@"Version %@ (%@)", CWGAppVersion(), build];
    [content addSubview:[self aboutLabel:version frame:NSMakeRect(20, 336, 520, 20) font:[NSFont systemFontOfSize:11]]];
    [content addSubview:[self aboutLabel:@"A minimal Go and Objective-C implementation of an AmneziaWG client, with support for macOS Mavericks and AWG 3.x. This is beta software and may contain bugs." frame:NSMakeRect(35, 274, 490, 52) font:[NSFont systemFontOfSize:11]]];
    [content addSubview:[self aboutLabel:@"This application is NOT a VPN and does not provide countries or servers to connect to. For connection configurations, contact the operator or provider responsible for your server connection." frame:NSMakeRect(35, 212, 490, 52) font:[NSFont systemFontOfSize:11]]];
    [content addSubview:[self aboutLabel:@"Based on the original source code:" frame:NSMakeRect(20, 180, 520, 20) font:[NSFont systemFontOfSize:11]]];
    [content addSubview:[self aboutLink:@"github.com/maloyan/amnezia-cloak" frame:NSMakeRect(20, 152, 520, 20) action:@selector(openOriginalRepo:)]];
    [content addSubview:[self aboutLink:@"github.com/TheFrutigerDaniel/amneziawg-mavericks" frame:NSMakeRect(20, 124, 520, 20) action:@selector(openEngineRepo:)]];
    [content addSubview:[self aboutLink:@"github.com/amnezia-vpn/amneziawg-apple" frame:NSMakeRect(20, 96, 520, 20) action:@selector(openAppleRepo:)]];
    [content addSubview:[self aboutLabel:@"© 2026 Narek Maloyan · UI/UX\n© 2026 LGRN Arts · Development, Testing\n© 2026 TheFrutigerDaniel · Binaries, Engine, Testing" frame:NSMakeRect(20, 18, 520, 72) font:[NSFont systemFontOfSize:11]]];
    [window center];
    return window;
}

- (void)openOriginalRepo:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/maloyan/amnezia-cloak"]];
}

- (void)openEngineRepo:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/TheFrutigerDaniel/amneziawg-mavericks"]];
}

- (void)openAppleRepo:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/amnezia-vpn/amneziawg-apple"]];
}

- (void)showWrongLocationAlert {
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:@"Move CloletteWG to /Applications"];
    [dialog setInformativeText:@"Drag CloletteWG.app to /Applications and launch it from that exact location. No background processes have been started."];
    [dialog addButtonWithTitle:@"Quit"];
    [NSApp activateIgnoringOtherApps:YES];
    [dialog runModal];
}

- (void)installEditMenu {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:edit];
    [main addItem:editItem];
    [NSApp setMainMenu:main];
}

- (void)alert:(NSString *)message {
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:message];
    [dialog addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [dialog runModal];
}

- (void)quitApplication:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

@end
