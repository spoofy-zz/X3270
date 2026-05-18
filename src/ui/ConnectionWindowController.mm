#import "ConnectionWindowController.h"
#import "TerminalWindowController.h"

@implementation ConnectionWindowController {
    NSTextField    *_hostField;
    NSTextField    *_portField;
    NSButton       *_sslCheckbox;
    NSTextField    *_caField;
    NSPopUpButton  *_codePagePopup;
    NSButton       *_connectButton;
    NSTextField    *_statusLabel;

    NSMutableArray<TerminalWindowController*> *_terminals;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 420, 350)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = @"X3270 — Connect to Host";
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        _terminals = [NSMutableArray array];
        [self buildUI];
        [self restoreLastConnection];
    }
    return self;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;
    CGFloat hdrW = 380;
    CGFloat labelW = 100, fieldW = 240, rowH = 24, gap = 10;
    __block CGFloat curY = 220;

    // ── Header: app name, version and author ──────────────────────────────────
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0.1";

    NSTextField *appName = [NSTextField labelWithString:@"X3270"];
    appName.font = [NSFont boldSystemFontOfSize:16];
    appName.alignment = NSTextAlignmentCenter;
    appName.frame = NSMakeRect(margin, 314, hdrW, 24);
    [cv addSubview:appName];

    NSTextField *appSubtitle = [NSTextField labelWithString:
        [NSString stringWithFormat:@"TN3270 Terminal Emulator  \u2013  v%@", version]];
    appSubtitle.font = [NSFont systemFontOfSize:11];
    appSubtitle.textColor = [NSColor secondaryLabelColor];
    appSubtitle.alignment = NSTextAlignmentCenter;
    appSubtitle.frame = NSMakeRect(margin, 294, hdrW, 16);
    [cv addSubview:appSubtitle];

    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"by Swen Kalski  \u00b7  github.com/el-dockerr/X3270"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin, 272, hdrW, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(openGitHub:);
    linkBtn.alignment = NSTextAlignmentCenter;
    [cv addSubview:linkBtn];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 258, hdrW, 1)];
    separator.boxType = NSBoxSeparator;
    [cv addSubview:separator];

    // ── Helper block ──────────────────────────────────────────────────────────
    void(^addRow)(NSString*, NSView*) = ^(NSString *label, NSView *field) {
        NSTextField *lbl = [NSTextField labelWithString:label];
        lbl.frame = NSMakeRect(margin, curY, labelW, rowH);
        lbl.alignment = NSTextAlignmentRight;
        [cv addSubview:lbl];

        field.frame = NSMakeRect(margin + labelW + gap, curY, fieldW, rowH);
        [cv addSubview:field];
        curY -= rowH + gap;
    };

    // Host
    _hostField = [NSTextField textFieldWithString:@""];
    _hostField.placeholderString = @"hostname or IP";
    addRow(@"Host:", _hostField);

    // Port
    _portField = [NSTextField textFieldWithString:@"23"];
    _portField.placeholderString = @"23";
    addRow(@"Port:", _portField);

    // SSL
    _sslCheckbox = [NSButton checkboxWithTitle:@"Use SSL/TLS (port 992)"
                                        target:self
                                        action:@selector(sslToggled:)];
    _sslCheckbox.frame = NSMakeRect(margin + labelW + gap, curY, fieldW, rowH);
    [cv addSubview:_sslCheckbox];
    curY -= rowH + gap;

    // CA Bundle (hidden by default)
    _caField = [NSTextField textFieldWithString:@""];
    _caField.placeholderString = @"(optional) path to CA bundle .pem";
    _caField.hidden = YES;
    addRow(@"CA Bundle:", _caField);

    // Code page
    _codePagePopup = [[NSPopUpButton alloc] init];
    [_codePagePopup addItemsWithTitles:@[@"CP037 (US/Canada)", @"CP500 (International)", @"CP1047 (Open Systems)"]];
    addRow(@"Code Page:", _codePagePopup);

    // Status label
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.textColor = [NSColor systemRedColor];
    _statusLabel.frame = NSMakeRect(margin, curY, 380, rowH);
    [cv addSubview:_statusLabel];
    curY -= rowH + gap;

    // Connect button
    _connectButton = [NSButton buttonWithTitle:@"Connect"
                                        target:self
                                        action:@selector(connect:)];
    _connectButton.bezelStyle = NSBezelStyleRounded;
    _connectButton.frame = NSMakeRect(self.window.contentView.bounds.size.width - 120 - margin,
                                       12, 120, 32);
    [cv addSubview:_connectButton];
    self.window.defaultButtonCell = _connectButton.cell;
}

