#import "CWGAppDelegate.h"
#import "CWGConstants.h"
#import "CWGDaemonClient.h"
#import "CWGServiceInstaller.h"
#import "CWGTunnelStore.h"
#import "CWGVPNURLParser.h"
#import "CWGStatusItemView.h"
#import <float.h>

@interface CWGAppDelegate ()
@property (nonatomic, retain) NSStatusItem *statusItem;
@property (nonatomic, retain) CWGStatusItemView *statusView;
@property (nonatomic, retain) NSMenu *statusMenu;
@property (nonatomic, retain) CWGTunnelStatus *currentStatus;
@property (nonatomic, copy) NSString *lastConnectedTunnelName;
@property (nonatomic, retain) NSMenuItem *autoLaunchItem;
@property (nonatomic, retain) NSMenuItem *autoTunnelItem;
@property (nonatomic, retain) NSTimer *refreshTimer;
@property (nonatomic, retain) CWGTunnelStore *store;
@property (nonatomic, retain) NSWindow *aboutWindow;
@property (nonatomic, retain) NSWindow *statusWindow;
@property (nonatomic, retain) NSWindow *logWindow;
@property (nonatomic, retain) NSTextField *statusStateLabel;
@property (nonatomic, retain) NSImageView *statusDotView;
@property (nonatomic, retain) NSMutableDictionary *statusValueLabels;
@property (nonatomic, copy) NSString *networkInfoKey;
@property (nonatomic, copy) NSString *countryValue;
@property (nonatomic, copy) NSString *ispValue;
@property (nonatomic, retain) NSTextView *killSwitchEditor;
@property (nonatomic, copy) NSString *killSwitchTunnelName;
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
    [self installStatusItem];
    [self refreshStatus];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [self performSelector:@selector(offerSetupIfNeeded) withObject:nil afterDelay:0.1];
    [self performSelector:@selector(autoConnectIfNeeded) withObject:nil afterDelay:1.0];
    [self performSelector:@selector(applyBossModeAtLoginIfNeeded) withObject:nil afterDelay:0.2];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                          selector:@selector(systemWillPowerOff:)
                                                              name:NSWorkspaceWillPowerOffNotification
                                                            object:nil];
}

- (void)installStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:26.0];
    CWGStatusItemView *view = [[CWGStatusItemView alloc] initWithFrame:NSMakeRect(0, 0, 26.0, 22.0)];
    self.statusView = view;
    __weak CWGAppDelegate *weakSelf = self;
    view.leftAction = ^{
        [weakSelf toggleLastTunnel];
    };
    view.rightAction = ^{
        [weakSelf showStatusMenu];
    };
    [self.statusItem setView:view];
    if (self.currentStatus) [self applyStatus:self.currentStatus];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    if (!self.statusItem) [self installStatusItem];
    [self refreshStatus];
    return YES;
}

- (void)showStatusMenu {
    if (self.statusMenu) [self.statusItem popUpStatusItemMenu:self.statusMenu];
}

- (void)bossMode:(id)sender {
    (void)sender;
    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
    self.statusView = nil;
}

