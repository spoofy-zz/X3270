#pragma once
#import <AppKit/AppKit.h>

/// Shows a connection sheet: host, port, SSL toggle, code page.
/// On connect, opens a TerminalWindowController.
@interface ConnectionWindowController : NSWindowController

@end
