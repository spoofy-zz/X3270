#import "PreferencesWindowController.h"
#import "TerminalView.h"

@implementation PreferencesWindowController {
    NSButton *_use3270FontCheckbox;
    NSTextField *_fontSizeField;
    NSStepper *_fontSizeStepper;
    NSMutableDictionary<NSString*, NSPopUpButton*> *_keyMappingPopups;
}

+ (instancetype)sharedController {
    static PreferencesWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSWindow *win = [[NSWindow alloc]
                         initWithContentRect:NSMakeRect(0, 0, 520, 520)
                                   styleMask:NSWindowStyleMaskTitled
                                            |NSWindowStyleMaskClosable
                                   backing:NSBackingStoreBuffered
                                      defer:NO];
        win.title = @"DX3270 — Preferences";
        win.releasedWhenClosed = NO;
        [win center];
        shared = [[PreferencesWindowController alloc] initWithWindow:win];
        [shared buildUI];
    });
    return shared;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;
    _keyMappingPopups = [NSMutableDictionary dictionary];

    // ── Section: Font ─────────────────────────────────────────────────────────
    NSTextField *fontHeader = [NSTextField labelWithString:@"Terminal Font"];
    fontHeader.font = [NSFont boldSystemFontOfSize:13];
    fontHeader.frame = NSMakeRect(margin, 480, 480, 20);
    [cv addSubview:fontHeader];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 474, 480, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];

    // Checkbox: use IBM 3270 font
    _use3270FontCheckbox = [NSButton checkboxWithTitle:@"Use IBM 3270 font (by Ricardo Bánffy)"
                                                target:self
                                                action:@selector(fontCheckboxChanged:)];
    _use3270FontCheckbox.frame = NSMakeRect(margin, 446, 480, 22);
    BOOL currentValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    _use3270FontCheckbox.state = currentValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_use3270FontCheckbox];

    NSTextField *sizeLabel = [NSTextField labelWithString:@"Size:"];
    sizeLabel.frame = NSMakeRect(margin + 18, 414, 42, 22);
    [cv addSubview:sizeLabel];

    _fontSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(margin + 62, 412, 52, 24)];
    _fontSizeField.alignment = NSTextAlignmentRight;
    _fontSizeField.target = self;
    _fontSizeField.action = @selector(fontSizeFieldChanged:);
    [cv addSubview:_fontSizeField];

    _fontSizeStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(margin + 120, 410, 20, 28)];
    _fontSizeStepper.minValue = 8.0;
    _fontSizeStepper.maxValue = 32.0;
    _fontSizeStepper.increment = 1.0;
    _fontSizeStepper.target = self;
    _fontSizeStepper.action = @selector(fontSizeStepperChanged:);
    [cv addSubview:_fontSizeStepper];
    [self syncFontSizeControls];

    // Descriptive note
    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Replaces the default Menlo font with the authentic IBM 3270 monospace font. "
         "The font is bundled with this app and designed to match the look of original "
         "IBM 3270 terminals."];
    note.textColor = [NSColor secondaryLabelColor];
    note.font = [NSFont systemFontOfSize:11];
    note.frame = NSMakeRect(margin + 18, 356, 452, 48);
    [cv addSubview:note];

    // Attribution link
    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"3270font on GitHub (github.com/rbanffy/3270font)"
            attributes:@{
                NSFontAttributeName:            [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin + 18, 334, 452, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(open3270FontLink:);
    linkBtn.alignment = NSTextAlignmentLeft;
    [cv addSubview:linkBtn];

    // ── Section: Keyboard mapping ─────────────────────────────────────────────
    NSTextField *keyHeader = [NSTextField labelWithString:@"Keyboard Mapping"];
    keyHeader.font = [NSFont boldSystemFontOfSize:13];
    keyHeader.frame = NSMakeRect(margin, 292, 480, 20);
    [cv addSubview:keyHeader];

    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 286, 480, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];

    NSArray<NSArray<NSString*>*> *rows = @[
        @[@"enter",  @"Enter AID"],
        @[@"return", @"Return / New Line"],
        @[@"clear",  @"Clear"],
        @[@"reset",  @"Reset"],
        @[@"pa1",    @"PA1"],
        @[@"pa2",    @"PA2"],
        @[@"pa3",    @"PA3"],
    ];

    CGFloat y = 252;
    for (NSArray<NSString*> *row in rows) {
        NSTextField *label = [NSTextField labelWithString:row[1]];
        label.frame = NSMakeRect(margin + 18, y + 4, 150, 20);
        [cv addSubview:label];

        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margin + 180, y, 220, 26)
                                                          pullsDown:NO];
        [self populateKeyMappingPopup:popup];
        popup.target = self;
        popup.action = @selector(keyMappingChanged:);
        popup.identifier = row[0];
        _keyMappingPopups[row[0]] = popup;
        [cv addSubview:popup];
        y -= 32;
    }
    [self syncKeyMappingControls];

    NSButton *resetKeys = [NSButton buttonWithTitle:@"Reset Keyboard Defaults"
                                             target:self
                                             action:@selector(resetKeyboardMappings:)];
    resetKeys.frame = NSMakeRect(margin + 18, 22, 180, 28);
    [cv addSubview:resetKeys];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)fontCheckboxChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPref3270FontEnabled];
    [self syncFontSizeControls];
    // NSUserDefaultsDidChangeNotification is posted automatically; TerminalView observes it.
}

