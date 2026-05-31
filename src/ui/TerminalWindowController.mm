#import "TerminalWindowController.h"
#import "TerminalView.h"
#import "DebugWindowController.h"
#include "TN3270Session.h"
#include "DataStreamParser.h"
#include "KeyboardState.h"
#include "ScreenBuffer.h"
#include "GraphicsBuffer.h"
#include "FileTransfer.h"
#include "EbcdicCodec.h"
#include <memory>
#include <thread>
#include <string>

@implementation TerminalWindowController {
    TerminalView*   _termView;
    DebugWindowController *_debugWC;

    // Core engine objects (heap-allocated because they have no default ctor)
    std::unique_ptr<x3270::ScreenBuffer>      _screen;
    std::unique_ptr<x3270::GraphicsBuffer>    _graphics;
    std::unique_ptr<x3270::EbcdicCodec>       _codec;
    std::unique_ptr<x3270::DataStreamParser>  _parser;
    std::unique_ptr<x3270::KeyboardState>     _kbd;
    std::unique_ptr<x3270::TN3270Session>     _session;
    std::unique_ptr<x3270::FileTransfer>      _fileTransfer;

    std::thread _networkThread;

    NSString  *_host;
    uint16_t   _port;
    BOOL       _useSSL;
    NSString  *_caBundle;
    x3270::CodePage     _codePage;
    x3270::TerminalModel _model;
}

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                    caBundle:(NSString*)caBundle
                   codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model {
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 640, 420)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                                        |NSWindowStyleMaskResizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = [NSString stringWithFormat:@"%@:%d — DX3270", host, port];
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        _host     = [host copy];
        _port     = port;
        _useSSL   = useSSL;
        _caBundle = [caBundle copy];
        _codePage = codePage;
        _model    = model;

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
    _screen   = std::make_unique<x3270::ScreenBuffer>(_model);
    _graphics = std::make_unique<x3270::GraphicsBuffer>();
    _codec    = std::make_unique<x3270::EbcdicCodec>(_codePage);
    _parser   = std::make_unique<x3270::DataStreamParser>(*_screen, *_codec);
    _parser->setGraphicsBuffer(*_graphics);
    _kbd      = std::make_unique<x3270::KeyboardState>(*_screen, *_codec);
    _session  = std::make_unique<x3270::TN3270Session>();
    _fileTransfer = std::make_unique<x3270::FileTransfer>();
    _session->setModel(_model);

    __weak TerminalWindowController *weakSelf = self;

    // Graphics update callback: fired by DataStreamParser after a GOCA WSF batch.
    _parser->setGraphicsUpdateCallback([weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) [s->_termView graphicsDidUpdate];
        });
    });

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

    // Parser -> IND$FILE DFT structured fields.
    _parser->setStructuredFieldCallback([weakSelf](const uint8_t* data, size_t length) -> bool {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_fileTransfer) return false;
        return s->_fileTransfer->processStructuredField(data, length);
    });

    _fileTransfer->setSendCallback([weakSelf](const std::vector<uint8_t>& record) -> bool {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_session) return false;
        return s->_session->send3270Record(record);
    });
    _fileTransfer->setCompleteCallback([weakSelf](bool ok, const std::string& message) {
        NSString *text = [NSString stringWithUTF8String:message.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = ok ? @"File Transfer Complete" : @"File Transfer Failed";
            alert.informativeText = text ?: @"";
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:s.window completionHandler:nil];
        });
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
    [_termView setGraphicsBuffer:_graphics.get()];

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

// ── Screenshot ────────────────────────────────────────────────────────────────

/// Save a PNG screenshot of the terminal view to a user-chosen file (⌘⇧P).
- (IBAction)saveScreenshot:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"png"];
    panel.nameFieldStringValue = @"DX3270_screenshot.png";
    panel.message = @"Save a PNG image of the current terminal screen.";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSRect bounds = self->_termView.bounds;
        NSBitmapImageRep *bitmap =
            [self->_termView bitmapImageRepForCachingDisplayInRect:bounds];
        if (!bitmap) return;
        [self->_termView cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
        NSData *pngData = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                               properties:@{}];
        [pngData writeToURL:panel.URL atomically:YES];
    }];
}

// ── Text export ───────────────────────────────────────────────────────────────

/// Export the current terminal screen as UTF-8 plain text (⌘⇧T).
/// Each row is written as a fixed-width line; columns are preserved by position.
- (IBAction)exportText:(id)sender {
    if (!_screen || !_codec) return;

    int rows = _screen->rows();
    int cols = _screen->cols();
    NSMutableString *text = [NSMutableString stringWithCapacity:(cols + 1) * rows];

    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            const x3270::Cell &cell = _screen->at(r, c);
            // Field-attribute cells and NUL/space bytes → space character
            if (cell.isFA || cell.ch == 0x00 ||
                cell.ch == x3270::EbcdicCodec::EBCDIC_SPACE) {
                [text appendString:@" "];
                continue;
            }
            uint16_t uc = _codec->toUnicode(cell.ch);
            if (uc >= 0x20) {
                unichar ch = (unichar)uc;
                [text appendString:[NSString stringWithCharacters:&ch length:1]];
            } else {
                [text appendString:@" "];
            }
        }
        if (r < rows - 1) [text appendString:@"\n"];
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"txt"];
    panel.nameFieldStringValue = @"DX3270_export.txt";
    panel.message = @"Export the current terminal screen as plain text.";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *err = nil;
        [text writeToURL:panel.URL
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&err];
    }];
}

