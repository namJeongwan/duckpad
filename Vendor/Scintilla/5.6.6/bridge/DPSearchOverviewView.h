#import <Cocoa/Cocoa.h>

// Search ticks fill the scrollbar track. Only tick hits intercept clicks;
// empty track and thumb dragging retain native scrollbar behavior.
@interface DPSearchOverviewView : NSView
@property(nonatomic, copy) NSArray<NSNumber *> *positions;
@property(nonatomic, strong) NSColor *markerColor;
@property(nonatomic, weak) NSScroller *scroller;
@property(nonatomic, copy) void (^onSelectMarker)(NSUInteger index);
@end
