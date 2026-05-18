#import "PreferencesWindowController.h"

@implementation PreferencesWindowController

+ (instancetype)sharedController {
    static PreferencesWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSWindow *win = [[NSWindow alloc]
                         initWithContentRect:NSMakeRect(0, 0, 380, 240)
                                   styleMask:NSWindowStyleMaskTitled
                                            |NSWindowStyleMaskClosable
                                   backing:NSBackingStoreBuffered
                                      defer:NO];
        win.title = @"X3270 — Preferences";
        win.releasedWhenClosed = NO;
        [win center];
        shared = [[PreferencesWindowController alloc] initWithWindow:win];
        [shared buildUI];
    });
    return shared;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20, y = 180;

    // Placeholder label
    NSTextField *lbl = [NSTextField wrappingLabelWithString:
        @"Preferences coming in Phase 2:\n"
         "• Font family and size\n"
         "• Colour scheme (green / amber / white-on-black)\n"
         "• Keyboard mapping\n"
         "• Default code page\n"
         "• Auto-reconnect"];
    lbl.frame = NSMakeRect(margin, y - 160, cv.bounds.size.width - margin * 2, 160);
    [cv addSubview:lbl];
}

@end
