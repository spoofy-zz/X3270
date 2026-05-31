#pragma once
#import <AppKit/AppKit.h>
#include "EbcdicCodec.h"
#include "TerminalModel.h"
#include <string>

/// Owns the TN3270 session and wires the core engine to the TerminalView.
@interface TerminalWindowController : NSWindowController

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                    caBundle:(NSString*)caBundle
                   codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model;

/// Callbacks for ConnectionWindowController to observe results
@property (nonatomic, copy) void(^onConnected)(void);
@property (nonatomic, copy) void(^onConnectError)(NSString*);

/// Save a PNG screenshot of the terminal window to disk.
- (IBAction)saveScreenshot:(id)sender;

/// Export the current screen content as a UTF-8 plain-text file.
- (IBAction)exportText:(id)sender;

/// Fill the current input field with a host-side IND$FILE upload command.
- (IBAction)uploadFile:(id)sender;

/// Fill the current input field with a host-side IND$FILE download command.
- (IBAction)downloadFile:(id)sender;

@end
