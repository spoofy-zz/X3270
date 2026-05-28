#import "ConnectionWindowController.h"
#import "TerminalWindowController.h"
#include "TerminalModel.h"

@implementation ConnectionWindowController {
    NSComboBox     *_hostCombo;
    NSTextField    *_portField;
    NSButton       *_sslCheckbox;
    NSTextField    *_caField;
    NSPopUpButton  *_codePagePopup;
    NSPopUpButton  *_modelPopup;
    NSButton       *_connectButton;
    NSTextField    *_statusLabel;

    NSMutableArray<TerminalWindowController*>  *_terminals;
    NSMutableArray<NSDictionary*>              *_connectionHistory;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 420, 410)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = @"DX3270 — Connect to Host";
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        _terminals = [NSMutableArray array];
        [self buildUI];
        [self restoreConnectionHistory];
    }
    return self;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;
    CGFloat hdrW = 380;
    CGFloat labelW = 100, fieldW = 240, rowH = 24, gap = 10;
    __block CGFloat curY = 270;

    // ── Header: app name, version and author ──────────────────────────────────
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.5.0";

    NSTextField *appName = [NSTextField labelWithString:@"DX3270"];
    appName.font = [NSFont boldSystemFontOfSize:16];
    appName.alignment = NSTextAlignmentCenter;
    appName.frame = NSMakeRect(margin, 374, hdrW, 24);
    [cv addSubview:appName];

    NSTextField *appSubtitle = [NSTextField labelWithString:
        [NSString stringWithFormat:@"TN3270 Terminal Emulator  \u2013  v%@", version]];
    appSubtitle.font = [NSFont systemFontOfSize:11];
    appSubtitle.textColor = [NSColor secondaryLabelColor];
    appSubtitle.alignment = NSTextAlignmentCenter;
    appSubtitle.frame = NSMakeRect(margin, 354, hdrW, 16);
    [cv addSubview:appSubtitle];

    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"by Swen Kalski  \u00b7  github.com/el-dockerr/X3270"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin, 332, hdrW, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(openGitHub:);
    linkBtn.alignment = NSTextAlignmentCenter;
    [cv addSubview:linkBtn];

    // Donation link
    NSMutableAttributedString *donateTitle = [[NSMutableAttributedString alloc]
        initWithString:@"\u2665  Support this project — Buy me a coffee"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor systemPinkColor],
            }];
    NSButton *donateBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin, 312, hdrW, 16)];
    [donateBtn setAttributedTitle:donateTitle];
    donateBtn.buttonType = NSButtonTypeMomentaryLight;
    donateBtn.bordered = NO;
    donateBtn.target = self;
    donateBtn.action = @selector(openDonation:);
    donateBtn.alignment = NSTextAlignmentCenter;
    [cv addSubview:donateBtn];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 298, hdrW, 1)];
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

    // Host — editable combo with connection history
    _hostCombo = [[NSComboBox alloc] init];
    _hostCombo.placeholderString = @"hostname or IP";
    _hostCombo.completes = YES;
    _hostCombo.numberOfVisibleItems = 10;
    _hostCombo.delegate = self;
    addRow(@"Host:", _hostCombo);

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

    // Screen model
    _modelPopup = [[NSPopUpButton alloc] init];
    [_modelPopup addItemsWithTitles:@[
        @"Model 2 \u2014 24\u00d780 (default)",
        @"Model 3 \u2014 32\u00d780",
        @"Model 4 \u2014 43\u00d780",
        @"Model 5 \u2014 27\u00d7132 (wide)",
        @"Large \u2014 62\u00d7160 (non-standard)",
    ]];
    addRow(@"Screen Model:", _modelPopup);

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