// ── Host-side IND$FILE command helpers ───────────────────────────────────────

- (NSString *)escapedIndFileName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length >= 2 &&
        [trimmed hasPrefix:@"'"] &&
        [trimmed hasSuffix:@"'"]) {
        return trimmed;
    }
    return [NSString stringWithFormat:@"'%@'",
            [trimmed stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

- (void)showTransferError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"File Transfer";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (BOOL)enterHostCommand:(NSString *)command submit:(BOOL)submit {
    if (!_kbd || !_screen) return NO;
    if (_kbd->isLocked()) {
        [self showTransferError:@"The terminal keyboard is locked. Wait for the host to unlock the session, then try again."];
        return NO;
    }

    if (!_kbd->handleEraseEOF()) {
        [self showTransferError:@"Place the cursor in the TSO command input field, then start IND$FILE Download again."];
        return NO;
    }
    NSData *ascii = [command dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
    const uint8_t *bytes = static_cast<const uint8_t *>(ascii.bytes);
    for (NSUInteger i = 0; i < ascii.length; ++i) {
        if (bytes[i] < 0x20 || bytes[i] >= 0x7F) continue;
        if (!_kbd->handleChar(bytes[i])) {
            [_termView screenDidUpdate];
            [self showTransferError:@"The IND$FILE command did not fit in the current input field or the field is protected."];
            return NO;
        }
    }
    [_termView screenDidUpdate];
    if (submit) {
        _kbd->handleEnter();
    }
    return YES;
}

- (void)promptForHostFileWithTitle:(NSString *)title
                      defaultValue:(NSString *)defaultValue
                         completed:(void (^)(NSString *hostFile, BOOL binaryMode, BOOL submit))completed {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = @"Enter the TSO/CMS host file name. DX3270 will place the IND$FILE command in the active input field.";
    [alert addButtonWithTitle:@"Insert Command"];
    [alert addButtonWithTitle:@"Insert and Submit"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 56)];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 28, 360, 24)];
    field.stringValue = defaultValue ?: @"";
    [accessory addSubview:field];
    NSButton *binary = [NSButton checkboxWithTitle:@"Binary transfer" target:nil action:nil];
    binary.frame = NSMakeRect(0, 0, 180, 22);
    binary.state = NSControlStateValueOff;
    [accessory addSubview:binary];
    alert.accessoryView = accessory;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertThirdButtonReturn) return;
        NSString *hostFile = [field.stringValue stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hostFile.length == 0) return;
        BOOL submit = (result == NSAlertSecondButtonReturn);
        BOOL binaryMode = (binary.state == NSControlStateValueOn);
        completed(hostFile, binaryMode, submit);
    }];
}

- (void)promptForDownloadHostFileWithDefault:(NSString *)defaultValue
                                   completed:(void (^)(NSString *hostFile, BOOL binaryMode))completed {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Download with IND$FILE";
    alert.informativeText = @"Enter the TSO/CMS host file or data set name. DX3270 will start IND$FILE GET and save the received data to the selected local file.";
    [alert addButtonWithTitle:@"Start Download"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 56)];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 28, 360, 24)];
    field.stringValue = defaultValue ?: @"";
    [accessory addSubview:field];
    NSButton *binary = [NSButton checkboxWithTitle:@"Binary transfer" target:nil action:nil];
    binary.frame = NSMakeRect(0, 0, 180, 22);
    binary.state = NSControlStateValueOff;
    [accessory addSubview:binary];
    alert.accessoryView = accessory;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertFirstButtonReturn) return;
        NSString *hostFile = [field.stringValue stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hostFile.length == 0) return;
        completed(hostFile, binary.state == NSControlStateValueOn);
    }];
}

- (IBAction)uploadFile:(id)sender {
    [self showTransferError:@"Upload is not implemented yet. Download via IND$FILE GET is implemented first because it requires receiving and acknowledging host DFT data in the active session."];
}

- (IBAction)downloadFile:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.message = @"Choose where DX3270 should save the downloaded host file.";
    panel.nameFieldStringValue = @"host-file.txt";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSString *defaultHostName = panel.URL.lastPathComponent.stringByDeletingPathExtension.uppercaseString;
        [self promptForDownloadHostFileWithDefault:defaultHostName
                                         completed:^(NSString *hostFile, BOOL binaryMode) {
            std::string error;
            bool asciiMode = !binaryMode;
            if (!self->_fileTransfer->beginDownload(panel.URL.path.UTF8String, asciiMode, error)) {
                NSString *msg = [NSString stringWithUTF8String:error.c_str()];
                [self showTransferError:msg ?: @"Cannot open local file."];
                return;
            }

            NSString *mode = binaryMode ? @"BINARY" : @"ASCII CRLF";
            NSString *command = [NSString stringWithFormat:@"IND$FILE GET %@ %@",
                                 [self escapedIndFileName:hostFile], mode];
            [self enterHostCommand:command submit:YES];
        }];
    }];
}

// ── Menu validation ───────────────────────────────────────────────────────────

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(saveScreenshot:) ||
        action == @selector(exportText:) ||
        action == @selector(uploadFile:) ||
        action == @selector(downloadFile:)) {
        return _session != nullptr;
    }
    return YES;
}

@end
