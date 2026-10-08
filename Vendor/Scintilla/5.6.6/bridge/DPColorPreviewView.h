#import <AppKit/AppKit.h>
@class ScintillaView;
NS_ASSUME_NONNULL_BEGIN

// Duckpad-owned viewport-only gutter and color chooser.
@interface DPColorPreviewView : NSView
@property(nonatomic, weak, nullable) ScintillaView *scintilla;
@property(nonatomic, copy) NSString *changeColorLabel;
@property(nonatomic, copy) NSString *applyLabel;
@property(nonatomic, copy, nullable) BOOL (^shouldPreviewAt)(NSUInteger position);
@property(nonatomic, copy, nullable) BOOL (^onReplaceColor)(NSRange range, NSData *original, NSColor *color, uint64_t revision);
@property(nonatomic, readonly) NSArray<NSValue *> *ranges;
- (void)refreshWithRevision:(uint64_t)revision enabled:(BOOL)enabled editable:(BOOL)editable plantUML:(BOOL)plantUML;
- (void)closeChooser;
+ (nullable NSColor *)colorFromHex:(NSData *)hex plantUML:(BOOL)plantUML;
+ (NSData *)hexFromColor:(NSColor *)color preserving:(NSData *)original plantUML:(BOOL)plantUML;
@end

NS_ASSUME_NONNULL_END