- (void)openGitHub:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://github.com/el-dockerr/X3270"]];
}

- (void)sslToggled:(id)sender {
    BOOL sslOn = _sslCheckbox.state == NSControlStateValueOn;
    _caField.hidden = !sslOn;
    if (sslOn && [_portField.stringValue isEqualToString:@"23"]) {
        _portField.stringValue = @"992";
    } else if (!sslOn && [_portField.stringValue isEqualToString:@"992"]) {
        _portField.stringValue = @"23";
    }
}

- (void)connect:(id)sender {
    NSString *host = [_hostField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    if (host.length == 0) {
        _statusLabel.stringValue = @"Please enter a hostname.";
        return;
    }

    int port = _portField.intValue;
    if (port <= 0 || port > 65535) {
        _statusLabel.stringValue = @"Invalid port number.";
        return;
    }

    BOOL useSSL = _sslCheckbox.state == NSControlStateValueOn;
    NSString *caBundle = useSSL ? _caField.stringValue : @"";

    // Map code page selection
    x3270::CodePage cp;
    switch (_codePagePopup.indexOfSelectedItem) {
    case 1:  cp = x3270::CodePage::CP500;  break;
    case 2:  cp = x3270::CodePage::CP1047; break;
    default: cp = x3270::CodePage::CP037;  break;
    }

    _connectButton.enabled = NO;
    _statusLabel.stringValue = @"Connecting…";
    [self saveLastConnection];

    TerminalWindowController *twc =
        [[TerminalWindowController alloc] initWithHost:host
                                                  port:(uint16_t)port
                                                useSSL:useSSL
                                              caBundle:caBundle
                                             codePage:cp];
    [_terminals addObject:twc];
    [twc showWindow:nil];

    // Observe connection result
    __weak typeof(self) weakSelf = self;
    __weak typeof(twc)  weakTwc  = twc;
    twc.onConnectError = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                s.statusLabel.stringValue = error ?: @"Connection failed.";
                s.connectButton.enabled = YES;
                [s.terminals removeObject:weakTwc];
            }
        });
    };
    twc.onConnected = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                s.statusLabel.stringValue = @"";
                s.connectButton.enabled = YES;
            }
        });
    };
}

// Expose for connection result callbacks
- (NSTextField*)statusLabel { return _statusLabel; }
- (NSButton*)connectButton  { return _connectButton; }
- (NSMutableArray*)terminals { return _terminals; }

// ── NSUserDefaults persistence ────────────────────────────────────────────────
- (void)restoreLastConnection {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *host = [ud stringForKey:@"x3270.lastHost"];
    NSString *port = [ud stringForKey:@"x3270.lastPort"];
    if (host.length > 0) _hostField.stringValue = host;
    if (port.length > 0) _portField.stringValue = port;
    BOOL ssl = [ud boolForKey:@"x3270.lastSSL"];
    _sslCheckbox.state = ssl ? NSControlStateValueOn : NSControlStateValueOff;
    _caField.hidden = !ssl;
    NSInteger cp = [ud integerForKey:@"x3270.lastCodePage"];
    if (cp >= 0 && cp < (NSInteger)_codePagePopup.numberOfItems) {
        [_codePagePopup selectItemAtIndex:cp];
    }
}

- (void)saveLastConnection {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:_hostField.stringValue        forKey:@"x3270.lastHost"];
    [ud setObject:_portField.stringValue        forKey:@"x3270.lastPort"];
    [ud setBool:(_sslCheckbox.state == NSControlStateValueOn)
         forKey:@"x3270.lastSSL"];
    [ud setInteger:_codePagePopup.indexOfSelectedItem
            forKey:@"x3270.lastCodePage"];
}

@end
