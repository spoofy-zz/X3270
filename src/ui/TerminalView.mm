#import "TerminalView.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "EbcdicCodec.h"
#include <string>

static const int kRows = x3270::ScreenBuffer::ROWS;
static const int kCols = x3270::ScreenBuffer::COLS;
// OIA (Operator Information Area) extra rows below the 3270 screen
static const int kOIARows = 2;

@implementation TerminalView {
    x3270::ScreenBuffer*  _screen;
    x3270::KeyboardState* _kbd;
    x3270::EbcdicCodec    _codec;

    NSTimer* _cursorTimer;
    BOOL     _cursorVisible;

    CGFloat  _charW;   // character cell width
    CGFloat  _charH;   // character cell height (ascent + descent + leading)
    CGFloat  _baseline; // distance from cell bottom to text baseline
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _codec = x3270::EbcdicCodec(x3270::CodePage::CP037);
        _cursorVisible = YES;

        // Default green-screen palette
        _foregroundColor  = [NSColor colorWithRed:0.0 green:0.85 blue:0.0 alpha:1.0];
        _backgroundColor  = [NSColor colorWithRed:0.0 green:0.0  blue:0.0 alpha:1.0];
        _intensifiedColor = [NSColor colorWithRed:1.0 green:1.0  blue:1.0 alpha:1.0];
        _cursorColor      = [NSColor colorWithRed:0.0 green:0.85 blue:0.0 alpha:1.0];
        _terminalFont     = [NSFont fontWithName:@"Menlo" size:14.0]
                         ?: [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightRegular];

        [self recalcCellSize];

        _cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                        target:self
                                                      selector:@selector(blinkCursor:)
                                                      userInfo:nil
                                                       repeats:YES];
    }
    return self;
}

- (void)dealloc {
    [_cursorTimer invalidate];
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
    return NSMakeSize(_charW * kCols, _charH * (kRows + kOIARows));
}

- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd {
    _screen = screen;
    _kbd    = kbd;
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
    for (int row = 0; row < kRows; ++row) {
        for (int col = 0; col < kCols; ++col) {
            int pos = row * kCols + col;
            const x3270::Cell& cell = _screen->at(pos);

            // Attribute positions are displayed as blanks
            if (cell.isFA) continue;

            // Skip non-display fields (password fields)
            if (cell.isNonDisplay()) continue;

            // Determine colour
            NSColor *fg = cell.isIntensified() ? _intensifiedColor : _foregroundColor;

            // Convert EBCDIC to displayable character
            uint16_t unicode = _codec.toUnicode(cell.ch);
            if (unicode == 0 || unicode < 0x20) continue; // non-printable / null

            // Cell rect (Y=0 is bottom in Cocoa)
            CGFloat x = col * _charW;
            CGFloat y = self.bounds.size.height - (row + 1) * _charH;

            NSString *ch = [NSString stringWithFormat:@"%C", (unichar)unicode];
            NSDictionary *attrs = @{
                NSFontAttributeName:            _terminalFont,
                NSForegroundColorAttributeName: fg,
            };
            [ch drawAtPoint:NSMakePoint(x, y + _baseline) withAttributes:attrs];
        }
    }

    // Draw cursor
    if (_cursorVisible && _kbd && !_kbd->isLocked()) {
        int curPos = _screen->cursorPos();
        int curRow = curPos / kCols;
        int curCol = curPos % kCols;
        CGFloat cx = curCol * _charW;
        CGFloat cy = self.bounds.size.height - (curRow + 1) * _charH;
        NSRect cursorRect = NSMakeRect(cx, cy, _charW, _charH);
        [_cursorColor setFill];
        [NSBezierPath fillRect:NSMakeRect(cursorRect.origin.x,
                                          cursorRect.origin.y,
                                          cursorRect.size.width,
                                          2.0)]; // underline cursor
    }

    // Draw OIA (status bar)
    [self drawOIA];
}

- (void)drawOIA {
    CGFloat oiaY = self.bounds.size.height - (kRows + 1) * _charH;
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
                      pos / kCols + 1, pos % kCols + 1];
    }

    // Version string (read once from bundle)
    static NSString *versionStr = nil;
    static dispatch_once_t vOnce;
    dispatch_once(&vOnce, ^{
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *v = info[@"CFBundleShortVersionString"] ?: @"1.0.0";
        NSString *b = info[@"CFBundleVersion"] ?: @"1";
        versionStr = [NSString stringWithFormat:@"X3270 v%@ build %@  \u2014  \u00a9 2026 Swen Skalski", v, b];
    });

    CGFloat oiaTextY = oiaY + _baseline;
    [statusStr drawAtPoint:NSMakePoint(4, oiaTextY) withAttributes:attrs];
    // Version centered in OIA
    NSSize vSize = [versionStr sizeWithAttributes:attrs];
    CGFloat vX = floor((self.bounds.size.width - vSize.width) / 2.0);
    [versionStr drawAtPoint:NSMakePoint(vX, oiaTextY) withAttributes:attrs];
    [cursorInfo drawAtPoint:NSMakePoint(self.bounds.size.width - 80, oiaTextY) withAttributes:attrs];
}

// ── Key handling ──────────────────────────────────────────────────────────────
- (BOOL)acceptsFirstResponder { return YES; }

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
