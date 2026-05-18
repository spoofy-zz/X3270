#pragma once
#import <AppKit/AppKit.h>

@class ConnectionWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) ConnectionWindowController *connectionWindowController;

@end
