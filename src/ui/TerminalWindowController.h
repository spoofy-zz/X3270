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

@end
