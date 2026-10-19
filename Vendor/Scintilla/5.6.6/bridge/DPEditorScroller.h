#import <AppKit/AppKit.h>

// AppKit still owns scroll geometry, wheel momentum, dragging and accessibility.
// Only the editor rail's appearance is custom.
@interface DPEditorScroller : NSScroller
- (void)configureDark:(BOOL)dark highContrast:(BOOL)highContrast;
@end
