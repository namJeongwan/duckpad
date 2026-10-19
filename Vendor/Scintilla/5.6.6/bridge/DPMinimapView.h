#import <AppKit/AppKit.h>
@class ScintillaView;

NS_ASSUME_NONNULL_BEGIN
@interface DPMinimapView : NSView
@property(nonatomic, weak, nullable) ScintillaView *scintilla;
@property(nonatomic, copy) NSIndexSet *markerLines;
@property(nonatomic, copy) NSString *navigationLabel;
@property(nonatomic, readonly) NSRect viewportRect;
@property(nonatomic, readonly) NSUInteger sampledByteCount;
@property(nonatomic, readonly) NSUInteger imageBuildCount;
- (void)configureDark:(BOOL)dark highContrast:(BOOL)highContrast;
- (void)invalidateContent;
- (void)refreshViewport;
@end
NS_ASSUME_NONNULL_END
