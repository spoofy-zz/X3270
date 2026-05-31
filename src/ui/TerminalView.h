#pragma once
#import <AppKit/AppKit.h>
#include "ScreenBuffer.h"
#include "KeyboardState.h"
#include "GraphicsBuffer.h"

/// NSUserDefaults key – BOOL; YES = use bundled IBM 3270 font (by Ricardo Bánffy)
extern NSString * const kPref3270FontEnabled;
/// NSUserDefaults key – double; terminal font size in points.
extern NSString * const kPrefTerminalFontSize;

/// TerminalView renders the 3270 screen buffer as a character grid using
/// Core Text.  It also handles all keyboard input and forwards it to
/// a KeyboardState instance provided by the owning window controller.
@interface TerminalView : NSView

/// Wire up the model objects from TerminalWindowController.
- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd;

/// Wire up the GOCA graphics buffer (call after setScreenBuffer:).
- (void)setGraphicsBuffer:(x3270::GraphicsBuffer*)graphics;

/// Call this (on main thread) whenever the screen buffer has changed.
- (void)screenDidUpdate;

/// Call this (on main thread) whenever the graphics buffer has changed.
- (void)graphicsDidUpdate;

/// Preferred window content size for the attached screen buffer's model + OIA
- (NSSize)preferredSize;

/// Runtime font-size controls.
- (IBAction)increaseFontSize:(id)sender;
- (IBAction)decreaseFontSize:(id)sender;
- (IBAction)resetFontSize:(id)sender;

/// Colour scheme
@property (nonatomic, strong) NSColor *foregroundColor;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *intensifiedColor;
@property (nonatomic, strong) NSColor *cursorColor;
@property (nonatomic, strong) NSFont  *terminalFont;

@end