- (void)systemWillPowerOff:(NSNotification *)notification {
    (void)notification;
    if ([self.currentStatus isActive]) {
        [[self daemonClient] bringDownWithError:NULL];
    }
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
    self.currentStatus = status;
    if ([status isActive] && status.name.length > 0 && ![self.lastConnectedTunnelName isEqualToString:status.name]) {
        self.lastConnectedTunnelName = status.name;
        [[NSUserDefaults standardUserDefaults] setObject:status.name forKey:@"CloletteWG.LastConnectedTunnel"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    NSString *imageName = [status isActive] ? @"menubar-icon-a" : @"menubar-icon-na";
    NSImage *image = [[NSBundle mainBundle] pathForResource:imageName ofType:@"png"] ?
                     [NSImage imageNamed:imageName] : nil;
    [image setSize:NSMakeSize(18.0, 18.0)];
    [image setTemplate:NO];
    self.statusView.image = image;
    self.statusView.connecting = [status.state isEqualToString:@"connecting"];
    [self.statusView setNeedsDisplay:YES];
    NSString *tooltip = [status isActive] && [status.name length] > 0
                        ? [NSString stringWithFormat:@"CloletteWG: %@ — %@", status.name, [status readableState]]
                        : [NSString stringWithFormat:@"CloletteWG: %@", [status readableState]];
    [self.statusView setToolTip:tooltip];
    [self rebuildMenuWithStatus:status];
    [self updateStatusWindowWithStatus:status];
    [self updateNetworkInfoForStatus:status];
}

- (void)rebuildMenuWithStatus:(CWGTunnelStatus *)status {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"CloletteWG"];
    [menu setAutoenablesItems:NO];
    NSArray *names = [self.store tunnelNames];
    NSMenuItem *autoConnectItem = [[NSMenuItem alloc] initWithTitle:[status isActive] ? @"Disconnect" : @"Auto-Connect" action:@selector(autoconnect:) keyEquivalent:@""];
    [autoConnectItem setTarget:self];
    [autoConnectItem setEnabled:names.count > 0];
    [menu addItem:autoConnectItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSString *summary = [status.name length] > 0
                        ? [NSString stringWithFormat:@"%@ — %@", status.name, [status readableState]]
                        : [status readableState];
    NSMenuItem *summaryItem = [[NSMenuItem alloc] initWithTitle:summary action:NULL keyEquivalent:@""];
    [summaryItem setEnabled:NO];
    [menu addItem:summaryItem];
    [menu addItem:[NSMenuItem separatorItem]];

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
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings" action:NULL keyEquivalent:@""];
    NSMenu *settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];
    [settingsMenu setAutoenablesItems:NO];
    NSMenuItem *serviceItem = [[NSMenuItem alloc] initWithTitle:@"Service" action:NULL keyEquivalent:@""];
    NSMenu *serviceMenu = [[NSMenu alloc] initWithTitle:@"Service"];
    [serviceMenu setAutoenablesItems:NO];
    [self addActionToMenu:serviceMenu title:@"Install or Repair" key:@"" selector:@selector(offerSetupIfNeeded)];
    [self addActionToMenu:serviceMenu title:@"Uninstall" key:@"" selector:@selector(uninstallService:)];
    [serviceItem setSubmenu:serviceMenu];
    [settingsMenu addItem:serviceItem];

    NSMenuItem *startupItem = [[NSMenuItem alloc] initWithTitle:@"Startup" action:NULL keyEquivalent:@""];
    NSMenu *startupMenu = [[NSMenu alloc] initWithTitle:@"Startup"];
    [startupMenu setAutoenablesItems:NO];
    BOOL autoLaunch = [[NSUserDefaults standardUserDefaults] boolForKey:@"CloletteWG.AutoLaunchApp"];
    BOOL autoTunnel = autoLaunch && [[NSUserDefaults standardUserDefaults] boolForKey:@"CloletteWG.AutoConnectTunnel"];
    BOOL bossAtLogin = autoLaunch && [[NSUserDefaults standardUserDefaults] boolForKey:@"CloletteWG.BossModeAtLogin"];
    self.autoLaunchItem = [[NSMenuItem alloc] initWithTitle:@"Launch Application" action:@selector(toggleAutoLaunch:) keyEquivalent:@""];
    [self.autoLaunchItem setTarget:self];
    [self.autoLaunchItem setState:autoLaunch ? NSOnState : NSOffState];
    [startupMenu addItem:self.autoLaunchItem];
    self.autoTunnelItem = [[NSMenuItem alloc] initWithTitle:@"Connect Tunnel" action:@selector(toggleAutoTunnel:) keyEquivalent:@""];
    [self.autoTunnelItem setTarget:self];
    [self.autoTunnelItem setState:autoTunnel ? NSOnState : NSOffState];
    [self.autoTunnelItem setEnabled:autoLaunch];
    [startupMenu addItem:self.autoTunnelItem];
    NSMenuItem *bossAtLoginItem = [[NSMenuItem alloc] initWithTitle:@"Boss-mode" action:@selector(toggleBossModeAtLogin:) keyEquivalent:@""];
    [bossAtLoginItem setTarget:self];
    [bossAtLoginItem setState:bossAtLogin ? NSOnState : NSOffState];
    [bossAtLoginItem setEnabled:autoLaunch];
    [startupMenu addItem:bossAtLoginItem];
    [startupItem setSubmenu:startupMenu];
    [settingsMenu addItem:startupItem];
    [settingsItem setSubmenu:settingsMenu];
    [menu addItem:settingsItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addActionToMenu:menu title:@"About CloletteWG" key:@"" selector:@selector(showAbout:)];
    [self addActionToMenu:menu title:@"Boss-mode" key:@"b" selector:@selector(bossMode:)];
    [self addActionToMenu:menu title:@"Quit" key:@"q" selector:@selector(quitApplication:)];
    self.statusMenu = menu;
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
    NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename" action:@selector(renameTunnel:) keyEquivalent:@""];
    [rename setTarget:self];
    [rename setRepresentedObject:name];
    [menu addItem:rename];
    NSMenuItem *delete = [[NSMenuItem alloc] initWithTitle:@"Delete" action:@selector(deleteTunnel:) keyEquivalent:@""];
    [delete setTarget:self];
    [delete setRepresentedObject:name];
    [menu addItem:delete];
    return menu;
}

- (NSString *)endpointHostForConfiguration:(NSString *)configuration {
    BOOL peerSection = NO;
    for (NSString *line in [configuration componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"["]) {
            peerSection = [trimmed caseInsensitiveCompare:@"[Peer]"] == NSOrderedSame;
            continue;
        }
        if (!peerSection) continue;
        NSRange separator = [trimmed rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([key caseInsensitiveCompare:@"Endpoint"] != NSOrderedSame) continue;
        NSString *endpoint = [[trimmed substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([endpoint hasPrefix:@"["]) {
            NSRange closing = [endpoint rangeOfString:@"]"];
            return closing.location == NSNotFound ? nil : [endpoint substringWithRange:NSMakeRange(1, closing.location - 1)];
        }
        NSRange port = [endpoint rangeOfString:@":" options:NSBackwardsSearch];
        return port.location == NSNotFound ? endpoint : [endpoint substringToIndex:port.location];
    }
    return nil;
}

- (NSNumber *)latencyForConfiguration:(NSString *)configuration {
    NSString *host = [self endpointHostForConfiguration:configuration];
    if (host.length == 0) return nil;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/ping"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", @"1", @"-W", @"1000", @"-t", @"2", host, nil]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        return nil;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
    while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    if ([task isRunning]) [task terminate];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:[[pipe fileHandleForReading] readDataToEndOfFile]
                                             encoding:NSUTF8StringEncoding];
    NSRange marker = [output rangeOfString:@"time="];
    if (marker.location == NSNotFound) marker = [output rangeOfString:@"time<"];
    if (marker.location == NSNotFound) return nil;
    NSString *value = [[output substringFromIndex:marker.location + 5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [NSNumber numberWithDouble:MAX(0.001, [value doubleValue])];
}

- (void)connectTunnelNamed:(NSString *)name {
    if (self.operationInFlight) return;
    NSString *configuration = [self.store configurationForTunnel:name];
    if (!configuration) return;
    self.operationInFlight = YES;
    self.statusView.connecting = YES;
    [self.statusView setNeedsDisplay:YES];
    NSString *token = [CWGServiceInstaller token];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *current = [client status];
        NSString *error = nil;
        BOOL ok = YES;
        if (![current isActive] || ![current.name isEqualToString:name]) {
            ok = [client bringUpTunnel:name configuration:configuration error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationInFlight = NO;
            if (!ok) [self alert:[NSString stringWithFormat:@"Tunnel operation failed:\n\n%@", error ?: @"Unknown error"]];
            [self refreshStatus];
        });
    });
}

- (void)disconnectActiveTunnel {
    self.operationInFlight = YES;
    NSString *token = [CWGServiceInstaller token];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        NSString *error = nil;
        BOOL ok = [client bringDownWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationInFlight = NO;
            if (!ok) [self alert:[NSString stringWithFormat:@"Tunnel operation failed:\n\n%@", error ?: @"Unknown error"]];
            [self refreshStatus];
        });
    });
}

