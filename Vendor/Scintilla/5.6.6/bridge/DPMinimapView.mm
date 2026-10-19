#import "DPMinimapView.h"
#import "ScintillaView.h"
#include <algorithm>
#include <array>

// Keep code at a fixed, legible scale. Long documents move underneath the
// viewport instead of dropping lines to squeeze the whole document into view.
static const CGFloat DPMinimapLineHeight = 4;
static const NSInteger DPMinimapCachePadding = 48;

@implementation DPMinimapView {
    NSImage *_image;
    NSSize _imageSize;
    BOOL _dirty, _scheduled, _dark, _highContrast, _dragging;
    CGFloat _mapTop, _dragStartY, _dragStartLine, _dragLinesPerPoint;
    NSInteger _imageFirstLine, _imageLineCount;
    NSRect _viewportRect;
    NSUInteger _sampledByteCount, _imageBuildCount;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _markerLines = [NSIndexSet indexSet];
        _dirty = YES;
        self.hidden = YES;
        self.accessibilityIdentifier = @"duckpad.editor.minimap";
        self.accessibilityRole = NSAccessibilityScrollAreaRole;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSRect)viewportRect { return _viewportRect; }
- (NSUInteger)sampledByteCount { return _sampledByteCount; }
- (NSUInteger)imageBuildCount { return _imageBuildCount; }
- (CGFloat)mapTop { return _mapTop; }
- (void)setNavigationLabel:(NSString *)label {
    _navigationLabel = [label copy];
    self.accessibilityLabel = label;
    self.toolTip = nil;
}
- (void)configureDark:(BOOL)dark highContrast:(BOOL)highContrast {
    _dark = dark; _highContrast = highContrast;
    [self invalidateContent];
}
- (void)setMarkerLines:(NSIndexSet *)lines {
    if ([_markerLines isEqualToIndexSet:lines]) return;
    _markerLines = [lines copy];
    self.needsDisplay = YES;
}
- (void)setFrameSize:(NSSize)size {
    const BOOL changed = !NSEqualSizes(size, self.frame.size);
    [super setFrameSize:size];
    if (changed) [self invalidateContent];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor]; }

- (void)invalidateContent {
    _dirty = YES;
    if (_scheduled || self.hidden || !self.scintilla) return;
    _scheduled = YES;
    __weak DPMinimapView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        DPMinimapView *owner = weakSelf;
        if (!owner) return;
        owner->_scheduled = NO;
        if (!owner.hidden && owner.scintilla && owner->_dirty) [owner rebuildImage];
    });
}

