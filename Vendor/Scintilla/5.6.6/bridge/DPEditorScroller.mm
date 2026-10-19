#import "DPEditorScroller.h"

@implementation DPEditorScroller {
    BOOL _dark, _highContrast, _dragging;
}
+ (BOOL)isCompatibleWithOverlayScrollers { return NO; }
- (void)configureDark:(BOOL)dark highContrast:(BOOL)highContrast {
    _dark = dark; _highContrast = highContrast;
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event {
    _dragging = YES; self.needsDisplay = YES;
    [super mouseDown:event];
    _dragging = NO; self.needsDisplay = YES;
}
- (void)drawKnobSlotInRect:(NSRect)rect highlight:(BOOL)highlight {
    NSColor *surface = _dark ? [NSColor colorWithSRGBRed:40/255.0 green:44/255.0 blue:51/255.0 alpha:1]
        : [NSColor colorWithWhite:250/255.0 alpha:1];
    [surface setFill]; NSRectFill(self.bounds);
    [[(_dark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:_highContrast ? 0.4 : 0.07] setFill];
    const BOOL vertical = self.bounds.size.height > self.bounds.size.width;
    NSRectFillUsingOperation(vertical ? NSMakeRect(0, 0, 1, self.bounds.size.height)
        : NSMakeRect(0, 0, self.bounds.size.width, 1), NSCompositingOperationSourceOver);
}
- (void)drawKnob {
    NSRect knob = [self rectForPart:NSScrollerKnob];
    if (NSIsEmptyRect(knob) || self.knobProportion >= 1) return;
    const BOOL vertical = self.bounds.size.height > self.bounds.size.width;
    // Keep the native hit target while presenting a slim, square-edged rail.
    if (vertical) { knob.origin.x = NSMaxX(self.bounds) - 9; knob.size.width = 8; }
    else { knob.origin.y = NSMaxY(self.bounds) - 9; knob.size.height = 8; }
    const CGFloat alpha = _highContrast ? 0.65 : (_dragging ? 0.28 : 0.22);
    [[(_dark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:alpha] setFill];
    NSRectFillUsingOperation(knob, NSCompositingOperationSourceOver);
}
- (void)drawRect:(NSRect)dirtyRect {
    [self drawKnobSlotInRect:self.bounds highlight:NO];
    [self drawKnob];
}
@end