- (void)autoconnect:(id)sender {
    (void)sender;
    if (self.operationInFlight || ![self ensureServiceReady]) return;
    if ([self.currentStatus isActive]) {
        [self disconnectActiveTunnel];
        return;
    }
    NSArray *names = [self.store tunnelNames];
    if (names.count == 0) return;
    if (names.count == 1) {
        [self connectTunnelNamed:[names objectAtIndex:0]];
        return;
    }

    self.operationInFlight = YES;
    self.statusView.connecting = YES;
    [self.statusView setNeedsDisplay:YES];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *latencies = [NSMutableDictionary dictionary];
        dispatch_apply(names.count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
            NSString *name = [names objectAtIndex:index];
            NSString *configuration = [self.store configurationForTunnel:name];
            NSNumber *latency = [self latencyForConfiguration:configuration];
            if (latency) {
                @synchronized (latencies) {
                    [latencies setObject:latency forKey:name];
                }
            }
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *bestName = nil;
            double bestLatency = DBL_MAX;
            for (NSString *name in names) {
                double latency = [[latencies objectForKey:name] doubleValue];
                if (latency > 0 && latency < bestLatency) {
                    bestLatency = latency;
                    bestName = name;
                }
            }
            self.operationInFlight = NO;
            if (!bestName) {
                self.statusView.connecting = NO;
                [self.statusView setNeedsDisplay:YES];
                [self alert:@"No reachable configs."];
                return;
            }
            [self connectTunnelNamed:bestName];
        });
    });
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
    self.statusView.connecting = YES;
    [self.statusView setNeedsDisplay:YES];
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


