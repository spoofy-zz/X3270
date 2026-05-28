#import "TerminalView.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "EbcdicCodec.h"
#include <string>

/// NSUserDefaults key – BOOL; YES = use bundled IBM 3270 font
NSString * const kPref3270FontEnabled = @"use3270Font";

// ── 3270-font loader (called once) ───────────────────────────────────────────
// Registers all three weight variants from the app bundle's Resources/fonts/
// folder with Core Text so they can be loaded by name.
static void register3270FontsIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString*> *names = @[
            @"3270-Regular",
            @"3270SemiCondensed-Regular",
            @"3270Condensed-Regular",
        ];
        NSBundle *bundle = [NSBundle mainBundle];
        for (NSString *name in names) {
            NSURL *url = [bundle URLForResource:name
                                  withExtension:@"otf"
                                   subdirectory:@"fonts"];
            if (!url) continue;
            CFErrorRef err = NULL;
            CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                             kCTFontManagerScopeProcess,
                                             &err);
            if (err) { CFRelease(err); }
        }
    });
}

static const int kOIARows = 2;

// ── IBM 3279 extended colour palette ─────────────────────────────────────────
// Maps the 3270 extended attribute colour code (0xF1-0xF7) to an NSColor.
// Returns nil for unknown/default codes; caller uses the field-attribute default.
static NSColor *colorFor3270Code(uint8_t code) {
    switch (code) {
    case 0xF1: return [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0]; // blue
    case 0xF2: return [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0]; // red
    case 0xF3: return [NSColor colorWithRed:1.00 green:0.44 blue:1.00 alpha:1.0]; // pink/magenta
    case 0xF4: return [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green
    case 0xF5: return [NSColor colorWithRed:0.20 green:0.85 blue:0.85 alpha:1.0]; // turquoise/cyan
    case 0xF6: return [NSColor colorWithRed:0.85 green:0.85 blue:0.20 alpha:1.0]; // yellow
    case 0xF7: return [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]; // neutral white
    default:   return nil;
    }
}

@implementation TerminalView {
    x3270::ScreenBuffer*  _screen;
    x3270::KeyboardState* _kbd;
    x3270::EbcdicCodec    _codec;

    NSTimer* _cursorTimer;
    BOOL     _cursorVisible;

    int      _rows;    // character grid rows (mirrors _screen->rows())
    int      _cols;    // character grid cols (mirrors _screen->cols())
    CGFloat  _charW;   // character cell width
    CGFloat  _charH;   // character cell height (ascent + descent + leading)
    CGFloat  _baseline; // distance from cell bottom to text baseline
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _codec = x3270::EbcdicCodec(x3270::CodePage::CP037);
        _cursorVisible = YES;
        _rows = 24;  // default; updated when screen buffer is attached
        _cols = 80;

        // Register the bundled 3270 font variants with Core Text (once per process)
        register3270FontsIfNeeded();

        // Default 3270 colour palette (matches IBM 3279 standard defaults)
        _foregroundColor  = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green (unprotected normal)
        _backgroundColor  = [NSColor colorWithRed:0.0  green:0.0  blue:0.0  alpha:1.0]; // black
        _intensifiedColor = [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0]; // red  (unprotected intensified)
        _cursorColor      = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green

        [self applyFontFromPreferences];
        [self recalcCellSize];

        _cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                        target:self
                                                      selector:@selector(blinkCursor:)
                                                      userInfo:nil
                                                       repeats:YES];

        // React to preference changes made in the Preferences window
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:nil];
    }
    return self;
}

// ── Font preference helpers ───────────────────────────────────────────────────

/// Pick the right NSFont based on the current kPref3270FontEnabled user default.
- (void)applyFontFromPreferences {
    BOOL use3270 = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    if (use3270) {
        // PostScript name is "3270-Regular" (confirmed from the OTF name table)
        _terminalFont = [NSFont fontWithName:@"3270-Regular" size:16.0]
                     ?: [NSFont fontWithName:@"Menlo" size:14.0]
                     ?: [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightRegular];
    } else {
        _terminalFont = [NSFont fontWithName:@"Menlo" size:14.0]
                     ?: [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightRegular];
    }
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    [self applyFontFromPreferences];
    [self recalcCellSize];
    [self setNeedsDisplay:YES];
    // Resize the window to the new preferred size (cell dimensions may have changed)
    [self.window setContentSize:[self preferredSize]];
}

