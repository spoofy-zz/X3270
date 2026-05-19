#import "TerminalWindowController.h"
#import "TerminalView.h"
#import "DebugWindowController.h"
#include "TN3270Session.h"
#include "DataStreamParser.h"
#include "KeyboardState.h"
#include "ScreenBuffer.h"
#include "EbcdicCodec.h"
#include <memory>
#include <thread>
#include <string>

@implementation TerminalWindowController {
    TerminalView*   _termView;
    DebugWindowController *_debugWC;

    // Core engine objects (heap-allocated because they have no default ctor)
    std::unique_ptr<x3270::ScreenBuffer>   _screen;
    std::unique_ptr<x3270::EbcdicCodec>    _codec;
    std::unique_ptr<x3270::DataStreamParser> _parser;
    std::unique_ptr<x3270::KeyboardState>  _kbd;
    std::unique_ptr<x3270::TN3270Session>  _session;

    std::thread _networkThread;

    NSString  *_host;
    uint16_t   _port;
    BOOL       _useSSL;
    NSString  *_caBundle;
    x3270::CodePage _codePage;
}

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                    caBundle:(NSString*)caBundle
                   codePage:(x3270::CodePage)codePage {
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 640, 420)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                                        |NSWindowStyleMaskResizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = [NSString stringWithFormat:@"%@:%d — X3270", host, port];
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        _host     = [host copy];
        _port     = port;
        _useSSL   = useSSL;
        _caBundle = [caBundle copy];
        _codePage = codePage;

        [self buildEngineObjects];
        [self buildUI];
        [self startNetworkConnection];
    }
    return self;
}

- (void)dealloc {
    if (_session) _session->disconnect();
    if (_networkThread.joinable()) _networkThread.detach();
    // ARC handles object release
}

// ── Engine ────────────────────────────────────────────────────────────────────
- (void)buildEngineObjects {
    _screen  = std::make_unique<x3270::ScreenBuffer>();
    _codec   = std::make_unique<x3270::EbcdicCodec>(_codePage);
    _parser  = std::make_unique<x3270::DataStreamParser>(*_screen, *_codec);
    _kbd     = std::make_unique<x3270::KeyboardState>(*_screen, *_codec);
    _session = std::make_unique<x3270::TN3270Session>();

    __weak TerminalWindowController *weakSelf = self;

    // Parser → unlock keyboard on WCC unlock bit
    _parser->setUnlockCallback([weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) s->_kbd->unlock();
        });
    });

    // Parser → alarm
    _parser->setAlarmCallback([]() {
        dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
    });

    // Parser → send (used for Read Modified responses)
    _parser->setSendCallback([weakSelf](const std::vector<uint8_t>& data) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) s->_session->send3270Record(data);
    });

    // Keyboard → send AID records to session (returns false if not yet connected)
    _kbd->setSendCallback([weakSelf](const std::vector<uint8_t>& record) -> bool {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) return s->_session->send3270Record(record);
        return false;
    });

    // Session → data received
    _session->setDataCallback([weakSelf](const std::vector<uint8_t>& record) {
        // Called from network thread — parse and notify UI
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;

        // TN3270E mode: strip the 5-byte header [data-type, request, response, seq_hi, seq_lo]
        // Only do this when TN3270E was actually negotiated, not for classic TN3270.
        const std::vector<uint8_t>* payload = &record;
        std::vector<uint8_t> stripped;
        if (s->_session->tn3270eActive() && record.size() >= 5) {
            // Ignore non-3270-data records (BIND_IMAGE, UNBIND, RESPONSE, etc.)
            if (record[0] != 0x00) { return; }  // not DT_3270_DATA
            stripped.assign(record.begin() + 5, record.end());
            payload = &stripped;
        }

        s->_parser->processRecord(*payload);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (s2) [s2->_termView screenDidUpdate];
        });
    });

    // Session → connected
    _session->setConnectedCallback([weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                s->_kbd->unlock();
                if (s.onConnected) s.onConnected();
            }
        });
    });

    // Session → error
    _session->setErrorCallback([weakSelf](const std::string& msg) {
        NSString *nsMsg = [NSString stringWithUTF8String:msg.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                if (s.onConnectError) s.onConnectError(nsMsg);
                [s close];
            }
        });
    });

    // Session → raw traffic (called from any thread)
    _debugWC = [[DebugWindowController alloc] init];
    _session->setTrafficCallback([weakSelf](bool tx, const std::vector<uint8_t>& data) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) {
            [s->_debugWC appendBytes:data.data()
                              length:data.size()
                          isOutgoing:tx ? YES : NO];
        }
    });
}

// ── UI ────────────────────────────────────────────────────────────────────────
- (void)buildUI {
    _termView = [[TerminalView alloc] initWithFrame:self.window.contentView.bounds];
    _termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_termView setScreenBuffer:_screen.get() keyboardState:_kbd.get()];

    [self.window.contentView addSubview:_termView];
    [self.window makeFirstResponder:_termView];

    // Resize window to fit preferred terminal size
    NSSize preferred = [_termView preferredSize];
    NSRect frame = self.window.frame;
    NSRect contentFrame = [self.window contentRectForFrameRect:frame];
    CGFloat widthDiff  = frame.size.width  - contentFrame.size.width;
    CGFloat heightDiff = frame.size.height - contentFrame.size.height;
    [self.window setContentSize:preferred];
    (void)widthDiff; (void)heightDiff;
}

// ── Networking ────────────────────────────────────────────────────────────────
- (void)startNetworkConnection {
    std::string host      = [_host UTF8String];
    uint16_t    port      = _port;
    bool        useSSL    = _useSSL == YES;
    std::string caBundle  = _caBundle ? [_caBundle UTF8String] : "";

    _networkThread = std::thread([self, host, port, useSSL, caBundle]() {
        bool ok = _session->connect(host, port, useSSL, caBundle);
        if (ok) {
            _session->readLoop(); // blocks until disconnected
        }
    });
    _networkThread.detach();
}

- (void)windowWillClose:(NSNotification*)notification {
    if (_session) _session->disconnect();
}

/// Open the traffic monitor panel (⌘⇧D).
- (IBAction)openDebugWindow:(id)sender {
    [_debugWC showWindow:nil];
    [_debugWC.window makeKeyAndOrderFront:nil];
}

@end