- (void)updateLoginItem {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *path = [directory stringByAppendingPathComponent:@"com.clolettewg.plist"];
    NSString *legacyPath = [directory stringByAppendingPathComponent:@"com.narek.clolettewg.plist"];
    NSFileManager *files = [NSFileManager defaultManager];
    [files removeItemAtPath:legacyPath error:NULL];
    if (![defaults boolForKey:@"CloletteWG.AutoLaunchApp"]) {
        [files removeItemAtPath:path error:NULL];
        return;
    }
    [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *agent = [NSDictionary dictionaryWithObjectsAndKeys:
        @"com.clolettewg", @"Label",
        [NSArray arrayWithObject:@"/Applications/CloletteWG.app/Contents/MacOS/CloletteWG"], @"ProgramArguments",
        [NSNumber numberWithBool:YES], @"RunAtLoad",
        @"Aqua", @"LimitLoadToSessionType", nil];
    [agent writeToFile:path atomically:YES];
}

- (void)toggleAutoLaunch:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![defaults boolForKey:@"CloletteWG.AutoLaunchApp"];
    [defaults setBool:enabled forKey:@"CloletteWG.AutoLaunchApp"];
    if (!enabled) {
        [defaults setBool:NO forKey:@"CloletteWG.AutoConnectTunnel"];
        [defaults setBool:NO forKey:@"CloletteWG.BossModeAtLogin"];
    }
    [self updateLoginItem];
    [self rebuildMenuWithStatus:self.currentStatus];
}

- (void)toggleAutoTunnel:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"CloletteWG.AutoLaunchApp"]) return;
    BOOL enabled = ![defaults boolForKey:@"CloletteWG.AutoConnectTunnel"];
    [defaults setBool:enabled forKey:@"CloletteWG.AutoConnectTunnel"];
    [self rebuildMenuWithStatus:self.currentStatus];
}

- (void)toggleBossModeAtLogin:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"CloletteWG.AutoLaunchApp"]) return;
    BOOL enabled = ![defaults boolForKey:@"CloletteWG.BossModeAtLogin"];
    [defaults setBool:enabled forKey:@"CloletteWG.BossModeAtLogin"];
    [self rebuildMenuWithStatus:self.currentStatus];
}

- (void)applyBossModeAtLoginIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"CloletteWG.AutoLaunchApp"] &&
        [defaults boolForKey:@"CloletteWG.BossModeAtLogin"]) {
        [self bossMode:nil];
    }
}

- (void)autoConnectIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"CloletteWG.AutoLaunchApp"] ||
        ![defaults boolForKey:@"CloletteWG.AutoConnectTunnel"] ||
        [self.store tunnelNames].count == 0) return;
    if (!self.currentStatus) {
        [self performSelector:@selector(autoConnectIfNeeded) withObject:nil afterDelay:1.0];
        return;
    }
    if ([self.currentStatus isActive] || [CWGServiceInstaller serviceState] != CWGServiceStateReady) return;
    [self toggleLastTunnel];
}

