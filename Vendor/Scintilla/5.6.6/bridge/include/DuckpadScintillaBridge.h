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

typedef NS_ENUM(NSInteger, DPScintillaPalette) {
    DPScintillaPaletteLight = 0,
    DPScintillaPaletteDark = 1,
    DPScintillaPaletteHighContrastLight = 2,
    DPScintillaPaletteHighContrastDark = 3,
};

typedef NS_ENUM(NSInteger, DPScintillaEditingCommand) {
    DPScintillaEditingCommandDuplicateLine = 0,
    DPScintillaEditingCommandMoveLineUp = 1,
    DPScintillaEditingCommandMoveLineDown = 2,
    DPScintillaEditingCommandDeleteLine = 3,
    DPScintillaEditingCommandJoinLines = 4,
    DPScintillaEditingCommandUppercase = 5,
    DPScintillaEditingCommandLowercase = 6,
    DPScintillaEditingCommandIndent = 7,
    DPScintillaEditingCommandUnindent = 8,
    DPScintillaEditingCommandTrimTrailingWhitespace = 9,
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
@property(nonatomic, copy, nullable) void (^onFoldStateChange)(void);
@property(nonatomic, copy, nullable) void (^onFoldRecoveryProgress)(void);
@property(nonatomic, readonly, nullable) NSError *lastMutationError;
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly, copy) NSData *contentUTF8;
@property(nonatomic, readonly) NSUInteger documentByteLength;
- (nullable NSData *)utf8BytesInRange:(NSRange)range
                                error:(NSError * _Nullable * _Nullable)error;
@property(nonatomic, getter=isInputEnabled) BOOL inputEnabled;
@property(nonatomic, getter=isWordWrapEnabled) BOOL wordWrapEnabled;
@property(nonatomic, getter=isWrapMarkerVisible) BOOL wrapMarkerVisible;
@property(nonatomic, getter=isWhitespaceVisible) BOOL whitespaceVisible;
@property(nonatomic, getter=areLineEndingsVisible) BOOL lineEndingsVisible;
@property(nonatomic) NSInteger zoomLevel;
@property(nonatomic, readonly) NSUInteger selectionCount;
@property(nonatomic, readonly) NSUInteger caretUTF8Position;
@property(nonatomic, readonly) NSUInteger anchorUTF8Position;
@property(nonatomic, readonly) NSUInteger firstVisibleLine;
@property(nonatomic, readonly) NSUInteger horizontalScrollOffset;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *bookmarkedLines;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
@property(nonatomic, readonly) BOOL canCut;
@property(nonatomic, readonly) BOOL canCopy;
@property(nonatomic, readonly) BOOL canPaste;
@property(nonatomic, readonly) BOOL canDelete;
@property(nonatomic, readonly) BOOL canSelectAll;
@property(nonatomic, readonly) BOOL cursorResourcesAvailable;
@property(nonatomic, readonly) BOOL hasEditorFocus;
@property(nonatomic, readonly) NSUInteger snapshotReadCount;
@property(nonatomic, readonly) NSUInteger incrementalNotificationCount;
@property(nonatomic, readonly) NSUInteger incrementalPayloadByteCount;
@property(nonatomic, readonly, copy) NSString *lexerName;
@property(nonatomic, readonly) BOOL languageStylingFallback;
@property(nonatomic, readonly) NSUInteger languageConfigurationCount;
@property(nonatomic, readonly) NSUInteger commentCommandInspectedByteCount;
@property(nonatomic, readonly) NSUInteger synchronouslyStyledByteCount;
@property(nonatomic, readonly) NSUInteger configuredTabWidth;
@property(nonatomic, readonly) BOOL configuredUseTabs;
@property(nonatomic, readonly) BOOL configuredFoldingEnabled;
@property(nonatomic, readonly) BOOL configuredBraceMatchingEnabled;
@property(nonatomic, readonly) NSInteger highlightedBraceUTF8Position;
@property(nonatomic, readonly) NSInteger matchingBraceUTF8Position;
@property(nonatomic, readonly) NSInteger badBraceUTF8Position;
@property(nonatomic, readonly, getter=isCompletionActive) BOOL completionActive;
@property(nonatomic, readonly) NSUInteger completionItemCount;
@property(nonatomic, readonly) NSUInteger lineCount;
@property(nonatomic, readonly) NSUInteger caretLine;
@property(nonatomic, readonly) NSUInteger caretColumn;
@property(nonatomic, readonly) BOOL canCollapseCurrentFold;
@property(nonatomic, readonly) BOOL canExpandCurrentFold;
@property(nonatomic, readonly) BOOL hasContractedFolds;

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
- (void)restoreBookmarkedLines:(NSArray<NSNumber *> *)lines;
- (void)toggleBookmarkAtCaret;
- (BOOL)navigateToBookmarkForward:(BOOL)forward;
- (void)clearBookmarks;
- (BOOL)goToOneBasedLine:(NSUInteger)line column:(NSUInteger)column;
- (BOOL)goToUTF8Offset:(NSUInteger)offset;
- (void)shareDocumentWithView:(DPScintillaEditorView *)source;
- (void)synchronizeRevision:(uint64_t)revision;
/// Disconnects native callbacks and document watchers before a pane is discarded.
- (void)invalidate;
- (BOOL)addSelectionUTF8Range:(NSRange)range;
- (void)insertCommittedText:(NSString *)text;
- (void)setMarkedText:(NSString *)text
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange;
- (void)unmarkText;
- (BOOL)hasMarkedText;
- (void)copySelection;
- (void)cutSelection;
- (void)paste;
- (void)deleteSelectionOrNextCharacter;
- (void)selectAll;
- (void)undo;
- (void)redo;
- (BOOL)canPerformEditingCommand:(DPScintillaEditingCommand)command;
- (void)performEditingCommand:(DPScintillaEditingCommand)command;
- (void)beginGroupedUndo;
- (void)endGroupedUndo;
- (void)focusEditor;
- (BOOL)applyLexerNamed:(NSString *)lexerName
               keywords:(NSArray<NSString *> *)keywords
                tabWidth:(NSUInteger)tabWidth
                 useTabs:(BOOL)useTabs
                 folding:(BOOL)folding
           braceMatching:(BOOL)braceMatching
        maximumStyleBytes:(NSUInteger)maximumStyleBytes;