- (NSColor *)backgroundColor {
    // Match the editor surface, including user-selected palette changes.
    const sptr_t colour = [self.scintilla message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
    return [NSColor colorWithSRGBRed:(colour & 255) / 255.0 green:((colour >> 8) & 255) / 255.0
        blue:((colour >> 16) & 255) / 255.0 alpha:1];
}

// Cache only a bounded window of consecutive lines, plus overscan. Core Text
// draws actual glyphs (including Unicode); there is no full-document snapshot.
- (void)rebuildImage {
    ScintillaView *view = self.scintilla;
    if (!view || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    _dirty = NO;
    const NSInteger lineCount = MAX(1, [view message:SCI_GETLINECOUNT]);
    _imageFirstLine = MAX(0, (NSInteger)floor(_mapTop) - DPMinimapCachePadding);
    _imageLineCount = MIN(lineCount - _imageFirstLine,
        MIN(800, (NSInteger)ceil(self.bounds.size.height / DPMinimapLineHeight) + 2 * DPMinimapCachePadding));
    _imageSize = NSMakeSize(self.bounds.size.width, MAX(1, _imageLineCount * DPMinimapLineHeight));
    const NSInteger tabWidth = MAX(1, MIN(16, [view message:SCI_GETTABWIDTH]));
    NSFont *font = [NSFont monospacedSystemFontOfSize:3 weight:NSFontWeightRegular];
    NSMutableArray<NSDictionary *> *attributes = [NSMutableArray arrayWithCapacity:256];
    for (int style = 0; style < 256; style++) {
        const sptr_t colour = [view message:SCI_STYLEGETFORE wParam:style];
        NSColor *foreground = [NSColor colorWithSRGBRed:(colour & 255) / 255.0
            green:((colour >> 8) & 255) / 255.0 blue:((colour >> 16) & 255) / 255.0
            alpha:_highContrast ? 1 : 0.85];
        [attributes addObject:@{NSFontAttributeName:font, NSForegroundColorAttributeName:foreground}];
    }
    NSImage *image = [[NSImage alloc] initWithSize:_imageSize];
    [image lockFocusFlipped:YES];
    _sampledByteCount = 0;
    for (NSInteger row = 0; row < _imageLineCount; row++) {
        const NSInteger line = _imageFirstLine + row;
        const sptr_t start = [view message:SCI_POSITIONFROMLINE wParam:line];
        const sptr_t end = std::min(start + 256, [view message:SCI_GETLINEENDPOSITION wParam:line]);
        if (end <= start) continue;
        std::array<char, 514> styled{};
        Sci_TextRangeFull range{{start, end}, styled.data()};
        [view message:SCI_GETSTYLEDTEXTFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&range)];
        _sampledByteCount += end - start;
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
        NSInteger column = 0;
        // Decode UTF-8 by scalar so truncation never feeds an invalid suffix to
        // NSString. Tabs expand at real tab stops rather than one blank glyph.
        for (sptr_t index = 0; index < end - start;) {
            const unsigned char ch = styled[index * 2];
            const unsigned char style = styled[index * 2 + 1];
            const NSInteger count = ch < 0x80 ? 1 : ((ch & 0xE0) == 0xC0 ? 2 : ((ch & 0xF0) == 0xE0 ? 3 : 4));
            if (index + count > end - start) break;
            char bytes[4];
            for (NSInteger i = 0; i < count; i++) bytes[i] = styled[(index + i) * 2];
            NSString *value = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
            if (ch == '\t') {
                const NSInteger spaces = tabWidth - column % tabWidth;
                value = [@"" stringByPaddingToLength:spaces withString:@" " startingAtIndex:0];
                column += spaces;
            } else { column++; }
            if (value) [text appendAttributedString:[[NSAttributedString alloc] initWithString:value attributes:attributes[style]]];
            index += count;
            if (column >= 100) break;
        }
        [text drawAtPoint:NSMakePoint(6, row * DPMinimapLineHeight)];
    }
    [image unlockFocus];
    _image = image;
    _imageBuildCount++;
    self.needsDisplay = YES;
}

- (void)visibleStart:(CGFloat *)start span:(CGFloat *)span {
    ScintillaView *view = self.scintilla;
    const NSInteger lines = MAX(1, [view message:SCI_GETLINECOUNT]);
    const NSInteger first = [view message:SCI_GETFIRSTVISIBLELINE];
    const NSInteger screen = MAX(1, [view message:SCI_LINESONSCREEN]);
    *start = MAX(0, [view message:SCI_DOCLINEFROMVISIBLE wParam:first]);
    NSInteger end = [view message:SCI_DOCLINEFROMVISIBLE wParam:first + screen];
    if (end < 0 || end > lines) end = lines;
    *span = MAX(1, end - *start);
}

- (void)refreshViewport {
    if (!self.scintilla || self.hidden) return;
    CGFloat start, span;
    [self visibleStart:&start span:&span];
    const CGFloat lines = MAX(1, [self.scintilla message:SCI_GETLINECOUNT]);
    const CGFloat mapLines = self.bounds.size.height / DPMinimapLineHeight;
    const CGFloat progress = MIN(1, start / MAX(1, lines - span));
    _mapTop = progress * MAX(0, lines - mapLines);
    _viewportRect = NSIntersectionRect(self.bounds, NSMakeRect(0, (start - _mapTop) * DPMinimapLineHeight,
        self.bounds.size.width, MAX(8, span * DPMinimapLineHeight)));
    if (_dirty) [self invalidateContent];
    else if (!_image || _mapTop < _imageFirstLine ||
             MIN(lines, ceil(_mapTop + mapLines)) > _imageFirstLine + _imageLineCount) [self rebuildImage];
    self.needsDisplay = YES;
}

- (void)scrollToLine:(CGFloat)line {
    ScintillaView *view = self.scintilla;
    if (!view) return;
    const NSInteger lines = MAX(1, [view message:SCI_GETLINECOUNT]);
    const NSInteger target = MAX(0, MIN(lines - 1, (NSInteger)round(line)));
    [view message:SCI_ENSUREVISIBLE wParam:target];
    [view message:SCI_SETFIRSTVISIBLELINE wParam:[view message:SCI_VISIBLEFROMDOCLINE wParam:target]];
    [self refreshViewport];
}
- (void)mouseDown:(NSEvent *)event {
    [self refreshViewport];
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, _viewportRect))
        [self scrollToLine:_mapTop + (point.y - _viewportRect.size.height / 2) / DPMinimapLineHeight];
    CGFloat span;
    [self visibleStart:&_dragStartLine span:&span];
    const CGFloat lines = MAX(1, [self.scintilla message:SCI_GETLINECOUNT]);
    const CGFloat travel = MIN(self.bounds.size.height, lines * DPMinimapLineHeight) - _viewportRect.size.height;
    _dragLinesPerPoint = travel > 0 ? MAX(0, lines - span) / travel : 0;
    _dragStartY = point.y;
    _dragging = YES;
    self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self scrollToLine:_dragStartLine + (point.y - _dragStartY) * _dragLinesPerPoint];
}
- (void)mouseUp:(NSEvent *)event { _dragging = NO; self.needsDisplay = YES; }
- (void)scrollWheel:(NSEvent *)event { [self.scintilla.scrollView scrollWheel:event]; }
- (BOOL)accessibilityPerformIncrement { [self.scintilla message:SCI_LINESCROLL wParam:0 lParam:10]; [self refreshViewport]; return YES; }
- (BOOL)accessibilityPerformDecrement { [self.scintilla message:SCI_LINESCROLL wParam:0 lParam:-10]; [self refreshViewport]; return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    [[self backgroundColor] setFill]; NSRectFill(self.bounds);
    // A subdued shared surface and neutral thumb keep syntax colours dominant.
    NSColor *ink = _dark ? NSColor.whiteColor : NSColor.blackColor;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(self.bounds);
    const NSUInteger first = MAX(0, (NSInteger)floor(_mapTop));
    const NSUInteger count = MAX(0, (NSInteger)ceil(self.bounds.size.height / DPMinimapLineHeight) + 1);
    [[NSColor.systemGreenColor colorWithAlphaComponent:_highContrast ? 0.2 : 0.055] setFill];
    [_markerLines enumerateIndexesInRange:NSMakeRange(first, count) options:0 usingBlock:^(NSUInteger line, BOOL *stop) {
        NSRectFillUsingOperation(NSMakeRect(4, (line - self->_mapTop) * DPMinimapLineHeight,
            self.bounds.size.width - 8, DPMinimapLineHeight), NSCompositingOperationSourceOver);
    }];
    [_image drawInRect:NSMakeRect(0, (_imageFirstLine - _mapTop) * DPMinimapLineHeight, _imageSize.width, _imageSize.height)
        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [[ink colorWithAlphaComponent:0.07] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 1, self.bounds.size.height), NSCompositingOperationSourceOver);
    [[ink colorWithAlphaComponent:_highContrast ? 0.18 : (_dragging ? 0.09 : 0.045)] setFill];
    NSRectFillUsingOperation(_viewportRect, NSCompositingOperationSourceOver);
}
@end