- (void)toggleLastTunnel {
    NSArray *names = [self.store tunnelNames];
    if (names.count == 0) {
        [self alert:@"Error: no imported configs."];
        return;
    }
    if (self.operationInFlight || ![self ensureServiceReady]) return;

    NSString *lastName = self.lastConnectedTunnelName;
    if (!lastName) lastName = [[NSUserDefaults standardUserDefaults] stringForKey:@"CloletteWG.LastConnectedTunnel"];
    NSString *configuration = [self.store configurationForTunnel:lastName];
    if (!configuration) {
        lastName = [names objectAtIndex:0];
        configuration = [self.store configurationForTunnel:lastName];
    }
    if (!configuration) return;

    self.lastConnectedTunnelName = lastName;
    NSString *token = [CWGServiceInstaller token];
    self.operationInFlight = YES;
    self.statusView.connecting = YES;
    [self.statusView setNeedsDisplay:YES];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *current = [client status];
        NSString *error = nil;
        BOOL ok;
        if ([current isActive]) {
            ok = [client bringDownWithError:&error];
        } else {
            ok = [client bringUpTunnel:lastName configuration:configuration error:&error];
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

- (NSString *)allowedIPsFromConfiguration:(NSString *)configuration {
    BOOL peerSection = NO;
    for (NSString *line in [configuration componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"["]) {
            peerSection = [trimmed caseInsensitiveCompare:@"[Peer]"] == NSOrderedSame;
            continue;
        }
        if (!peerSection) continue;
        NSRange separator = [trimmed rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([key caseInsensitiveCompare:@"AllowedIPs"] == NSOrderedSame) {
            return [[trimmed substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

- (BOOL)isFullTunnelAllowedIPs:(NSString *)allowedIPs {
    for (NSString *item in [allowedIPs componentsSeparatedByString:@","]) {
        if ([[item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"0.0.0.0/0"]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)configuration:(NSString *)configuration withAllowedIPs:(NSString *)allowedIPs {
    NSMutableArray *result = [NSMutableArray array];
    BOOL peerSection = NO;
    BOOL replaced = NO;
    for (NSString *line in [configuration componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"["]) {
            if (peerSection && !replaced && allowedIPs != nil) {
                [result addObject:[NSString stringWithFormat:@"AllowedIPs = %@", allowedIPs]];
                replaced = YES;
            }
            peerSection = [trimmed caseInsensitiveCompare:@"[Peer]"] == NSOrderedSame;
        }
        NSRange separator = [trimmed rangeOfString:@"="];
        if (peerSection && !replaced && separator.location != NSNotFound) {
            NSString *key = [[trimmed substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([key caseInsensitiveCompare:@"AllowedIPs"] == NSOrderedSame) {
                replaced = YES;
                if (allowedIPs != nil) {
                    [result addObject:[NSString stringWithFormat:@"AllowedIPs = %@", allowedIPs]];
                }
                continue;
            }
        }
        [result addObject:line];
    }
    if (!replaced && allowedIPs != nil) {
        [result addObject:[NSString stringWithFormat:@"AllowedIPs = %@", allowedIPs]];
    }
    return [result componentsJoinedByString:@"\n"];
}

- (void)toggleKillSwitch:(NSButton *)sender {
    NSString *configuration = self.killSwitchEditor.string;
    NSString *allowedIPs = sender.state == NSOnState
                           ? @"0.0.0.0/0, ::/0"
                           : @"0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1";
    [self.killSwitchEditor setString:[self configuration:configuration withAllowedIPs:allowedIPs]];
}

- (void)editTunnel:(NSMenuItem *)sender {
    NSString *name = [sender representedObject];
    NSString *configuration = [self.store configurationForTunnel:name];
    if (!configuration) return;
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:[NSString stringWithFormat:@"Edit %@", name]];
    NSTextView *editor = [self textViewInScrollViewForDialog:dialog height:340.0];
    [editor setString:configuration];

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 380)];
    NSScrollView *scroll = [editor enclosingScrollView];
    [scroll setFrame:NSMakeRect(0, 40, 520, 340)];
    [container addSubview:scroll];
    NSButton *killSwitch = [[NSButton alloc] initWithFrame:NSMakeRect(0, 8, 280, 24)];
    [killSwitch setButtonType:NSSwitchButton];
    [killSwitch setTitle:@"Kill switch (full tunnel)"];
    [killSwitch setState:[self isFullTunnelAllowedIPs:[self allowedIPsFromConfiguration:configuration]] ? NSOnState : NSOffState];
    [killSwitch setTarget:self];
    [killSwitch setAction:@selector(toggleKillSwitch:)];
    [container addSubview:killSwitch];
    [dialog setAccessoryView:container];

    self.killSwitchEditor = editor;
    self.killSwitchTunnelName = name;
    [dialog addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    NSInteger response = [dialog runModal];
    self.killSwitchEditor = nil;
    self.killSwitchTunnelName = nil;
    if (response != NSAlertFirstButtonReturn) return;

    NSString *updatedConfiguration = [editor string];
    if ([updatedConfiguration isEqualToString:configuration]) {
        [self alert:@"No changes to save."];
        return;
    }
    if (![self validConfiguration:updatedConfiguration]) {
        [self alert:@"The edited configuration must retain [Interface] and [Peer] sections."];
        return;
    }
    NSError *error = nil;
    if (![self.store saveConfiguration:updatedConfiguration name:name error:&error]) {
        [self alert:[NSString stringWithFormat:@"Save failed:\n\n%@", [error localizedDescription]]];
        return;
    }

    self.operationInFlight = YES;
    NSString *token = [CWGServiceInstaller token];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *status = [client status];
        BOOL shouldRestart = [status isActive] && [status.name isEqualToString:name];
        BOOL restarted = NO;
        NSString *operationError = nil;
        if (shouldRestart && [client bringDownWithError:&operationError]) {
            restarted = [client bringUpTunnel:name configuration:updatedConfiguration error:&operationError];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationInFlight = NO;
            if (operationError) {
                [self alert:[NSString stringWithFormat:@"Changes saved, but tunnel restart failed:\n\n%@", operationError]];
            } else if (restarted) {
                [self alert:@"Changes saved. Tunnel restarted."];
            } else {
                [self alert:@"Changes saved."];
            }
            [self refreshStatus];
        });
    });
}

- (void)renameTunnel:(NSMenuItem *)sender {
    NSString *oldName = [sender representedObject];
    if (!oldName) return;
    NSAlert *dialog = [[NSAlert alloc] init];
    [dialog setMessageText:[NSString stringWithFormat:@"Rename %@", oldName]];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    [input setStringValue:oldName];
    [dialog setAccessoryView:input];
    [dialog addButtonWithTitle:@"OK"];
    [dialog addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    [[dialog window] makeFirstResponder:input];
    if ([dialog runModal] != NSAlertFirstButtonReturn) return;

    NSString *newName = CWGValidatedTunnelName([input stringValue]);
    if (!newName) {
        [self alert:@"Import error: the config contains special characters or is not an AmneziaWG/WireGuard config. Rename the config or try again."];
        return;
    }
    if ([newName isEqualToString:oldName]) {
        [self alert:@"Name unchanged."];
        return;
    }

    NSError *error = nil;
    if (![self.store renameTunnel:oldName toName:newName error:&error]) {
        [self alert:[error localizedDescription]];
        return;
    }
    [self refreshStatus];

    self.operationInFlight = YES;
    NSString *token = [CWGServiceInstaller token];
    NSString *configuration = [self.store configurationForTunnel:newName];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CWGDaemonClient *client = [[CWGDaemonClient alloc] initWithToken:token];
        CWGTunnelStatus *status = [client status];
        BOOL shouldRestart = [status isActive] && [status.name isEqualToString:oldName];
        BOOL restarted = NO;
        NSString *operationError = nil;
        if (shouldRestart && [client bringDownWithError:&operationError]) {
            restarted = [client bringUpTunnel:newName configuration:configuration error:&operationError];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationInFlight = NO;
            if (operationError) {
                [self alert:[NSString stringWithFormat:@"Renamed to %@, but tunnel restart failed:\n\n%@", newName, operationError]];
            } else if (restarted) {
                [self alert:[NSString stringWithFormat:@"Renamed to %@. Tunnel restarted.", newName]];
            } else {
                [self alert:[NSString stringWithFormat:@"Renamed to %@.", newName]];
            }
            [self refreshStatus];
        });
    });
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

- (NSTextField *)addStatusRowToView:(NSView *)view title:(NSString *)title value:(NSString *)value y:(CGFloat)y {
    [view addSubview:[self statusLabel:title frame:NSMakeRect(20, y, 125, 20) bold:NO]];
    NSTextField *valueLabel = [self statusLabel:value.length > 0 ? value : @"—" frame:NSMakeRect(150, y, 290, 20) bold:YES];
    [view addSubview:valueLabel];
    return valueLabel;
}

- (NSButton *)windowButton:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return button;
}

- (NSString *)localAddressForStatus:(CWGTunnelStatus *)status {
    NSString *configuration = [self.store configurationForTunnel:status.name];
    BOOL interfaceSection = NO;
    for (NSString *line in [configuration componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"["]) {
            interfaceSection = [trimmed caseInsensitiveCompare:@"[Interface]"] == NSOrderedSame;
            continue;
        }
        if (!interfaceSection) continue;
        NSRange separator = [trimmed rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([key caseInsensitiveCompare:@"Address"] == NSOrderedSame) {
            return [[trimmed substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return @"—";
}

- (NSImage *)statusDotImageForState:(NSString *)state {
    NSColor *color = [NSColor grayColor];
    if ([state isEqualToString:@"connected"]) {
        color = [NSColor colorWithCalibratedRed:0.12 green:0.65 blue:0.20 alpha:1.0];
    } else if ([state isEqualToString:@"connecting"]) {
        color = [NSColor orangeColor];
    }
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(14, 14)];
    [image lockFocus];
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 14, 14)] fill];
    [image unlockFocus];
    return image;
}

- (void)updateStatusWindowWithStatus:(CWGTunnelStatus *)status {
    if (!self.statusWindow || !self.statusValueLabels) return;
    [self.statusStateLabel setStringValue:[status readableState]];
    [self.statusDotView setImage:[self statusDotImageForState:status.state]];

    NSString *handshake = @"Never";
    if (status.lastHandshake > 0) {
        long long seconds = (long long)([[NSDate date] timeIntervalSince1970] - (NSTimeInterval)status.lastHandshake);
        if (seconds < 0) seconds = 0;
        handshake = [NSString stringWithFormat:@"%lld sec ago", seconds];
    }
    NSDictionary *values = [NSDictionary dictionaryWithObjectsAndKeys:
        status.name.length > 0 ? status.name : @"—", @"tunnel",
        [self localAddressForStatus:status], @"localIP",
        status.endpoint.length > 0 ? status.endpoint : @"—", @"endpoint",
        status.listenPort > 0 ? [NSString stringWithFormat:@"%d", status.listenPort] : @"—", @"listenPort",
        handshake, @"handshake",
        CWGFormatBytes(status.receivedBytes), @"received",
        CWGFormatBytes(status.transmittedBytes), @"transmitted",
        self.countryValue ?: @"—", @"country",
        self.ispValue ?: @"—", @"isp", nil];
    for (NSString *key in values) {
        [[self.statusValueLabels objectForKey:key] setStringValue:[values objectForKey:key]];
    }
}

- (NSDictionary *)networkInformation {
    @try {
        __block NSTask *task = nil;
        __block NSPipe *pipe = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/curl"];
            [task setArguments:[NSArray arrayWithObjects:@"-fsSL", @"--max-time", @"5", @"ipinfo.io", nil]];
            pipe = [NSPipe pipe];
            [task setStandardOutput:pipe];
            [task setStandardError:pipe];
            [task launch];
        });
        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        id JSON = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![JSON isKindOfClass:[NSDictionary class]]) return nil;

        NSString *code = [[JSON objectForKey:@"country"] isKindOfClass:[NSString class]] ? [[JSON objectForKey:@"country"] uppercaseString] : nil;
        NSString *country = code.length == 2 ? [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"] displayNameForKey:NSLocaleCountryCode value:code] : nil;
        NSString *isp = [[JSON objectForKey:@"org"] isKindOfClass:[NSString class]] ? [JSON objectForKey:@"org"] : nil;
        if (!isp && [[JSON objectForKey:@"isp"] isKindOfClass:[NSString class]]) isp = [JSON objectForKey:@"isp"];
        if ([isp hasPrefix:@"AS"]) {
            NSRange space = [isp rangeOfString:@" "];
            if (space.location != NSNotFound) isp = [isp substringFromIndex:space.location + 1];
        }
        return [NSDictionary dictionaryWithObjectsAndKeys:
            country.length > 0 ? country : @"Unknown", @"country",
            isp.length > 0 ? isp : @"Unknown", @"isp", nil];
    } @catch (NSException *exception) {
        return nil;
    }
}

- (void)updateNetworkInfoForStatus:(CWGTunnelStatus *)status {
    NSString *key = [NSString stringWithFormat:@"%@:%@", status.state ?: @"", status.name ?: @""];
    if ([self.networkInfoKey isEqualToString:key]) return;
    self.networkInfoKey = key;
    if ([status.state isEqualToString:@"connecting"]) {
        self.countryValue = @"Looking up…";
        self.ispValue = @"Looking up…";
        [self updateStatusWindowWithStatus:status];
        return;
    }
    [self updateStatusWindowWithStatus:status];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *information = [self networkInformation];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.networkInfoKey isEqualToString:key]) return;
            self.countryValue = [information objectForKey:@"country"] ?: @"Unknown";
            self.ispValue = [information objectForKey:@"isp"] ?: @"Unknown";
            [self updateStatusWindowWithStatus:status];
        });
    });
}

