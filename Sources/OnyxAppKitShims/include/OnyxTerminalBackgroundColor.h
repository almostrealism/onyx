#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The terminal's default background: fully transparent where it is
/// painted, so the window's vibrancy shows through, but OPAQUE when
/// SwiftTerm inverts it for reverse video.
///
/// SwiftTerm draws SGR 7 (reverse video) on default colors by inverting
/// `nativeBackgroundColor`, and its inversion keeps the alpha. With a plain
/// alpha-0 background the reversed cell's background stayed invisible while
/// its text became the inverse of our light foreground: dark gray on
/// nothing. zsh (`zle_highlight` paste=standout) and bash 5.1+ (active
/// region) both highlight PASTED text with reverse video, so every paste
/// was unreadable.
///
/// The inversion (and every other color computation in SwiftTerm) reads the
/// color through `-colorUsingColorSpace:`, while painting goes through
/// `-setFill` / `CGColor`. So this color answers the first with its opaque
/// twin and everything else as the transparent original.
///
/// Objective-C because Swift can't subclass NSColor: its color-literal
/// initializer is required, and declared in an extension, so no Swift
/// subclass can provide it.
@interface OnyxTerminalBackgroundColor : NSColor

- (instancetype)initWithWhite:(CGFloat)white NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
