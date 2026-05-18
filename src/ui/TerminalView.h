#pragma once
#import <AppKit/AppKit.h>
#include "ScreenBuffer.h"
#include "KeyboardState.h"

/// TerminalView renders the 3270 screen buffer as a character grid using
/// Core Text.  It also handles all keyboard input and forwards it to
/// a KeyboardState instance provided by the owning window controller.
@interface TerminalView : NSView

/// Wire up the model objects from TerminalWindowController.
- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd;

/// Call this (on main thread) whenever the screen buffer has changed.
- (void)screenDidUpdate;

/// Preferred window content size for a 24x80 + OIA terminal
- (NSSize)preferredSize;

/// Colour scheme
@property (nonatomic, strong) NSColor *foregroundColor;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *intensifiedColor;
@property (nonatomic, strong) NSColor *cursorColor;
@property (nonatomic, strong) NSFont  *terminalFont;

@end