- (void)presentStatusWindowWithStatus:(CWGTunnelStatus *)status {
    [self.statusWindow close];
    self.statusWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 456)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];
    [self.statusWindow setTitle:@"CloletteWG Status"];
    [self.statusWindow setReleasedWhenClosed:NO];
    self.statusValueLabels = [NSMutableDictionary dictionary];
    NSView *content = [self.statusWindow contentView];

    self.statusDotView = [[NSImageView alloc] initWithFrame:NSMakeRect(21, 414, 14, 14)];
    [content addSubview:self.statusDotView];
    self.statusStateLabel = [self statusLabel:@"" frame:NSMakeRect(46, 406, 394, 24) bold:YES];
    [self.statusStateLabel setFont:[NSFont boldSystemFontOfSize:14.0]];
    [content addSubview:self.statusStateLabel];

    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Tunnel" value:@"" y:358] forKey:@"tunnel"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Local IP" value:@"" y:326] forKey:@"localIP"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Endpoint" value:@"" y:294] forKey:@"endpoint"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Listen port" value:@"" y:262] forKey:@"listenPort"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Last handshake" value:@"" y:230] forKey:@"handshake"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Received" value:@"" y:198] forKey:@"received"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Transmitted" value:@"" y:166] forKey:@"transmitted"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"Country" value:@"" y:134] forKey:@"country"];
    [self.statusValueLabels setObject:[self addStatusRowToView:content title:@"ISP" value:@"" y:102] forKey:@"isp"];
    [content addSubview:[self windowButton:@"Daemon Log…" frame:NSMakeRect(20, 32, 120, 28) action:@selector(showDaemonLog:)]];
    [content addSubview:[self windowButton:@"Close" frame:NSMakeRect(360, 32, 80, 28) action:@selector(closeStatusWindow:)]];
    [self updateStatusWindowWithStatus:status];
    [self updateNetworkInfoForStatus:status];
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
    if (![self.currentStatus isActive]) {
        [NSApp terminate:nil];
        return;
    }

    NSAlert *confirm = [[NSAlert alloc] init];
    [confirm setMessageText:@"Are you sure you want to quit? The tunnel will be disconnected!"];
    [confirm addButtonWithTitle:@"Yes"];
    [confirm addButtonWithTitle:@"No"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSString *error = nil;
    if (![[self daemonClient] bringDownWithError:&error]) {
        [self alert:[NSString stringWithFormat:@"Could not disconnect the tunnel:\n\n%@", error ?: @"Unknown error"]];
        return;
    }
    [NSApp terminate:nil];
}

@end
