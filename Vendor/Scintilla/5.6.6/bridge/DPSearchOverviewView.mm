#import "DPSearchOverviewView.h"
#include <cmath>

@implementation DPSearchOverviewView {
    NSIndexSet *_rows;
    CGFloat _cachedHeight;
    CGFloat _cachedScale;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _positions = @[];
        _markerColor = NSColor.systemGreenColor;
        self.hidden = YES;
        self.accessibilityIdentifier = @"duckpad.search.overview";
        self.accessibilityElement = NO;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSUInteger)markerAtPoint:(NSPoint)point {
    if (!NSPointInRect(point, self.bounds) || _positions.count == 0) return NSNotFound;
    const CGFloat span = MAX(0, self.bounds.size.height - 3);
    const CGFloat target = point.y - 1.5;
    // Sorted display positions permit a binary search even for dense matches.
    NSUInteger low = 0, high = _positions.count;
    while (low < high) {
        const NSUInteger mid = low + (high - low) / 2;
        if (_positions[mid].doubleValue * span < target) low = mid + 1;
        else high = mid;
    }
    NSUInteger nearest = MIN(low, _positions.count - 1);
    if (nearest > 0 && fabs(_positions[nearest - 1].doubleValue * span - target)
        < fabs(_positions[nearest].doubleValue * span - target)) --nearest;
    return fabs(_positions[nearest].doubleValue * span + 1.5 - point.y) <= 4 ? nearest : NSNotFound;
}
- (NSView *)hitTest:(NSPoint)point {
    const NSPoint local = [self convertPoint:point fromView:self.superview];
    // A dense result set must not turn the scrollbar thumb into a link.
    if (_scroller && !_scroller.hidden) {
        const NSPoint inScroller = [_scroller convertPoint:local fromView:self];
        if (NSPointInRect(inScroller, [_scroller rectForPart:NSScrollerKnob])) return nil;
    }
    return !self.hidden && [self markerAtPoint:local] != NSNotFound ? self : nil;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event {
    const NSUInteger index = [self markerAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != NSNotFound && self.onSelectMarker) self.onSelectMarker(index);
}
- (void)setPositions:(NSArray<NSNumber *> *)positions {
    if ([_positions isEqualToArray:positions]) return;
    _positions = [positions copy];
    _rows = nil;
    self.hidden = positions.count == 0;
    self.needsDisplay = YES;
}
- (void)setMarkerColor:(NSColor *)color {
    _markerColor = color;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    const CGFloat scale = self.window.backingScaleFactor ?: 1;
    const CGFloat height = self.bounds.size.height;
    if (!_rows || height != _cachedHeight || scale != _cachedScale) {
        // Coalesce dense results to screen rows. Painting is bounded by track
        // height rather than the number of matches, and scrolling reuses it.
        NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
        for (NSNumber *position in _positions) {
            const CGFloat y = MAX(0, MIN(1, position.doubleValue)) * MAX(0, height - 3);
            const NSUInteger first = (NSUInteger)std::floor(y * scale);
            const NSUInteger end = MIN((NSUInteger)std::ceil(height * scale),
                first + (NSUInteger)std::ceil(MIN(3, height) * scale));
            [rows addIndexesInRange:NSMakeRange(first, end - first)];
        }
        _rows = rows;
        _cachedHeight = height;
        _cachedScale = scale;
    }
    [_markerColor setFill];
    // Paint each covered pixel only once so dense results retain the same
    // transparency as isolated ticks and never obscure the native thumb.
    [_rows enumerateRangesUsingBlock:^(NSRange rows, BOOL *stop) {
        NSRectFillUsingOperation(NSMakeRect(0, rows.location / scale,
            self.bounds.size.width, rows.length / scale), NSCompositingOperationSourceOver);
    }];
}
@end