- (NSData *)contentPrefixUTF8WithMaximumLength:(NSUInteger)maximumLength;
- (void)applyPalette:(DPScintillaPalette)palette;
- (NSInteger)styleAtUTF8Position:(NSUInteger)position;
- (NSUInteger)foregroundColorForStyle:(NSInteger)style;
- (NSInteger)foldLevelAtLine:(NSUInteger)line;
- (BOOL)isFoldExpandedAtLine:(NSUInteger)line;
- (void)toggleFoldAtLine:(NSUInteger)line;
- (NSArray<NSNumber *> *)contractedFoldHeaderLinesWithMaximumCount:(NSUInteger)maximumCount
    NS_SWIFT_NAME(contractedFoldHeaderLines(maximumCount:));
- (NSArray<NSNumber *> *)restoreContractedFoldHeaderLines:(NSArray<NSNumber *> *)lines
    NS_SWIFT_NAME(restoreContractedFoldHeaderLines(_:));
- (BOOL)isLineVisibleAtLine:(NSUInteger)line NS_SWIFT_NAME(isLineVisible(at:));
- (BOOL)collapseCurrentFold;
- (BOOL)expandCurrentFold;
- (BOOL)collapseAllFolds;
- (BOOL)expandAllFolds;
- (void)updateBraceHighlight;
- (BOOL)toggleLineCommentsWithPrefixUTF8:(NSData *)prefix;
- (BOOL)showCompletionItems:(NSArray<NSString *> *)items
   replacingPrefixByteCount:(NSUInteger)prefixByteCount;
- (void)cancelCompletion;
+ (BOOL)supportsLexerNamed:(NSString *)lexerName;
- (void)resetInstrumentation;
@end

NS_ASSUME_NONNULL_END