- (void)dealloc {
    [_cursorTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // ARC handles object release
}

- (void)recalcCellSize {
    CTFontRef ctFont = (__bridge CTFontRef)_terminalFont;

    // Use Core Text advance width for pixel-precise grid alignment
    UniChar mChar = 'M';
    CGGlyph mGlyph;
    CTFontGetGlyphsForCharacters(ctFont, &mChar, &mGlyph, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(ctFont, kCTFontOrientationHorizontal, &mGlyph, &adv, 1);
    _charW = ceil(adv.width);

    CGFloat ascent  = CTFontGetAscent(ctFont);
    CGFloat descent = CTFontGetDescent(ctFont);
    CGFloat leading = CTFontGetLeading(ctFont);
    _charH    = ceil(ascent + descent + leading) + 1.0;
    _baseline = descent;
}

- (NSSize)preferredSize {
    return NSMakeSize(_charW * _cols, _charH * (_rows + kOIARows));
}

- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd {
    _screen = screen;
    _kbd    = kbd;
    if (screen) {
        _rows = screen->rows();
        _cols = screen->cols();
    }
}

- (void)screenDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
}

- (void)blinkCursor:(NSTimer*)timer {
    _cursorVisible = !_cursorVisible;
    [self setNeedsDisplay:YES];
}

// ── Drawing ───────────────────────────────────────────────────────────────────
- (void)drawRect:(NSRect)dirtyRect {
    [_backgroundColor setFill];
    NSRectFill(self.bounds);

    if (!_screen) {
        return;
    }

    // Draw each cell
    for (int row = 0; row < _rows; ++row) {
        for (int col = 0; col < _cols; ++col) {
            int pos = row * _cols + col;
            const x3270::Cell& cell = _screen->at(pos);

            // Attribute positions are rendered as blanks (background colour only)
            if (cell.isFA) continue;

            // Skip non-display (password) fields — draw nothing
            if (cell.isNonDisplay()) continue;

            // ── Foreground colour ─────────────────────────────────────────────
            // Priority: per-cell SA extended colour > FA-attribute default colour
            NSColor *fg;
            if (cell.fgColor != 0x00) {
                fg = colorFor3270Code(cell.fgColor) ?: _foregroundColor;
            } else {
                // DEFCOLOR_MAP: index 0-3 from protected (bit5) + intensified (bit3)
                // 0=unprotected-normal, 1=unprotected-intensified,
                // 2=protected-normal,   3=protected-intensified
                int colorIdx = ((cell.attr & 0x20) >> 4) | ((cell.attr & 0x08) >> 3);
                switch (colorIdx) {
                case 1:  fg = _intensifiedColor; break;  // red
                case 2:  fg = [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0]; break; // blue
                case 3:  fg = [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]; break; // white
                default: fg = _foregroundColor; break;   // green
                }
            }

            // ── Background colour ─────────────────────────────────────────────
            NSColor *bg = (cell.bgColor != 0x00)
                ? (colorFor3270Code(cell.bgColor) ?: _backgroundColor)
                : _backgroundColor;

            // ── Reverse-video highlight (0xF2) ────────────────────────────────
            if (cell.highlight == 0xF2) {
                NSColor *tmp = fg; fg = bg; bg = tmp;
            }

            // Cell rect (Y=0 is bottom in Cocoa)
            CGFloat cx = col * _charW;
            CGFloat cy = self.bounds.size.height - (row + 1) * _charH;

            // Fill cell background when it differs from the global background
            if (bg != _backgroundColor) {
                [bg setFill];
                NSRectFill(NSMakeRect(cx, cy, _charW, _charH));
            }

            // Draw character
            uint16_t unicode = _codec.toUnicode(cell.ch);
            if (unicode >= 0x20) {
                NSString *ch = [NSString stringWithFormat:@"%C", (unichar)unicode];
                NSDictionary *charAttrs = @{
                    NSFontAttributeName:            _terminalFont,
                    NSForegroundColorAttributeName: fg,
                };
                [ch drawAtPoint:NSMakePoint(cx, cy + _baseline) withAttributes:charAttrs];
            }

            // ── Underscore highlight (0xF4) ───────────────────────────────────
            if (cell.highlight == 0xF4) {
                [fg setStroke];
                NSBezierPath *line = [NSBezierPath bezierPath];
                [line setLineWidth:1.0];
                [line moveToPoint:NSMakePoint(cx,          cy + 1.0)];
                [line lineToPoint:NSMakePoint(cx + _charW, cy + 1.0)];
                [line stroke];
            }
        }
    }

    // Draw block cursor (always visible during blink-on phase, regardless of lock state)
    if (_cursorVisible && _screen) {
        int curPos = _screen->cursorPos();
        int curRow = curPos / _cols;
        int curCol = curPos % _cols;
        const x3270::Cell& curCell = _screen->at(curPos);
        CGFloat cx = curCol * _charW;
        CGFloat cy = self.bounds.size.height - (curRow + 1) * _charH;

        // Block cursor: fill cell with cursor colour, then re-draw character inverted
        [_cursorColor setFill];
        NSRectFill(NSMakeRect(cx, cy, _charW, _charH));

        if (!curCell.isFA && !curCell.isNonDisplay()) {
            uint16_t cunicode = _codec.toUnicode(curCell.ch);
            if (cunicode >= 0x20) {
                NSString *cch = [NSString stringWithFormat:@"%C", (unichar)cunicode];
                NSDictionary *cAttrs = @{
                    NSFontAttributeName:            _terminalFont,
                    NSForegroundColorAttributeName: _backgroundColor,
                };
                [cch drawAtPoint:NSMakePoint(cx, cy + _baseline) withAttributes:cAttrs];
            }
        }
    }

    // Draw OIA (status bar)
    [self drawOIA];
}

- (void)drawOIA {
    CGFloat oiaY = self.bounds.size.height - (_rows + 1) * _charH;
    // Separator line
    [[NSColor colorWithWhite:0.4 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, oiaY + _charH - 1, self.bounds.size.width, 1.0));

    NSColor *oiaColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    NSDictionary *attrs = @{
        NSFontAttributeName:            _terminalFont,
        NSForegroundColorAttributeName: oiaColor,
    };

    NSString *statusStr = @"";
    if (_kbd) {
        switch (_kbd->lockReason()) {
        case x3270::KeyboardState::LockReason::None:
            statusStr = @"";
            break;
        case x3270::KeyboardState::LockReason::Connecting:
            statusStr = @"Connecting...";
            break;
        case x3270::KeyboardState::LockReason::System:
            statusStr = @"X SYS";
            break;
        case x3270::KeyboardState::LockReason::OErr:
            statusStr = @"X OERR";
            break;
        }
        if (_kbd->isInsertMode()) {
            statusStr = [statusStr stringByAppendingString:@" INS"];
        }
    }

    // Cursor position (1-based)
    NSString *cursorInfo = @"";
    if (_screen) {
        int pos = _screen->cursorPos();
        cursorInfo = [NSString stringWithFormat:@"%03d/%03d",
                      pos / _cols + 1, pos % _cols + 1];
    }

    CGFloat oiaTextY = oiaY + _baseline;
    [statusStr drawAtPoint:NSMakePoint(4, oiaTextY) withAttributes:attrs];
    [cursorInfo drawAtPoint:NSMakePoint(self.bounds.size.width - 80, oiaTextY) withAttributes:attrs];

    // Version string drawn dimly in the lower OIA row (does not overlap status)
    static NSString *versionStr = nil;
    static dispatch_once_t vOnce;
    dispatch_once(&vOnce, ^{
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *v = info[@"CFBundleShortVersionString"] ?: @"1.5.0";
        NSString *b = info[@"CFBundleVersion"] ?: @"1";
        versionStr = [NSString stringWithFormat:@"DX3270 v%@ build %@  \u2014  \u00a9 2026 Swen Skalski", v, b];
    });
    NSColor *dimColor = [NSColor colorWithWhite:0.3 alpha:1.0];
    NSDictionary *dimAttrs = @{
        NSFontAttributeName:            _terminalFont,
        NSForegroundColorAttributeName: dimColor,
    };
    NSSize vSize = [versionStr sizeWithAttributes:dimAttrs];
    CGFloat vX = floor((self.bounds.size.width - vSize.width) / 2.0);
    [versionStr drawAtPoint:NSMakePoint(vX, _baseline) withAttributes:dimAttrs];
}

// ── Key handling ──────────────────────────────────────────────────────────────
- (BOOL)acceptsFirstResponder { return YES; }

// macOS sometimes routes function-key events through performKeyEquivalent:
// instead of keyDown: (e.g. when the key overlaps with a menu key-equivalent
// lookup, or on certain keyboard layouts).  Mirror the PF-key logic here so
// those events are not silently dropped.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!_kbd) return NO;

    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    // Let Cmd+Fkey pass through so app-level shortcuts (⌘Q, ⌘N …) still work.
    if (modifiers & NSEventModifierFlagCommand) return [super performKeyEquivalent:event];

    unichar key = [event.charactersIgnoringModifiers length] > 0
                  ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    BOOL shiftDown = (modifiers & NSEventModifierFlagShift) != 0;

    if (key >= NSF1FunctionKey && key <= NSF12FunctionKey) {
        int pfNum = (int)(key - NSF1FunctionKey + 1);
        if (shiftDown) pfNum += 12;   // Shift+F1-F12 → PF13-24
        BOOL handled = _kbd->handlePF(pfNum);
        if (handled) [self setNeedsDisplay:YES];
        else if (_kbd->lockReason() == x3270::KeyboardState::LockReason::OErr) NSBeep();
        return YES;  // consume the event regardless so macOS takes no further action
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    if (!_kbd) { [super keyDown:event]; return; }

    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL altDown   = (modifiers & NSEventModifierFlagOption)  != 0;
    BOOL shiftDown = (modifiers & NSEventModifierFlagShift)   != 0;

    unichar key = [event.charactersIgnoringModifiers length] > 0
                  ? [event.charactersIgnoringModifiers characterAtIndex:0]
                  : 0;

    BOOL handled = NO;

    // PF keys: F1-F12 (PF1-12), Shift+F1-F12 (PF13-24)
    if (key >= NSF1FunctionKey && key <= NSF12FunctionKey) {
        int pfNum = (int)(key - NSF1FunctionKey + 1);
        if (shiftDown) pfNum += 12;
        handled = _kbd->handlePF(pfNum);
    }
    // PA keys: Alt+1, Alt+2, Alt+3
    else if (altDown && key >= '1' && key <= '3') {
        handled = _kbd->handlePA((int)(key - '0'));
    }
    // Reset: Escape
    else if (key == 27 && !altDown) {
        handled = _kbd->handleReset();
    }
    // Clear: Alt+Escape or Escape with Option
    else if (key == 27 && altDown) {
        handled = _kbd->handleClear();
    }
    // Enter
    else if (key == '\r' || key == '\n') {
        if (shiftDown) handled = _kbd->handleNewLine();
        else           handled = _kbd->handleEnter();
    }
    // Tab / BackTab
    else if (key == '\t') {
        handled = _kbd->handleTab(shiftDown);
    }
    // Backspace
    else if (key == NSBackspaceCharacter || key == NSDeleteCharacter) {
        handled = _kbd->handleBackspace();
    }
    // Delete (forward delete)
    else if (key == NSDeleteFunctionKey) {
        handled = _kbd->handleDelete();
    }
    // Home
    else if (key == NSHomeFunctionKey) {
        handled = _kbd->handleHome();
    }
    // Arrow keys
    else if (key == NSUpArrowFunctionKey)    { handled = _kbd->handleCursorUp(); }
    else if (key == NSDownArrowFunctionKey)  { handled = _kbd->handleCursorDown(); }
    else if (key == NSLeftArrowFunctionKey)  { handled = _kbd->handleCursorLeft(); }
    else if (key == NSRightArrowFunctionKey) { handled = _kbd->handleCursorRight(); }
    // Insert mode
    else if (key == NSInsertFunctionKey) {
        _kbd->toggleInsert();
        handled = YES;
    }
    // ErEOF: Alt+Delete
    else if (altDown && key == NSDeleteFunctionKey) {
        handled = _kbd->handleEraseEOF();
    }
    // ErInput: Alt+E
    else if (altDown && (key == 'e' || key == 'E')) {
        handled = _kbd->handleEraseInput();
    }
    // Printable ASCII
    else if (!altDown) {
        NSString *chars = event.characters;
        if (chars.length > 0) {
            unichar c = [chars characterAtIndex:0];
            if (c >= 0x20 && c < 0x80) {
                handled = _kbd->handleChar(static_cast<uint8_t>(c));
            }
        }
    }

    if (handled) {
        [self setNeedsDisplay:YES];
    } else if (!handled) {
        // Play system beep on OErr
        if (_kbd && _kbd->lockReason() == x3270::KeyboardState::LockReason::OErr) {
            NSBeep();
        }
    }
}

@end
