#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Read-only floating window listing every keyboard shortcut available in DX3270.
@interface ShortcutsWindowController : NSWindowController
+ (instancetype)sharedController;
@end

NS_ASSUME_NONNULL_END
