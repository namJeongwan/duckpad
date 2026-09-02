#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DPScintillaErrorDomain;
FOUNDATION_EXPORT void DPScintillaConfigureResourceDirectory(NSURL *directoryURL);

typedef NS_ERROR_ENUM(DPScintillaErrorDomain, DPScintillaErrorCode) {
    DPScintillaErrorInvalidUTF8 = 1,
    DPScintillaErrorInvalidRange = 2,
    DPScintillaErrorStaleRevision = 3,
    DPScintillaErrorRevisionOverflow = 4,
    DPScintillaErrorInvalidUTF8Boundary = 5,
};

typedef NS_ENUM(NSInteger, DPScintillaEditOrigin) {
    DPScintillaEditOriginUser = 0,
    DPScintillaEditOriginUndo = 1,
    DPScintillaEditOriginRedo = 2,
};

/// An owned edit value. `range` is measured in UTF-8 bytes, never UTF-16.
@interface DPScintillaEdit : NSObject
@property(nonatomic, readonly) NSRange range;
@property(nonatomic, readonly, copy) NSData *replacementUTF8;
@property(nonatomic, readonly, copy) NSData *insertedUTF8;
@property(nonatomic, readonly, copy) NSData *deletedUTF8;
@property(nonatomic, readonly) uint64_t baseRevision;
@property(nonatomic, readonly) uint64_t resultingRevision;
@property(nonatomic, readonly) DPScintillaEditOrigin origin;
@end

/// Narrow AppKit facade. No Scintilla message, pointer, or C++ type is public.
@interface DPScintillaEditorView : NSView
@property(nonatomic, copy, nullable) void (^onEdit)(DPScintillaEdit *edit);
@property(nonatomic, copy, nullable) void (^onError)(NSError *error);
@property(nonatomic, readonly, nullable) NSError *lastMutationError;
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly, copy) NSData *contentUTF8;
@property(nonatomic, readonly) NSUInteger documentByteLength;
@property(nonatomic, getter=isInputEnabled) BOOL inputEnabled;
@property(nonatomic, getter=isWordWrapEnabled) BOOL wordWrapEnabled;
@property(nonatomic, readonly) NSUInteger selectionCount;
@property(nonatomic, readonly) NSUInteger caretUTF8Position;
@property(nonatomic, readonly) NSUInteger anchorUTF8Position;
@property(nonatomic, readonly) NSUInteger firstVisibleLine;
@property(nonatomic, readonly) NSUInteger horizontalScrollOffset;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
@property(nonatomic, readonly) BOOL cursorResourcesAvailable;
@property(nonatomic, readonly) BOOL hasEditorFocus;
@property(nonatomic, readonly) NSUInteger snapshotReadCount;
@property(nonatomic, readonly) NSUInteger incrementalNotificationCount;
@property(nonatomic, readonly) NSUInteger incrementalPayloadByteCount;

- (BOOL)loadUTF8:(NSData *)content
         revision:(uint64_t)revision
            error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceUTF8Range:(NSRange)range
         withReplacement:(NSData *)replacement
        expectedRevision:(uint64_t)expectedRevision
       resultingRevision:(uint64_t)resultingRevision
                    error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceUTF8Ranges:(NSArray<NSValue *> *)ranges
         withReplacements:(NSArray<NSData *> *)replacements
          expectedRevision:(uint64_t)expectedRevision
                     error:(NSError * _Nullable * _Nullable)error;
- (NSRange)searchUTF8:(NSData *)pattern
            backwards:(BOOL)backwards
            matchCase:(BOOL)matchCase
            wholeWord:(BOOL)wholeWord
              regularExpression:(BOOL)regularExpression
          restrictToRange:(NSRange)restriction
            wrapAround:(BOOL)wrapAround
                 error:(NSError * _Nullable * _Nullable)error;
- (void)setPrimarySelectionUTF8Range:(NSRange)range;
- (void)restoreCaretUTF8Position:(NSUInteger)caret
                  anchorPosition:(NSUInteger)anchor
                firstVisibleLine:(NSUInteger)firstVisibleLine
          horizontalScrollOffset:(NSUInteger)horizontalScrollOffset
                 wordWrapEnabled:(BOOL)wordWrapEnabled;
- (BOOL)addSelectionUTF8Range:(NSRange)range;
- (void)insertCommittedText:(NSString *)text;
- (void)setMarkedText:(NSString *)text
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange;
- (void)unmarkText;
- (BOOL)hasMarkedText;
- (void)copySelection;
- (void)paste;
- (void)undo;
- (void)redo;
- (void)beginGroupedUndo;
- (void)endGroupedUndo;
- (void)focusEditor;
- (void)resetInstrumentation;
@end

NS_ASSUME_NONNULL_END
