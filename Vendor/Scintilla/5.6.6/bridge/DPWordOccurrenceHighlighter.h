#import <AppKit/AppKit.h>
@class ScintillaView;

NS_ASSUME_NONNULL_BEGIN
// Shared by panes displaying the same document; the focused pane supplies the word.
@interface DPWordOccurrenceHighlighter : NSObject
@property(nonatomic, readonly) NSUInteger inspectedByteCount;
@property(nonatomic, readonly) NSIndexSet *matchOffsets;
@property(nonatomic, readonly) NSUInteger matchedByteLength;
- (void)addView:(ScintillaView *)view onChange:(void (^)(void))onChange;
- (void)scheduleForView:(ScintillaView *)view enabled:(BOOL)enabled selectionChanged:(BOOL)selectionChanged;
- (void)removeView:(ScintillaView *)view;
- (void)documentChanged;
+ (void)applyAppearanceToView:(ScintillaView *)view dark:(BOOL)dark highContrast:(BOOL)highContrast;
+ (BOOL)isHighlightedInView:(ScintillaView *)view atPosition:(NSUInteger)position;
@end
NS_ASSUME_NONNULL_END
