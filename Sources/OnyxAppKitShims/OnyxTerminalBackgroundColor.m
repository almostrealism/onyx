#import "OnyxTerminalBackgroundColor.h"

@implementation OnyxTerminalBackgroundColor {
    NSColor *_clear;
    NSColor *_opaque;
}

- (instancetype)initWithWhite:(CGFloat)white {
    self = [super init];
    if (self) {
        _clear = [NSColor colorWithDeviceWhite:white alpha:0];
        _opaque = [NSColor colorWithDeviceWhite:white alpha:1];
    }
    return self;
}

// Computation: the opaque twin.

- (nullable NSColor *)colorUsingColorSpace:(NSColorSpace *)space {
    return [_opaque colorUsingColorSpace:space];
}

// Painting and inspection: the transparent original.

- (NSColorType)type { return _clear.type; }
- (NSColorSpace *)colorSpace { return _clear.colorSpace; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (NSColorSpaceName)colorSpaceName { return _clear.colorSpaceName; }
#pragma clang diagnostic pop
- (NSInteger)numberOfComponents { return _clear.numberOfComponents; }
- (void)getComponents:(CGFloat *)components { [_clear getComponents:components]; }
- (CGFloat)whiteComponent { return _clear.whiteComponent; }
- (CGFloat)alphaComponent { return _clear.alphaComponent; }
- (void)getWhite:(nullable CGFloat *)white alpha:(nullable CGFloat *)alpha { [_clear getWhite:white alpha:alpha]; }
- (CGColorRef)CGColor { return _clear.CGColor; }
- (void)set { [_clear set]; }
- (void)setFill { [_clear setFill]; }
- (void)setStroke { [_clear setStroke]; }
- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return [_clear colorWithAlphaComponent:alpha]; }

@end