- (double)currentFontSizePreference {
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kPrefTerminalFontSize];
    BOOL use3270 = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    return stored ? stored.doubleValue : (use3270 ? 16.0 : 14.0);
}

- (void)syncFontSizeControls {
    double size = [self currentFontSizePreference];
    _fontSizeField.doubleValue = size;
    _fontSizeStepper.doubleValue = size;
}

- (void)setFontSizePreference:(double)size {
    double clamped = MIN(32.0, MAX(8.0, size));
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:kPrefTerminalFontSize];
    [self syncFontSizeControls];
}

- (void)fontSizeFieldChanged:(NSTextField *)sender {
    [self setFontSizePreference:sender.doubleValue];
}

- (void)fontSizeStepperChanged:(NSStepper *)sender {
    [self setFontSizePreference:sender.doubleValue];
}

- (NSDictionary<NSString*, NSString*> *)defaultKeyboardMappings {
    return @{
        @"enter":  @"return",
        @"return": @"shift-return",
        @"clear":  @"option-escape",
        @"reset":  @"escape",
        @"pa1":    @"option-1",
        @"pa2":    @"option-2",
        @"pa3":    @"option-3",
    };
}

- (NSArray<NSArray<NSString*>*> *)keyMappingChoices {
    return @[
        @[@"return",        @"Return"],
        @[@"shift-return",  @"Shift-Return"],
        @[@"escape",        @"Escape"],
        @[@"option-escape", @"Option-Escape"],
        @[@"option-1",      @"Option-1"],
        @[@"option-2",      @"Option-2"],
        @[@"option-3",      @"Option-3"],
        @[@"f1",            @"F1"],
        @[@"f2",            @"F2"],
        @[@"f3",            @"F3"],
        @[@"f4",            @"F4"],
        @[@"f5",            @"F5"],
        @[@"f6",            @"F6"],
        @[@"f7",            @"F7"],
        @[@"f8",            @"F8"],
        @[@"f9",            @"F9"],
        @[@"f10",           @"F10"],
        @[@"f11",           @"F11"],
        @[@"f12",           @"F12"],
    ];
}

- (NSDictionary<NSString*, NSString*> *)currentKeyboardMappings {
    NSMutableDictionary *m = [[self defaultKeyboardMappings] mutableCopy];
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPrefKeyboardMappings];
    if (stored) [m addEntriesFromDictionary:stored];
    return m;
}

- (void)populateKeyMappingPopup:(NSPopUpButton *)popup {
    [popup removeAllItems];
    for (NSArray<NSString*> *choice in [self keyMappingChoices]) {
        [popup addItemWithTitle:choice[1]];
        popup.lastItem.representedObject = choice[0];
    }
}

- (void)syncKeyMappingControls {
    NSDictionary<NSString*, NSString*> *m = [self currentKeyboardMappings];
    for (NSString *action in _keyMappingPopups) {
        NSString *signature = m[action];
        NSPopUpButton *popup = _keyMappingPopups[action];
        for (NSMenuItem *item in popup.itemArray) {
            if ([item.representedObject isEqualToString:signature]) {
                [popup selectItem:item];
                break;
            }
        }
    }
}

- (void)keyMappingChanged:(NSPopUpButton *)sender {
    NSString *action = sender.identifier;
    NSString *signature = sender.selectedItem.representedObject;
    if (!action || !signature) return;

    NSMutableDictionary *m = [[[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kPrefKeyboardMappings] mutableCopy] ?: [NSMutableDictionary dictionary];
    m[action] = signature;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kPrefKeyboardMappings];
}

- (void)resetKeyboardMappings:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPrefKeyboardMappings];
    [self syncKeyMappingControls];
}

- (void)open3270FontLink:(id)sender {
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"https://github.com/rbanffy/3270font"]];
}

@end