- (void)openDonation:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://buy.stripe.com/7sY9AT3VMfKi53942m3VC05"]];
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
    NSString *host = [_hostCombo.stringValue stringByTrimmingCharactersInSet:
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

    // Map screen model selection
    x3270::TerminalModel model;
    switch (_modelPopup.indexOfSelectedItem) {
    case 1:  model = x3270::TerminalModel::Model3;      break;
    case 2:  model = x3270::TerminalModel::Model4;      break;
    case 3:  model = x3270::TerminalModel::Model5;      break;
    case 4:  model = x3270::TerminalModel::LargeCustom; break;
    default: model = x3270::TerminalModel::Model2;      break;
    }

    _connectButton.enabled = NO;
    _statusLabel.stringValue = @"Connecting…";
    [self saveConnectionToHistory];

    TerminalWindowController *twc =
        [[TerminalWindowController alloc] initWithHost:host
                                                  port:(uint16_t)port
                                                useSSL:useSSL
                                              caBundle:caBundle
                                             codePage:cp
                                                model:model];
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

// ── Connection history persistence ───────────────────────────────────────────
static NSString * const kHistoryKey = @"x3270.connectionHistory";
static const NSInteger  kHistoryMax = 20;

/// Label shown in the drop-down for a history entry ("host:port" or "host:port [SSL]").
- (NSString *)labelForEntry:(NSDictionary *)entry {
    NSString *suffix = [entry[@"ssl"] boolValue] ? @" [SSL]" : @"";
    return [NSString stringWithFormat:@"%@:%@%@", entry[@"host"], entry[@"port"], suffix];
}

/// Rebuild combo box items from _connectionHistory.
- (void)rebuildComboItems {
    [_hostCombo removeAllItems];
    for (NSDictionary *e in _connectionHistory)
        [_hostCombo addItemWithObjectValue:[self labelForEntry:e]];
}

/// Load history and pre-fill fields from the most recent entry.
- (void)restoreConnectionHistory {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryKey];
    _connectionHistory = saved ? [saved mutableCopy] : [NSMutableArray array];
    [self rebuildComboItems];
    if (_connectionHistory.count > 0) {
        NSDictionary *last = _connectionHistory[0];
        _hostCombo.stringValue  = last[@"host"] ?: @"";
        _portField.stringValue  = last[@"port"] ?: @"23";
        BOOL ssl = [last[@"ssl"] boolValue];
        _sslCheckbox.state = ssl ? NSControlStateValueOn : NSControlStateValueOff;
        _caField.hidden = !ssl;
        _caField.stringValue = last[@"ca"] ?: @"";
        NSInteger cp = [last[@"codepage"] integerValue];
        if (cp >= 0 && cp < _codePagePopup.numberOfItems)
            [_codePagePopup selectItemAtIndex:cp];
        NSInteger model = [last[@"model"] integerValue];
        if (model >= 0 && model < _modelPopup.numberOfItems)
            [_modelPopup selectItemAtIndex:model];
    }
}

/// Push current connection to top of history; deduplicate by host:port; cap at kHistoryMax.
- (void)saveConnectionToHistory {
    NSString *host = [_hostCombo.stringValue
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *port = _portField.stringValue;
    BOOL      ssl  = (_sslCheckbox.state == NSControlStateValueOn);

    NSDictionary *entry = @{
        @"host":     host,
        @"port":     port,
        @"ssl":      @(ssl),
        @"ca":       _caField.stringValue ?: @"",
        @"codepage": @(_codePagePopup.indexOfSelectedItem),
        @"model":    @(_modelPopup.indexOfSelectedItem),
    };

    // Remove existing entry for same host:port so it moves to top
    NSString *key = [NSString stringWithFormat:@"%@:%@", host, port];
    [_connectionHistory filterUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *e, id __unused b) {
            return ![[NSString stringWithFormat:@"%@:%@", e[@"host"], e[@"port"]]
                     isEqualToString:key];
        }]];

    [_connectionHistory insertObject:entry atIndex:0];
    if (_connectionHistory.count > kHistoryMax)
        [_connectionHistory removeLastObject];

    [[NSUserDefaults standardUserDefaults] setObject:_connectionHistory forKey:kHistoryKey];
    [self rebuildComboItems];
}

// ── NSComboBoxDelegate ────────────────────────────────────────────────────────
- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    NSInteger idx = _hostCombo.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)_connectionHistory.count) return;
    NSDictionary *entry = _connectionHistory[idx];
    _hostCombo.stringValue  = entry[@"host"];
    _portField.stringValue  = entry[@"port"];
    BOOL ssl = [entry[@"ssl"] boolValue];
    _sslCheckbox.state = ssl ? NSControlStateValueOn : NSControlStateValueOff;
    _caField.hidden = !ssl;
    _caField.stringValue = entry[@"ca"] ?: @"";
    NSInteger cp = [entry[@"codepage"] integerValue];
    if (cp >= 0 && cp < _codePagePopup.numberOfItems)
        [_codePagePopup selectItemAtIndex:cp];
    NSInteger model = [entry[@"model"] integerValue];
    if (model >= 0 && model < _modelPopup.numberOfItems)
        [_modelPopup selectItemAtIndex:model];
}

@end
