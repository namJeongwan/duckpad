#import "DuckpadScintillaBridge.h"

#import "ScintillaView.h"
#import "DPSearchOverviewView.h"
#import "DPColorPreviewView.h"
#import "DPWordOccurrenceHighlighter.h"
#import "DPMinimapView.h"
#import "DPEditorScroller.h"

#include <limits>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <utility>
#include <vector>
#include "ILexer.h"
#include "Lexilla.h"
#include "SciLexer.h"
#include "DPScintillaLegacyStyleRoles.h"
#include "DPPlantUMLLexer.h"
#include "DPLogLexer.h"
#include "DPAsyncLexer.h"
#include <chrono>

@interface DPScintillaBinaryDocument (DuckpadAttachment)
- (void)attachToScintillaView:(ScintillaView *)view;
- (BOOL)isAttachedToScintillaView:(ScintillaView *)view;
- (BOOL)appendMaximumBytes:(NSUInteger)maximumBytes error:(NSError **)error;
@end

NSErrorDomain const DPScintillaErrorDomain = @"app.duckpad.scintilla";
static NSURL *DPScintillaResourceDirectory;
static constexpr sptr_t DPMaximumBulkSelections = 10000;
static constexpr sptr_t DPMaximumBulkSelectionDocumentBytes = 16 * 1024 * 1024;
static constexpr sptr_t DPMaximumBulkSelectionPatternBytes = 64 * 1024;
static constexpr int DPSearchIndicator = 8;
static constexpr int DPDeclarationIndicator = 9;
static constexpr int DPBookmarkMarker = 20;
static constexpr int DPBookmarkMask = 1 << DPBookmarkMarker;
static constexpr NSInteger DPSmartIndentScanLimit = 4096;
static constexpr NSUInteger DPMaximumSynchronousStyleBytes = 262144;
static constexpr NSUInteger DPMaximumFoldRecoveryHeaderCount = 10000;
static constexpr uint64_t DPBlockCommentRequiredRevisionBudget = 3;
static constexpr uint64_t DPSmartCloserRequiredRevisionBudget = 5;

typedef NSData * _Nullable (^DPScintillaAggregateReplacementBuilder)(NSData *deletedUTF8);

static BOOL DPIntegerFromNumber(NSNumber *number, NSInteger *value) {
    if (![number isKindOfClass:[NSNumber class]] || !std::isfinite(number.doubleValue)) return NO;
    NSDecimal decimal = number.decimalValue;
    if (NSDecimalIsNotANumber(&decimal)) return NO;
    NSDecimal integral;
    NSDecimalRound(&integral, &decimal, 0, NSRoundDown);
    if (NSDecimalCompare(&decimal, &integral) != NSOrderedSame) return NO;
    NSDecimal minimum = @(NSIntegerMin).decimalValue;
    NSDecimal maximum = @(NSIntegerMax).decimalValue;
    if (NSDecimalCompare(&decimal, &minimum) == NSOrderedAscending
        || NSDecimalCompare(&decimal, &maximum) == NSOrderedDescending) return NO;
    *value = number.integerValue;
    return YES;
}

static int DPEOLModeForUTF8(NSData *content) {
    const auto *bytes = static_cast<const unsigned char *>(content.bytes);
    for (NSUInteger index = 0; index < content.length; index += 1) {
        if (bytes[index] == '\r') {
            return index + 1 < content.length && bytes[index + 1] == '\n'
                ? SC_EOL_CRLF : SC_EOL_CR;
        }
        if (bytes[index] == '\n') return SC_EOL_LF;
    }
    return SC_EOL_LF;
}

static BOOL DPBlockCommentDelimiterIsValid(NSData *delimiter) {
    return delimiter.length > 0
        && delimiter.length <= 64
        && [[NSString alloc] initWithData:delimiter encoding:NSUTF8StringEncoding] != nil;
}

static DPScintillaSelectionShape DPSelectionShapeFromScintilla(NSInteger selectionMode) {
    switch (selectionMode) {
        case SC_SEL_STREAM: return DPScintillaSelectionShapeStream;
        case SC_SEL_RECTANGLE: return DPScintillaSelectionShapeRectangle;
        case SC_SEL_LINES: return DPScintillaSelectionShapeLines;
        case SC_SEL_THIN: return DPScintillaSelectionShapeThin;
        default: return DPScintillaSelectionShapeThin;
    }
}

static BOOL DPScintillaBytesMatch(ScintillaView *scintilla, NSUInteger position, NSData *bytes) {
    const auto *expected = static_cast<const unsigned char *>(bytes.bytes);
    for (NSUInteger index = 0; index < bytes.length; index += 1) {
        if ([scintilla message:SCI_GETCHARAT wParam:(uptr_t)(position + index)] != expected[index]) {
            return NO;
        }
    }
    return YES;
}

static BOOL DPIsClosingDelimiter(int character) {
    return character == '}' || character == ']' || character == ')';
}

static BOOL DPIsSmartClosingCharacter(int character) {
    return DPIsClosingDelimiter(character)
        || character == '\'' || character == '"' || character == '`';
}

static const char *DPSmartPairForOpening(int character) {
    switch (character) {
    case '{': return "{}";
    case '[': return "[]";
    case '(': return "()";
    case '\'': return "''";
    case '"': return "\"\"";
    case '`': return "``";
    default: return nullptr;
    }
}

static NSUInteger DPIndentationColumns(const std::string &prefix, NSUInteger tabWidth) {
    NSUInteger columns = 0;
    for (const unsigned char character : prefix) {
        if (character == '\t') {
            columns += tabWidth - (columns % tabWidth);
        } else {
            columns += 1;
        }
    }
    return columns;
}

static std::string DPCanonicalIndentation(NSUInteger columns, NSUInteger tabWidth, BOOL useTabs) {
    if (!useTabs) return std::string(columns, ' ');
    std::string result(columns / tabWidth, '\t');
    result.append(columns % tabWidth, ' ');
    return result;
}

void DPScintillaConfigureResourceDirectory(NSURL *directoryURL) {
    DPScintillaResourceDirectory = [directoryURL copy];
}

NSString *DPScintillaResourcePath(NSString *name) {
    if (DPScintillaResourceDirectory == nil) return nil;
    return [[DPScintillaResourceDirectory URLByAppendingPathComponent:name] path];
}

@interface DPScintillaEdit ()
@property(nonatomic, readwrite) BOOL isIntermediateUndoRedo;
@property(nonatomic, readwrite) NSInteger metadataToken;
- (instancetype)initWithRange:(NSRange)range
                  insertedUTF8:(NSData *)inserted
                   deletedUTF8:(NSData *)deleted
                  baseRevision:(uint64_t)baseRevision
             resultingRevision:(uint64_t)resultingRevision
                        origin:(DPScintillaEditOrigin)origin;
@end

@implementation DPScintillaEdit
- (instancetype)initWithRange:(NSRange)range
                  insertedUTF8:(NSData *)inserted
                   deletedUTF8:(NSData *)deleted
                  baseRevision:(uint64_t)baseRevision
             resultingRevision:(uint64_t)resultingRevision
                        origin:(DPScintillaEditOrigin)origin {
    self = [super init];
    if (self) {
        _range = range;
        _insertedUTF8 = [inserted copy];
        _deletedUTF8 = [deleted copy];
        _replacementUTF8 = _insertedUTF8;
        _baseRevision = baseRevision;
        _resultingRevision = resultingRevision;
        _origin = origin;
    }
    return self;
}
@end

@interface DPScintillaEditorView () <ScintillaNotificationProtocol>
- (BOOL)applyAggregateUserEditInRange:(NSRange)range
                       selectionOwner:(DPScintillaEditorView *)selectionOwner
                 resultingAnchorUTF8:(NSUInteger)anchor
                  resultingCaretUTF8:(NSUInteger)caret
              replacementBuilder:(DPScintillaAggregateReplacementBuilder)replacementBuilder;
- (BOOL)prepareClosingDelimiterDedent:(SCNotification *)notification;
- (BOOL)publishPendingSmartCloser;
- (void)finishPendingSmartIndentation;
- (void)captureDirectInputPreflightState;
- (BOOL)applyAggregateUserEditInRange:(NSRange)range
                       selectionOwner:(DPScintillaEditorView *)selectionOwner
                 resultingAnchorUTF8:(NSUInteger)anchor
                  resultingCaretUTF8:(NSUInteger)caret
                   preserveSelection:(BOOL)preserveSelection
              replacementBuilder:(DPScintillaAggregateReplacementBuilder)replacementBuilder;
- (void)clearDirectInputPreflightState;
@end

@interface SCIContentView (DuckpadStandardEditing)
- (void)selectAll:(id)sender;
- (void)cut:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (BOOL)canUndo;
- (BOOL)canRedo;
@end

static BOOL DPContentCanPerform(SCIContentView *content, SEL action) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
    return [content validateUserInterfaceItem:item];
}

@implementation DPScintillaEditorView {
    ScintillaView *_scintilla;
    DPSearchOverviewView *_searchOverview;
    DPMinimapView *_minimap;
    BOOL _minimapVisible;
    NSInteger _baseRightPadding;
    NSInteger _minimapReservedWidth;
    DPColorPreviewView *_colorPreview;
    NSIndexSet *_searchMarkerOffsets;
    NSHashTable<DPScintillaEditorView *> *_searchMarkerPeers;
    DPWordOccurrenceHighlighter *_wordHighlighter;
    BOOL _searchHighlightsActive;
    BOOL _searchOverviewNeedsRefresh;
    NSInteger _searchOverviewDisplayLineCount;
    CGFloat _searchOverviewDocumentHeight;
    uint64_t _revision;
    BOOL _suppressEdit;
    BOOL _requestedInputEnabled;
    BOOL _observedFollowEnd;
    id _observedInputMonitor;
    NSUInteger _declarationHoverPosition;
    NSRange _declarationHoverRange;
    BOOL _binaryDocument;
    BOOL _caretWordHighlightEnabled;
    BOOL _loadingText;
    NSUInteger _loadingTextTotal;
    BOOL _loadingTextHasEOL;
    std::string _binarySelectionBeforeAppend;
    NSInteger _binaryFirstVisibleLine;
    NSInteger _binaryHorizontalScroll;
    NSError *_lastMutationError;
    NSUInteger _snapshotReadCount;
    NSUInteger _incrementalNotificationCount;
    NSUInteger _incrementalPayloadByteCount;
    NSData *_lastSearchPattern;
    NSUInteger _lastZeroLengthSearchPosition;
    BOOL _lastSearchWasZeroLength;
    BOOL _lastSearchBackwards;
    NSString *_lexerName;
    BOOL _languageStylingFallback;
    NSUInteger _languageConfigurationCount;
    NSUInteger _maximumStyleBytes;
    BOOL _foldingEnabled;
    BOOL _deferReplacementStyling;
    BOOL _braceMatchingEnabled;
    DPScintillaPalette _palette;
    std::vector<std::pair<int, int>> _semanticStyleRoles;
    NSUInteger _commentCommandInspectedByteCount;
    NSUInteger _synchronouslyStyledByteCount;
    NSInteger _highlightedBraceUTF8Position;
    NSInteger _matchingBraceUTF8Position;
    NSInteger _badBraceUTF8Position;
    NSUInteger _completionItemCount;
    BOOL _publishesDocumentEdits;
    __weak DPScintillaEditorView *_documentPublisher;
    BOOL _smartEditingEnabled;
    BOOL _plainTextIndentationEnabled;
    BOOL _highlightCurrentLine;
    NSString *_editorFontName;
    double _editorFontSize;
    BOOL _textInputSourceKnown;
    BOOL _directInputInsertion;
    BOOL _directInputByteLengthKnown;
    NSUInteger _directInputByteLength;
    BOOL _directInputSelectionEligible;
    __weak DPScintillaEditorView *_directInputInitiator;
    NSInteger _pendingSmartCaretPosition;
    NSInteger _pendingSmartInsertionEnd;
    int _pendingSmartCharacter;
    NSInteger _pendingSmartIndentationInsertionPosition;
    NSRange _pendingSmartIndentationRange;
    NSData *_pendingSmartIndentationOriginalUTF8;
    NSData *_pendingSmartIndentationReplacementUTF8;
    NSInteger _pendingSmartIndentationExpectedPostInsertCaret;
    int _pendingSmartIndentationCloser;
    uint64_t _pendingSmartIndentationBaseRevision;
    BOOL _pendingSmartIndentationUndoGroupOpen;
    __weak DPScintillaEditorView *_pendingSmartIndentationPublisher;
    BOOL _pendingSmartIndentationPublisherWasSuppressingEdit;
    BOOL _pendingSmartIndentationCharacterAdded;
    NSUInteger _pendingSmartIndentationSuppressedNativeComponentCount;
    BOOL _pendingSmartIndentationApplyingReplacement;
    BOOL _foldRecoveryProgressPending;
    BOOL _foldRecoveryProgressScheduled;
    BOOL _collapseAllFoldsAfterStyling;
    NSUInteger _collapseAllFoldsGeneration;
    NSUInteger _focusEventGeneration;
    uint64_t _statusContentGeneration;
    uint64_t _selectedCountGeneration;
    NSUInteger _selectedCharacterCount;
    std::vector<std::pair<NSInteger, NSInteger>> _countedSelections;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _contextMenuTitles = @{};
        _scintilla = [[ScintillaView alloc] initWithFrame:self.bounds];
        _scintilla.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scintilla.delegate = self;
        NSScrollView *scroll = _scintilla.scrollView;
        scroll.verticalScroller = [[DPEditorScroller alloc] initWithFrame:NSMakeRect(0, 0, 15, 100)];
        scroll.horizontalScroller = [[DPEditorScroller alloc] initWithFrame:NSMakeRect(0, 0, 100, 15)];
        scroll.scrollerStyle = NSScrollerStyleLegacy;
        [self addSubview:_scintilla];
        _searchOverview = [[DPSearchOverviewView alloc] initWithFrame:NSZeroRect];
        _minimap = [[DPMinimapView alloc] initWithFrame:NSZeroRect];
        _minimap.scintilla = _scintilla;
        [self addSubview:_minimap];
        __weak DPScintillaEditorView *weakSelf = self;
        _colorPreview = [[DPColorPreviewView alloc] initWithFrame:NSZeroRect];
        _colorPreview.scintilla = _scintilla;
        _colorPreview.hidden = YES;
        _colorPreview.shouldPreviewAt = ^BOOL(NSUInteger position) {
            DPScintillaEditorView *owner = weakSelf;
            if (!owner) return NO;
            const int style = [owner->_scintilla message:SCI_GETSTYLEAT wParam:position];
            for (const auto &entry : owner->_semanticStyleRoles)
                if (entry.first == style && entry.second == 1) return NO;
            return YES;
        };
        _colorPreview.onReplaceColor = ^BOOL(NSRange range, NSData *original, NSColor *color, uint64_t revision) {
            DPScintillaEditorView *owner = weakSelf;
            if (!owner || owner.revision != revision) return NO;
            NSData *current = [owner utf8BytesInRange:range error:nil];
            if (![current isEqualToData:original]) return NO;
            return [owner replaceColorInUTF8Range:range withColor:color expectedRevision:revision];
        };
        [self addSubview:_colorPreview];
        // Cocoa can scroll cached text without SCN_PAINTED. Sibling gutter
        // controls must follow the clip viewport immediately, not the next paint.
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(colorPreviewViewportChanged:)
            name:NSViewBoundsDidChangeNotification object:_scintilla.scrollView.contentView];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(asynchronousStylingCompleted:)
            name:DPAsyncLexerDidStyleNotification object:nil];
        _searchOverview.onSelectMarker = ^(NSUInteger index) { [weakSelf navigateToSearchMarker:index]; };
        [self addSubview:_searchOverview];
        _searchMarkerOffsets = [NSIndexSet indexSet];
        _searchMarkerPeers = [NSHashTable weakObjectsHashTable];
        [_searchMarkerPeers addObject:self];
        _wordHighlighter = [[DPWordOccurrenceHighlighter alloc] init];
        [self attachWordHighlighter];
        [_scintilla message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_scintilla message:SCI_SETMULTIPLESELECTION wParam:YES];
        [_scintilla message:SCI_SETADDITIONALSELECTIONTYPING wParam:YES];
        [_scintilla message:SCI_SETMULTIPASTE wParam:SC_MULTIPASTE_EACH];
        [_scintilla message:SCI_SETMOUSESELECTIONRECTANGULARSWITCH wParam:YES];
        // Maintain the index while loading/editing, before Cocoa's input manager
        // can ask for document-wide UTF-16 coordinates on every key event.
        [_scintilla message:SCI_ALLOCATELINECHARACTERINDEX wParam:SC_LINECHARACTERINDEX_UTF16];
        _publishesDocumentEdits = YES;
        [self updateModificationEventMask];
        [_scintilla message:SCI_SETUNDOSELECTIONHISTORY
                     wParam:SC_UNDO_SELECTION_HISTORY_ENABLED];
        [_scintilla message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];
        _editorFontName = @"Menlo";
        _editorFontSize = 13;
        [_scintilla setFontName:_editorFontName size:_editorFontSize bold:NO italic:NO];
        _lexerName = @"null";
        _maximumStyleBytes = 16 * 1024 * 1024;
        _foldingEnabled = YES;
        _braceMatchingEnabled = YES;
        _highlightedBraceUTF8Position = -1;
        _matchingBraceUTF8Position = -1;
        _badBraceUTF8Position = -1;
        _pendingSmartCaretPosition = -1;
        _pendingSmartInsertionEnd = -1;
        _pendingSmartIndentationInsertionPosition = -1;
        _pendingSmartIndentationExpectedPostInsertCaret = -1;
        [_scintilla message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:0 lParam:40];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:1 lParam:SC_MASK_FOLDERS];
        [_scintilla message:SCI_SETMARGINSENSITIVEN wParam:1 lParam:1];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:1 lParam:12];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:2 lParam:DPBookmarkMask];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:2 lParam:12];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:3 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:3 lParam:0x01E00000];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:3 lParam:3];
        [_scintilla message:SCI_SETMARGINSENSITIVEN wParam:3 lParam:0];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:4 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:4 lParam:0];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:4 lParam:0];
        for (int marker = SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN;
             marker <= SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED; ++marker) {
            [_scintilla message:SCI_MARKERDEFINE wParam:marker lParam:SC_MARK_BAR];
        }
        [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
        [_scintilla message:SCI_MARKERDEFINE wParam:DPBookmarkMarker lParam:SC_MARK_BOOKMARK];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN lParam:SC_MARK_ARROWDOWN];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER lParam:SC_MARK_ARROW];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB lParam:SC_MARK_EMPTY];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL lParam:SC_MARK_EMPTY];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND lParam:SC_MARK_ARROW];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_ARROWDOWN];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_EMPTY];
        [_scintilla message:SCI_SETINDENTATIONGUIDES wParam:SC_IV_LOOKBOTH];
        _highlightCurrentLine = YES;
        [self applyPalette:DPScintillaPaletteLight];
        [self configureTextLayoutWithLeftPadding:0 rightPadding:8 lineSpacing:4];
        _requestedInputEnabled = YES;
        _declarationHoverPosition = NSNotFound;
        _declarationHoverRange = NSMakeRange(NSNotFound, 0);
        self.accessibilityIdentifier = @"duckpad.editor.scintilla";
    }
    return self;
}

- (void)scintillaPrepareContextMenu:(NSMenu *)menu {
    // These command tags belong to the pinned ScintillaBase context menu.
    // Keep this mapping inside the bridge; Swift only sees stable command keys.
    NSArray<NSString *> *keys = @[@"undo", @"redo", @"cut", @"copy", @"paste", @"delete", @"selectAll"];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem || item.tag < 10 || item.tag > 16) continue;
        NSString *key = keys[item.tag - 10];
        item.identifier = [@"duckpad.editor.context." stringByAppendingString:key];
        NSString *title = self.contextMenuTitles[key];
        if (title) item.title = title;
    }
}

- (void)layout {
    [super layout];
    [self scheduleWordHighlights:NO];
    [self refreshColorPreviews];
    NSScrollView *scroll = _scintilla.scrollView;
    NSRect track = [self convertRect:scroll.contentView.bounds fromView:scroll.contentView];
    NSScroller *scroller = scroll.verticalScroller;
    _searchOverview.scroller = scroller;
    if (!scroller.hidden && scroller.frame.size.width > 0) {
        track = [self convertRect:scroller.bounds fromView:scroller];
    }
    const CGFloat width = MAX(12, scroller.frame.size.width);
    const BOOL showsMap = _minimapVisible && !_binaryDocument && !_loadingText && self.bounds.size.width >= 420;
    const BOOL wasHidden = _minimap.hidden;
    _minimap.hidden = !showsMap;
    const CGFloat mapWidth = floor(MIN(80, MAX(56, self.bounds.size.width * 0.09)));
    // Legacy scrollers already reserve their own width outside the clip view.
    const NSInteger reserved = showsMap ? (NSInteger)mapWidth : 0;
    if (_minimapReservedWidth != reserved) {
        _minimapReservedWidth = reserved;
        [_scintilla message:SCI_SETMARGINRIGHT wParam:0 lParam:_baseRightPadding + reserved];
    }
    _minimap.frame = NSMakeRect(MAX(0, NSMaxX(track) - width - mapWidth), NSMinY(track), mapWidth, MAX(0, NSHeight(track)));
    if (showsMap) {
        if (wasHidden) [_minimap invalidateContent];
        [_minimap refreshViewport];
    }
    _searchOverview.frame = NSMakeRect(MAX(0, NSMaxX(track) - width), NSMinY(track),
                                       width, MAX(0, NSHeight(track)));
    _searchOverviewNeedsRefresh = YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsLayout = YES;
    _searchOverviewNeedsRefresh = YES;
}

- (BOOL)canEditPreviewColor {
    if (!self.isInputEnabled) return NO;
    for (DPScintillaEditorView *peer in _searchMarkerPeers)
        if (peer.hasMarkedText) return NO;
    return YES;
}
- (void)colorPreviewViewportChanged:(NSNotification *)notification {
    [_minimap refreshViewport];
    [self scheduleWordHighlights:NO];
    [self clearDeclarationHover];
    [self refreshColorPreviews];
}
- (void)refreshColorPreviews {
    const BOOL enabled = !_binaryDocument && !_languageStylingFallback && ![_lexerName isEqualToString:@"null"];
    if ([_scintilla message:SCI_GETMARGINWIDTHN wParam:4] != (enabled ? 16 : 0)) {
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:4 lParam:enabled ? 16 : 0];
    }
    NSInteger x = 0;
    for (int margin = 0; margin < 4; ++margin) x += [_scintilla message:SCI_GETMARGINWIDTHN wParam:margin];
    NSView *ruler = _scintilla.scrollView.verticalRulerView;
    _colorPreview.frame = [self convertRect:NSMakeRect(x, 0, 16, NSHeight(ruler.bounds)) fromView:ruler];
    _colorPreview.hidden = !enabled;
    [_colorPreview refreshWithRevision:_revision enabled:enabled editable:[self canEditPreviewColor]
                             plantUML:[_lexerName isEqualToString:@"plantuml"]];
}
- (NSArray<NSValue *> *)colorPreviewRanges { [self refreshColorPreviews]; return _colorPreview.ranges; }
- (void)configureColorPreviewWithChangeLabel:(NSString *)changeLabel applyLabel:(NSString *)applyLabel {
    _colorPreview.changeColorLabel = changeLabel; _colorPreview.applyLabel = applyLabel;
    [self refreshColorPreviews];
}
- (BOOL)replaceColorInUTF8Range:(NSRange)range withColor:(NSColor *)color expectedRevision:(uint64_t)revision {
    DPScintillaEditorView *publisher = _documentPublisher ?: self;
    if (_revision != revision || publisher.revision != revision || (!_publishesDocumentEdits && !_documentPublisher)
        || ![self canEditPreviewColor] || range.length > 9) return NO;
    NSData *original = [self utf8BytesInRange:range error:nil];
    if (![DPColorPreviewView colorFromHex:original plantUML:[_lexerName isEqualToString:@"plantuml"]]) return NO;
    NSData *replacement = [DPColorPreviewView hexFromColor:color preserving:original plantUML:[_lexerName isEqualToString:@"plantuml"]];
    if ([replacement isEqualToData:original]) return YES;
    [publisher beginGroupedUndo];
    const BOOL result = [publisher applyAggregateUserEditInRange:range selectionOwner:self
        resultingAnchorUTF8:self.anchorUTF8Position resultingCaretUTF8:self.caretUTF8Position
        preserveSelection:YES
        replacementBuilder:^NSData *(NSData *deleted) { return [deleted isEqualToData:original] ? replacement : nil; }];
    [publisher endGroupedUndo];
    [self refreshColorPreviews];
    return result;
}
- (NSArray<NSNumber *> *)searchOverviewPositions { return _searchOverview.positions; }

- (void)resetSearchOverviewDocument {
    [_wordHighlighter removeView:_scintilla];
    _wordHighlighter = [[DPWordOccurrenceHighlighter alloc] init];
    [self attachWordHighlighter];
    [self clearDeclarationHover];
    [_colorPreview closeChooser];
    [_searchMarkerPeers removeObject:self];
    _searchMarkerPeers = [NSHashTable weakObjectsHashTable];
    [_searchMarkerPeers addObject:self];
    _searchHighlightsActive = NO;
    _searchMarkerOffsets = [NSIndexSet indexSet];
    _searchOverview.positions = @[];
    _searchOverviewNeedsRefresh = NO;
}

- (void)navigateToSearchMarker:(NSUInteger)index {
    NSIndexSet *offsets = [self overviewMarkerOffsets];
    if (_binaryDocument || index >= offsets.count) return;
    __block NSUInteger selectedOffset = NSNotFound;
    __block NSUInteger current = 0;
    [offsets enumerateIndexesUsingBlock:^(NSUInteger offset, BOOL *stop) {
        if (current++ == index) { selectedOffset = offset; *stop = YES; }
    }];
    if (selectedOffset == NSNotFound) return;
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:selectedOffset];
    [_scintilla message:SCI_ENSUREVISIBLEENFORCEPOLICY wParam:line];
    if (!_searchHighlightsActive && _wordHighlighter.matchedByteLength > 0) {
        [_scintilla message:SCI_SETSEL wParam:selectedOffset lParam:selectedOffset + _wordHighlighter.matchedByteLength];
    } else {
        [_scintilla message:SCI_GOTOPOS wParam:selectedOffset];
    }
    // SCI_VERTICALCENTRECARET centers the logical line's start, which can
    // scroll a match in a long wrapped line back out of view.
    const NSInteger lineHeight = MAX(1, [_scintilla message:SCI_TEXTHEIGHT wParam:0]);
    const NSInteger caretRow = [_scintilla message:SCI_GETFIRSTVISIBLELINE]
        + [_scintilla message:SCI_POINTYFROMPOSITION wParam:0 lParam:selectedOffset] / lineHeight;
    const NSInteger centeredRow = MAX(0, caretRow - [_scintilla message:SCI_LINESONSCREEN] / 2);
    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:centeredRow];
    _searchOverviewNeedsRefresh = YES;
    [self refreshSearchOverview];
    [self.window makeFirstResponder:[_scintilla content]];
}

- (void)refreshSearchOverview {
    if (!_searchOverviewNeedsRefresh) return;
    _searchOverviewNeedsRefresh = NO;
    NSIndexSet *offsets = [self overviewMarkerOffsets];
    if (offsets.count == 0 || _binaryDocument) {
        _minimap.markerLines = [NSIndexSet indexSet];
        _searchOverview.positions = @[];
        return;
    }
    // The one-past-end document line maps to the total display-line count,
    // including folding/wrapping, without laying out the final document line.
    const NSInteger displayLines = [_scintilla message:SCI_VISIBLEFROMDOCLINE
                                               wParam:[_scintilla message:SCI_GETLINECOUNT]];
    _searchOverviewDisplayLineCount = displayLines;
    // Use the native scroll document extent, including scroll-past-end space
    // and viewport padding, so ticks share the thumb's coordinate system.
    const CGFloat lineHeight = MAX(1, [_scintilla message:SCI_TEXTHEIGHT wParam:0]);
    _searchOverviewDocumentHeight = _scintilla.scrollView.documentView.frame.size.height;
    const CGFloat documentHeight = MAX(lineHeight * displayLines, _searchOverviewDocumentHeight);
    const NSInteger firstVisible = [_scintilla message:SCI_GETFIRSTVISIBLELINE];
    const BOOL wrapping = [_scintilla message:SCI_GETWRAPMODE] != SC_WRAP_NONE;
    const NSInteger cacheLevel = [_scintilla message:SCI_GETLAYOUTCACHE];
    // Clones deliberately use no persistent layout cache. Temporarily keep
    // one line so many matches in a huge wrapped line don't lay it out N times.
    if (wrapping && cacheLevel == SC_CACHE_NONE) [_scintilla message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_CARET];
    NSMutableArray<NSNumber *> *positions = [NSMutableArray arrayWithCapacity:offsets.count];
    NSMutableIndexSet *markerLines = [NSMutableIndexSet indexSet];
    __block NSInteger previousLine = -1, lineStart = 0, lineEnd = 0;
    [offsets enumerateIndexesUsingBlock:^(NSUInteger offset, BOOL *stop) {
        const NSInteger line = [self->_scintilla message:SCI_LINEFROMPOSITION wParam:offset];
        [markerLines addIndex:line];
        if (line != previousLine) {
            previousLine = line;
            lineStart = [self->_scintilla message:SCI_VISIBLEFROMDOCLINE wParam:line];
            lineEnd = [self->_scintilla message:SCI_VISIBLEFROMDOCLINE wParam:line + 1];
        }
        CGFloat displayLine = lineStart;
        if (wrapping && lineEnd - lineStart > 1) {
            const NSInteger y = [self->_scintilla message:SCI_POINTYFROMPOSITION wParam:0 lParam:offset];
            // During idle rewrapping the new character layout may run ahead
            // of native scroll heights. Stay within this line's current span
            // until the next paint updates the map, keeping tick order stable.
            displayLine = MAX(lineStart, MIN(lineEnd - 1, firstVisible + y / lineHeight));
        }
        [positions addObject:@(MIN(1.0, MAX(0, (displayLine + 0.5) * lineHeight / MAX(1, documentHeight))))];
    }];
    if (wrapping && cacheLevel == SC_CACHE_NONE) [_scintilla message:SCI_SETLAYOUTCACHE wParam:cacheLevel];
    _searchOverview.positions = positions;
    _minimap.markerLines = markerLines;
}

- (void)dealloc {
    if (_observedInputMonitor) [NSEvent removeMonitor:_observedInputMonitor];
    [_wordHighlighter removeView:_scintilla];
    [[_scintilla content] unmarkText];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self cancelPendingSmartIndentation];
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil && publisher->_directInputInitiator == self) {
        publisher->_directInputInitiator = nil;
    }
    self.onWillModifyDocument = nil;
    self.onSmartIndentationStateChange = nil;
    _scintilla.delegate = nil;
}

- (void)invalidate {
    if (_observedInputMonitor) [NSEvent removeMonitor:_observedInputMonitor];
    _observedInputMonitor = nil;
    _observedFollowEnd = NO;
    _minimap.scintilla = nil;
    [_minimap removeFromSuperview];
    [_wordHighlighter removeView:_scintilla];
    [[_scintilla content] unmarkText];
    [self clearDeclarationHover];
    self.onDeclarationHovered = nil;
    self.onDeclarationRequested = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_searchMarkerPeers removeObject:self];
    [_searchOverview removeFromSuperview];
    [_colorPreview closeChooser];
    [_colorPreview removeFromSuperview];
    [self cancelPendingSmartIndentation];
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil && publisher->_directInputInitiator == self) {
        publisher->_directInputInitiator = nil;
    }
    _directInputInitiator = nil;
    self.onWillModifyDocument = nil;
    self.onEdit = nil;
    self.onError = nil;
    self.onFocus = nil;
    self.onStatusChange = nil;
    self.onFoldStateChange = nil;
    self.onFoldRecoveryProgress = nil;
    self.onSmartIndentationStateChange = nil;
    _foldRecoveryProgressPending = NO;
    _collapseAllFoldsAfterStyling = NO;
    _documentPublisher = nil;
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    _scintilla.delegate = nil;
    [_scintilla removeFromSuperview];
    _scintilla = nil;
}

- (uint64_t)revision { return _revision; }
- (NSError *)lastMutationError { return _lastMutationError; }
- (NSUInteger)snapshotReadCount { return _snapshotReadCount; }
- (NSUInteger)incrementalNotificationCount { return _incrementalNotificationCount; }
- (NSUInteger)incrementalPayloadByteCount { return _incrementalPayloadByteCount; }
- (NSString *)lexerName { return _lexerName; }
- (BOOL)languageStylingFallback { return _languageStylingFallback; }
- (NSUInteger)languageConfigurationCount { return _languageConfigurationCount; }
- (NSUInteger)commentCommandInspectedByteCount { return _commentCommandInspectedByteCount; }
- (void)asynchronousStylingCompleted:(NSNotification *)notification {
    if ([notification.object pointerValue] != reinterpret_cast<void *>([_scintilla message:SCI_GETDOCPOINTER])) return;
    [_minimap invalidateContent];
    if (_collapseAllFoldsAfterStyling) {
        [self continueCollapseAllFoldsAtLine:0 insideFold:NO generation:++_collapseAllFoldsGeneration];
    }
    [self scheduleFoldRecoveryProgress];
    [self updateBraceHighlight];
    [self refreshColorPreviews];
}
- (BOOL)asynchronousWorkPending {
    return _collapseAllFoldsAfterStyling || self.asynchronousStylingPending;
}
- (BOOL)asynchronousStylingPending {
    if (![_lexerName isEqualToString:@"cpp"] && ![_lexerName isEqualToString:@"css"]
        && ![_lexerName isEqualToString:@"xml"] && ![_lexerName isEqualToString:@"duckpadlog"]) return NO;
    return [_scintilla message:SCI_PRIVATELEXERCALL wParam:DPAsyncLexerPendingOperation lParam:0] != 0;
}
- (NSUInteger)logStyledByteCount {
    DPLogStatistics statistics;
    if ([_lexerName isEqualToString:@"duckpadlog"]) [_scintilla message:SCI_PRIVATELEXERCALL wParam:DPLogStatisticsOperation lParam:reinterpret_cast<sptr_t>(&statistics)];
    return statistics.styledBytes;
}
- (NSUInteger)maximumLogStyleSliceMicroseconds {
    DPLogStatistics statistics;
    if ([_lexerName isEqualToString:@"duckpadlog"]) [_scintilla message:SCI_PRIVATELEXERCALL wParam:DPLogStatisticsOperation lParam:reinterpret_cast<sptr_t>(&statistics)];
    return statistics.maximumSliceMicroseconds;
}
- (NSInteger)ansiForegroundAtUTF8Position:(NSUInteger)position {
    const sptr_t value = [_scintilla message:SCI_INDICATORVALUEAT wParam:DPLogForegroundIndicator lParam:position];
    return value ? value & SC_INDICVALUEMASK : -1;
}
- (NSInteger)ansiBackgroundAtUTF8Position:(NSUInteger)position {
    const sptr_t value = [_scintilla message:SCI_INDICATORVALUEAT wParam:DPLogBackgroundIndicator lParam:position];
    return value ? value & SC_INDICVALUEMASK : -1;
}
- (BOOL)isStyleVisible:(NSInteger)style { return [_scintilla message:SCI_STYLEGETVISIBLE wParam:style] != 0; }
- (NSUInteger)synchronouslyStyledByteCount { return _synchronouslyStyledByteCount; }
- (BOOL)additionalSelectionTyping { return [_scintilla message:SCI_GETADDITIONALSELECTIONTYPING] != 0; }
- (void)setAdditionalSelectionTyping:(BOOL)enabled { [_scintilla message:SCI_SETADDITIONALSELECTIONTYPING wParam:enabled]; }
- (NSString *)insertionLineEnding {
    const sptr_t mode = [_scintilla message:SCI_GETEOLMODE];
    return mode == SC_EOL_CRLF ? @"\r\n" : (mode == SC_EOL_CR ? @"\r" : @"\n");
}
- (NSUInteger)configuredTabWidth { return (NSUInteger)[_scintilla message:SCI_GETTABWIDTH]; }
- (BOOL)configuredUseTabs { return [_scintilla message:SCI_GETUSETABS] != 0; }
- (NSInteger)highlightedBraceUTF8Position { return _highlightedBraceUTF8Position; }
- (NSInteger)matchingBraceUTF8Position { return _matchingBraceUTF8Position; }
- (NSInteger)badBraceUTF8Position { return _badBraceUTF8Position; }
- (BOOL)isCompletionActive { return [_scintilla message:SCI_AUTOCACTIVE] != 0; }
- (NSUInteger)completionItemCount { return _completionItemCount; }

- (NSData *)contentUTF8 {
    _snapshotReadCount += 1;
    const NSInteger length = [_scintilla message:SCI_GETLENGTH];
    NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)length + 1];
    [_scintilla message:SCI_GETTEXT
                 wParam:(uptr_t)bytes.length
                 lParam:(sptr_t)bytes.mutableBytes];
    bytes.length = (NSUInteger)length;
    return bytes;
}

- (NSUInteger)documentByteLength {
    return (NSUInteger)[_scintilla message:SCI_GETLENGTH];
}

- (NSData *)utf8BytesInRange:(NSRange)range error:(NSError **)error {
    const NSUInteger length = (NSUInteger)[_scintilla message:SCI_GETLENGTH];
    if (range.location > length || range.length > length - range.location) {
        [self fail:DPScintillaErrorInvalidRange description:@"UTF-8 byte range is outside the document" error:error];
        return nil;
    }
    const NSUInteger end = range.location + range.length;
    if (![self isUTF8Boundary:range.location documentLength:length]
        || ![self isUTF8Boundary:end documentLength:length]) {
        [self fail:DPScintillaErrorInvalidUTF8Boundary description:@"Range must use UTF-8 code point boundaries" error:error];
        return nil;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:range.length + 1];
    Sci_TextRangeFull textRange = {
        { static_cast<Sci_Position>(range.location), static_cast<Sci_Position>(end) },
        static_cast<char *>(bytes.mutableBytes)
    };
    [_scintilla message:SCI_GETTEXTRANGEFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&textRange)];
    bytes.length = range.length;
    return bytes;
}

- (BOOL)loadUTF8:(NSData *)content revision:(uint64_t)revision error:(NSError **)error {
    return [self loadUTF8:content revision:revision preservingUndo:NO error:error];
}

- (BOOL)isObservedFileFollowingEnd {
    // Idle wrapping changes display-line estimates after a split/resize. Retain
    // explicit Follow intent until a user gesture or selection leaves the end.
    if (_observedFollowEnd && [_scintilla message:SCI_GETSELECTIONEMPTY]
        && [_scintilla message:SCI_GETCURRENTPOS] == self.documentByteLength) return YES;
    const sptr_t rows = [_scintilla message:SCI_VISIBLEFROMDOCLINE wParam:[_scintilla message:SCI_GETLINECOUNT]];
    return [_scintilla message:SCI_GETFIRSTVISIBLELINE] + [_scintilla message:SCI_LINESONSCREEN] >= rows
        && [_scintilla message:SCI_GETSELECTIONEMPTY];
}

- (void)followObservedFileEnd {
    _observedFollowEnd = YES;
    if (!_observedInputMonitor) {
        __weak DPScintillaEditorView *weakSelf = self;
        _observedInputMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            NSEventMaskScrollWheel | NSEventMaskLeftMouseDown | NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                DPScintillaEditorView *view = weakSelf;
                if (!view || !view.window || event.window != view.window) return event;
                const BOOL targetsView = event.type == NSEventTypeKeyDown
                    ? view.hasEditorFocus
                    : NSPointInRect([view convertPoint:event.locationInWindow fromView:nil], view.bounds);
                if (targetsView) view->_observedFollowEnd = NO;
                return event;
            }];
    }
    [_scintilla message:SCI_GOTOPOS wParam:self.documentByteLength];
    [_scintilla message:SCI_SCROLLCARET];
}

- (BOOL)applyObservedUTF8:(NSData *)data revision:(uint64_t)revision reset:(BOOL)reset {
    if (_binaryDocument || _loadingText || data.length > 64 * 1024 || _revision == UINT64_MAX
        || revision != _revision + 1 || [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] == nil) return NO;
    // Shared panes have independent selections and scroll positions.
    NSMutableArray<NSDictionary *> *states = [NSMutableArray array];
    for (DPScintillaEditorView *peer in _searchMarkerPeers) {
        ScintillaView *view = peer->_scintilla;
        const sptr_t first = [view message:SCI_GETFIRSTVISIBLELINE];
        const BOOL follows = peer.isObservedFileFollowingEnd;
        const NSUInteger length = [view message:SCI_GETSELECTIONSERIALIZED];
        std::string selection(length + 1, '\0');
        [view message:SCI_GETSELECTIONSERIALIZED wParam:0 lParam:reinterpret_cast<sptr_t>(selection.data())];
        [states addObject:@{@"peer": peer, @"first": @(first), @"x": @([view message:SCI_GETXOFFSET]),
            @"follow": @(follows), @"selection": [NSData dataWithBytes:selection.data() length:selection.size()]}];
    }
    _suppressEdit = YES;
    [_scintilla setEditable:YES];
    [_scintilla message:SCI_SETUNDOCOLLECTION wParam:0];
    if (reset) [_scintilla message:SCI_CLEARALL];
    if (data.length) [_scintilla message:SCI_APPENDTEXT wParam:data.length lParam:reinterpret_cast<sptr_t>(data.bytes)];
    [_scintilla message:SCI_EMPTYUNDOBUFFER];
    [_scintilla message:SCI_SETSAVEPOINT];
    [_scintilla message:SCI_SETUNDOCOLLECTION wParam:1];
    _revision = revision;
    _suppressEdit = NO;
    [_scintilla setEditable:_requestedInputEnabled && revision != UINT64_MAX];
    for (NSDictionary *state in states) {
        DPScintillaEditorView *peer = state[@"peer"];
        if ([state[@"follow"] boolValue]) [peer followObservedFileEnd];
        else if (!reset) {
            NSData *selection = state[@"selection"];
            [peer->_scintilla message:SCI_SETSELECTIONSERIALIZED wParam:0 lParam:reinterpret_cast<sptr_t>(selection.bytes)];
            [peer->_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:[state[@"first"] integerValue]];
            [peer->_scintilla message:SCI_SETXOFFSET wParam:[state[@"x"] integerValue]];
        }
        [peer->_minimap invalidateContent];
        peer->_searchOverviewNeedsRefresh = YES;
    }
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
    return YES;
}

- (BOOL)loadUTF8:(NSData *)content revision:(uint64_t)revision
   preservingUndo:(BOOL)preservingUndo error:(NSError **)error {
    if ([[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding] == nil) {
        return [self fail:DPScintillaErrorInvalidUTF8 description:@"Content is not valid UTF-8" error:error];
    }
    [[_scintilla content] unmarkText];
    [self cancelPendingSmartIndentation];
    _collapseAllFoldsAfterStyling = NO;
    const BOOL interruptedTextLoad = _loadingText;
    // An incomplete preview has no user edits and must never become an undo target.
    if (interruptedTextLoad) preservingUndo = NO;
    _loadingText = NO;
    _suppressEdit = YES;
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    if (_binaryDocument) {
        // StylesNone cannot be changed in place; text reload needs a regular document.
        [self resetSearchOverviewDocument];
        [_scintilla message:SCI_SETDOCPOINTER wParam:0 lParam:0];
        [_scintilla message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_NONE];
        [_scintilla message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        // Maintain the index while loading/editing, before Cocoa's input manager
        // can ask for document-wide UTF-16 coordinates on every key event.
        [_scintilla message:SCI_ALLOCATELINECHARACTERINDEX wParam:SC_LINECHARACTERINDEX_UTF16];
        [_scintilla message:SCI_SETUNDOSELECTIONHISTORY wParam:SC_UNDO_SELECTION_HISTORY_ENABLED];
        _binaryDocument = NO;
        [self updateModificationEventMask];
    }
    [_scintilla setEditable:YES];
    if (!preservingUndo) [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [_scintilla message:SCI_SETMARGINWIDTHN wParam:3 lParam:3];
    [_scintilla message:SCI_SETEOLMODE wParam:DPEOLModeForUTF8(content)];
    if (!preservingUndo || ![content isEqualToData:self.contentUTF8]) {
        const BOOL collectingUndo = interruptedTextLoad || [_scintilla message:SCI_GETUNDOCOLLECTION] != 0;
        if (preservingUndo) [_scintilla message:SCI_BEGINUNDOACTION];
        else [_scintilla message:SCI_SETUNDOCOLLECTION wParam:0];
        [_scintilla message:SCI_CLEARALL];
        if (content.length > 0) {
            // Scintilla's first bulk insertion otherwise leaves only eight
            // spare bytes. The first few keystrokes then reallocate/copy both
            // the text and style buffers (gigabytes for a large file).
            constexpr NSUInteger editingReserve = 64 * 1024;
            if (!preservingUndo && content.length <= NSIntegerMax - editingReserve) {
                [_scintilla message:SCI_ALLOCATE wParam:content.length + editingReserve];
            }
            [_scintilla message:SCI_ADDTEXT
                         wParam:(uptr_t)content.length
                         lParam:(sptr_t)content.bytes];
        }
        if (preservingUndo) [_scintilla message:SCI_ENDUNDOACTION];
        else [_scintilla message:SCI_SETUNDOCOLLECTION wParam:collectingUndo];
    }
    if (!preservingUndo) {
        [_scintilla message:SCI_EMPTYUNDOBUFFER];
        [_scintilla message:SCI_SETSAVEPOINT];
        [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
    }
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
    _suppressEdit = NO;
    _revision = revision;
    _lastSearchWasZeroLength = NO;
    _completionItemCount = 0;
    [_scintilla setEditable:_requestedInputEnabled && revision != UINT64_MAX];
    _lastMutationError = nil;
    [_minimap invalidateContent];
    self.needsLayout = YES;
    [self scheduleWordHighlights:YES];
    return YES;
}

- (BOOL)beginTextLoad:(NSData *)initial totalByteCount:(NSUInteger)total
             revision:(uint64_t)revision error:(NSError **)error {
    if (total < initial.length || total > static_cast<NSUInteger>(PTRDIFF_MAX) - 64 * 1024) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Invalid text load size" error:error];
    }
    if (![self loadUTF8:initial revision:revision error:error]) return NO;
    _loadingText = YES;
    self.needsLayout = YES;
    [self scheduleWordHighlights:NO];
    _loadingTextTotal = total;
    _loadingTextHasEOL = memchr(initial.bytes, '\r', initial.length) || memchr(initial.bytes, '\n', initial.length);
    [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [_scintilla message:SCI_SETUNDOCOLLECTION wParam:0];
    [_scintilla message:SCI_ALLOCATE wParam:total + 64 * 1024];
    [_scintilla setEditable:NO];
    return YES;
}

- (BOOL)appendTextLoadChunk:(NSData *)chunk atOffset:(NSUInteger)offset
                    final:(BOOL)final error:(NSError **)error {
    if (!_loadingText || offset != self.documentByteLength || offset > _loadingTextTotal
        || chunk.length > _loadingTextTotal - offset
        || final != (offset + chunk.length == _loadingTextTotal)
        || [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding] == nil) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Invalid text load chunk" error:error];
    }
    if (!_loadingTextHasEOL && (memchr(chunk.bytes, '\r', chunk.length) || memchr(chunk.bytes, '\n', chunk.length))) {
        [_scintilla message:SCI_SETEOLMODE wParam:DPEOLModeForUTF8(chunk)];
        _loadingTextHasEOL = YES;
    }
    _suppressEdit = YES;
    [_scintilla setEditable:YES];
    [_scintilla message:SCI_APPENDTEXT wParam:chunk.length lParam:(sptr_t)chunk.bytes];
    [_scintilla setEditable:NO];
    _suppressEdit = NO;
    if (self.documentByteLength != offset + chunk.length) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Incomplete text load" error:error];
    }
    if (final) {
        _loadingText = NO;
        [_minimap invalidateContent];
        self.needsLayout = YES;
        [self scheduleWordHighlights:NO];
        [_scintilla message:SCI_SETUNDOCOLLECTION wParam:1];
        [_scintilla message:SCI_EMPTYUNDOBUFFER];
        [_scintilla message:SCI_SETSAVEPOINT];
        [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
        [_scintilla setEditable:_requestedInputEnabled && _revision != UINT64_MAX];
    }
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
    _statusContentGeneration += 1;
    if (self.onStatusChange) self.onStatusChange();
    return YES;
}

- (void)loadBinaryDocument:(DPScintillaBinaryDocument *)document revision:(uint64_t)revision {
    [self cancelPendingSmartIndentation];
    _loadingText = NO;
    [self resetSearchOverviewDocument];
    _suppressEdit = YES;
    _binaryDocument = YES;
    self.needsLayout = YES;
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    _smartEditingEnabled = NO;
    _plainTextIndentationEnabled = NO;
    _braceMatchingEnabled = NO;
    _foldingEnabled = NO;
    _foldRecoveryProgressPending = NO;
    _collapseAllFoldsAfterStyling = NO;
    [self updateModificationEventMask];
    [_scintilla message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
    [_scintilla message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_PAGE];
    [_scintilla message:SCI_SETUNDOSELECTIONHISTORY wParam:SC_UNDO_SELECTION_HISTORY_DISABLED];
    [document attachToScintillaView:_scintilla];
    [_scintilla message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [_scintilla message:SCI_SETMARGINWIDTHN wParam:3 lParam:0];
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
    [_scintilla setEditable:NO];
    _revision = revision;
    _lastSearchWasZeroLength = NO;
    _completionItemCount = 0;
    _lastMutationError = nil;
    _lexerName = @"null";
    _languageStylingFallback = NO;
    _statusContentGeneration += 1;
    _suppressEdit = NO;
}

- (BOOL)appendBinaryDocumentChunk:(DPScintillaBinaryDocument *)document
                    maximumBytes:(NSUInteger)maximumBytes error:(NSError **)error {
    if (!_binaryDocument || maximumBytes == 0 || ![document isAttachedToScintillaView:_scintilla]) {
        return [self fail:DPScintillaErrorInvalidRange
               description:@"Binary chunk requires its attached document and a positive byte count" error:error];
    }
    const BOOL complete = [document appendMaximumBytes:maximumBytes error:error];
    if (self.onStatusChange) self.onStatusChange();
    return complete;
}

- (BOOL)showCompletionItems:(NSArray<NSString *> *)items
   replacingPrefixByteCount:(NSUInteger)prefixByteCount {
    if (!_requestedInputEnabled || self.hasMarkedText || items.count == 0 || items.count > 200) {
        [self cancelCompletion];
        return NO;
    }
    const NSUInteger caret = self.caretUTF8Position;
    if (prefixByteCount > caret) {
        [self cancelCompletion];
        return NO;
    }
    NSMutableArray<NSString *> *validated = [NSMutableArray arrayWithCapacity:items.count];
    for (NSString *item in items) {
        if (item.length == 0 || [item rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound
            || [item dataUsingEncoding:NSUTF8StringEncoding] == nil) {
            [self cancelCompletion];
            return NO;
        }
        [validated addObject:item];
    }
    NSString *list = [validated componentsJoinedByString:@"\n"];
    [_scintilla message:SCI_AUTOCSETSEPARATOR wParam:'\n'];
    [_scintilla message:SCI_AUTOCSETIGNORECASE wParam:1];
    [_scintilla message:SCI_AUTOCSETCHOOSESINGLE wParam:0];
    [_scintilla message:SCI_AUTOCSETAUTOHIDE wParam:1];
    [_scintilla message:SCI_AUTOCSETDROPRESTOFWORD wParam:1];
    [_scintilla message:SCI_AUTOCSETOPTIONS wParam:SC_AUTOCOMPLETE_SELECT_FIRST_ITEM];
    [_scintilla message:SCI_AUTOCSETMAXHEIGHT wParam:12];
    [_scintilla message:SCI_AUTOCSETMAXWIDTH wParam:48];
    [_scintilla message:SCI_AUTOCSHOW
                 wParam:(uptr_t)prefixByteCount
                 lParam:(sptr_t)list.UTF8String];
    _completionItemCount = validated.count;
    return self.isCompletionActive;
}

- (void)cancelCompletion {
    if (_scintilla != nil) [_scintilla message:SCI_AUTOCCANCEL];
    _completionItemCount = 0;
}

- (BOOL)replaceUTF8Range:(NSRange)range
         withReplacement:(NSData *)replacement
        expectedRevision:(uint64_t)expectedRevision
       resultingRevision:(uint64_t)resultingRevision
                    error:(NSError **)error {
    if ([_scintilla message:SCI_GETREADONLY] != 0) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Document is read-only" error:error];
    }
    if (expectedRevision != _revision) {
        return [self fail:DPScintillaErrorStaleRevision description:@"Expected revision is stale" error:error];
    }
    if (_revision == UINT64_MAX || resultingRevision != _revision + 1) {
        return [self fail:DPScintillaErrorRevisionOverflow description:@"Result revision must advance exactly once" error:error];
    }
    if ([[NSString alloc] initWithData:replacement encoding:NSUTF8StringEncoding] == nil) {
        return [self fail:DPScintillaErrorInvalidUTF8 description:@"Replacement is not valid UTF-8" error:error];
    }
    const NSUInteger length = (NSUInteger)[_scintilla message:SCI_GETLENGTH];
    if (range.location > length || range.length > length - range.location) {
        return [self fail:DPScintillaErrorInvalidRange description:@"UTF-8 byte range is outside the document" error:error];
    }
    const NSUInteger end = range.location + range.length;
    if (![self isUTF8Boundary:range.location documentLength:length]
        || ![self isUTF8Boundary:end documentLength:length]) {
        return [self fail:DPScintillaErrorInvalidUTF8Boundary
               description:@"Range must start and end on UTF-8 code point boundaries"
                     error:error];
    }
    _suppressEdit = YES;
    [_scintilla message:SCI_SETTARGETSTART wParam:(uptr_t)range.location];
    [_scintilla message:SCI_SETTARGETEND wParam:(uptr_t)NSMaxRange(range)];
    static const char emptyReplacement = '\0';
    const void *replacementBytes = replacement.length > 0 ? replacement.bytes : &emptyReplacement;
    [_scintilla message:SCI_REPLACETARGET
                 wParam:(uptr_t)replacement.length
                 lParam:(sptr_t)replacementBytes];
    if (_foldingEnabled && !_deferReplacementStyling) {
        const NSInteger changedLine = [_scintilla message:SCI_LINEFROMPOSITION
                                                    wParam:(uptr_t)range.location];
        const NSInteger lineStart = [_scintilla message:SCI_POSITIONFROMLINE
                                                  wParam:(uptr_t)changedLine];
        const NSInteger nextLineStart = changedLine + 1 < (NSInteger)self.lineCount
            ? [_scintilla message:SCI_POSITIONFROMLINE wParam:(uptr_t)(changedLine + 1)]
            : (NSInteger)self.documentByteLength;
        [_scintilla message:SCI_COLOURISE wParam:(uptr_t)lineStart lParam:nextLineStart];
        _synchronouslyStyledByteCount += nextLineStart - lineStart;
    }
    _suppressEdit = NO;
    _revision = resultingRevision;
    return YES;
}

- (BOOL)replaceUTF8Ranges:(NSArray<NSValue *> *)ranges
         withReplacements:(NSArray<NSData *> *)replacements
          expectedRevision:(uint64_t)expectedRevision
                     error:(NSError **)error {
    if (ranges.count != replacements.count) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Batch ranges and replacements differ" error:error];
    }
    if ([_scintilla message:SCI_GETREADONLY] != 0) {
        return [self fail:DPScintillaErrorInvalidRange description:@"Document is read-only" error:error];
    }
    if (expectedRevision != _revision) {
        return [self fail:DPScintillaErrorStaleRevision description:@"Expected batch revision is stale" error:error];
    }
    if ((uint64_t)ranges.count > UINT64_MAX - _revision) {
        return [self fail:DPScintillaErrorRevisionOverflow description:@"Batch exhausts document revision" error:error];
    }
    const NSUInteger documentLength = self.documentByteLength;
    NSUInteger previousLocation = documentLength;
    for (NSUInteger index = 0; index < ranges.count; index += 1) {
        const NSRange range = ranges[index].rangeValue;
        NSData *replacement = replacements[index];
        if (range.location > documentLength || range.length > documentLength - range.location
            || NSMaxRange(range) > previousLocation) {
            return [self fail:DPScintillaErrorInvalidRange description:@"Batch ranges must be descending and non-overlapping" error:error];
        }
        if (![self isUTF8Boundary:range.location documentLength:documentLength]
            || ![self isUTF8Boundary:NSMaxRange(range) documentLength:documentLength]) {
            return [self fail:DPScintillaErrorInvalidUTF8Boundary description:@"Batch range splits UTF-8" error:error];
        }
        if ([[NSString alloc] initWithData:replacement encoding:NSUTF8StringEncoding] == nil) {
            return [self fail:DPScintillaErrorInvalidUTF8 description:@"Batch replacement is not UTF-8" error:error];
        }
        previousLocation = range.location;
    }
    const BOOL wasDeferringStyling = _deferReplacementStyling;
    _deferReplacementStyling = YES;
    [_scintilla message:SCI_BEGINUNDOACTION];
    BOOL succeeded = YES;
    for (NSUInteger index = 0; index < ranges.count; index += 1) {
        const NSRange range = ranges[index].rangeValue;
        NSData *replacement = replacements[index];
        if (![self replaceUTF8Range:range
                    withReplacement:replacement
                   expectedRevision:_revision
                  resultingRevision:_revision + 1
                               error:error]) {
            succeeded = NO;
            break;
        }
    }
    [_scintilla message:SCI_ENDUNDOACTION];
    _deferReplacementStyling = wasDeferringStyling;
    if (_foldingEnabled && !wasDeferringStyling && ranges.count > 0) {
        // Descending edits keep the lowest original position stable. Refresh
        // lexer/fold state once after the batch, not for every whitespace edit.
        const NSUInteger start = MIN(ranges.lastObject.rangeValue.location, self.documentByteLength);
        const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:start];
        const NSInteger lineStart = [_scintilla message:SCI_POSITIONFROMLINE wParam:line];
        [_scintilla message:SCI_COLOURISE wParam:lineStart lParam:-1];
        _synchronouslyStyledByteCount += self.documentByteLength - lineStart;
    }
    return succeeded;
}

- (NSRange)searchUTF8:(NSData *)pattern
            backwards:(BOOL)backwards
            matchCase:(BOOL)matchCase
            wholeWord:(BOOL)wholeWord
    regularExpression:(BOOL)regularExpression
       restrictToRange:(NSRange)restriction
            wrapAround:(BOOL)wrapAround
                 error:(NSError **)error {
    if (pattern.length == 0) {
        [self fail:DPScintillaErrorInvalidRange description:@"Search pattern is empty" error:error];
        return NSMakeRange(NSNotFound, 0);
    }
    if ([[NSString alloc] initWithData:pattern encoding:NSUTF8StringEncoding] == nil) {
        [self fail:DPScintillaErrorInvalidUTF8 description:@"Search pattern is not valid UTF-8" error:error];
        return NSMakeRange(NSNotFound, 0);
    }
    const NSUInteger documentLength = self.documentByteLength;
    const BOOL restricted = restriction.location != NSNotFound;
    if (restricted && (restriction.location > documentLength
        || restriction.length > documentLength - restriction.location)) {
        [self fail:DPScintillaErrorInvalidRange description:@"Search range is outside the document" error:error];
        return NSMakeRange(NSNotFound, 0);
    }
    const NSUInteger lower = restricted ? restriction.location : 0;
    const NSUInteger upper = restricted ? NSMaxRange(restriction) : documentLength;
    const NSUInteger anchor = MIN(self.anchorUTF8Position, documentLength);
    const NSUInteger caret = MIN(self.caretUTF8Position, documentLength);
    NSUInteger start = backwards ? MIN(anchor, caret) : MAX(anchor, caret);
    start = MIN(MAX(start, lower), upper);
    if (_lastSearchWasZeroLength && _lastSearchBackwards == backwards
        && [_lastSearchPattern isEqualToData:pattern]
        && start == _lastZeroLengthSearchPosition) {
        const NSInteger advanced = [_scintilla message:backwards ? SCI_POSITIONBEFORE : SCI_POSITIONAFTER
                                                  wParam:(uptr_t)start];
        if (advanced >= (NSInteger)lower && advanced <= (NSInteger)upper) {
            start = (NSUInteger)advanced;
        }
    }
    int flags = 0;
    if (matchCase) flags |= SCFIND_MATCHCASE;
    if (wholeWord) flags |= SCFIND_WHOLEWORD;
    if (regularExpression) flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    [_scintilla message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    const auto run = ^NSInteger(NSUInteger from, NSUInteger to) {
        [_scintilla message:SCI_SETTARGETSTART wParam:(uptr_t)from];
        [_scintilla message:SCI_SETTARGETEND wParam:(uptr_t)to];
        return [_scintilla message:SCI_SEARCHINTARGET
                             wParam:(uptr_t)pattern.length
                             lParam:(sptr_t)pattern.bytes];
    };
    NSInteger found = backwards ? run(start, lower) : run(start, upper);
    if (found < 0 && wrapAround) {
        found = backwards ? run(upper, start) : run(lower, start);
    }
    if (found < 0) {
        _lastSearchWasZeroLength = NO;
        return NSMakeRange(NSNotFound, 0);
    }
    const NSUInteger resultStart = (NSUInteger)[_scintilla message:SCI_GETTARGETSTART];
    const NSUInteger resultEnd = (NSUInteger)[_scintilla message:SCI_GETTARGETEND];
    _lastSearchPattern = [pattern copy];
    _lastSearchBackwards = backwards;
    _lastSearchWasZeroLength = resultStart == resultEnd;
    _lastZeroLengthSearchPosition = resultStart;
    return NSMakeRange(resultStart, resultEnd - resultStart);
}

- (BOOL)isInputEnabled { return [_scintilla isEditable]; }
- (void)setInputEnabled:(BOOL)value {
    if (!value) [self clearDeclarationHover];
    _requestedInputEnabled = value;
    [_scintilla setEditable:value && !_binaryDocument && !_loadingText && _revision != UINT64_MAX];
}
- (BOOL)isWordWrapEnabled { return [_scintilla message:SCI_GETWRAPMODE] != SC_WRAP_NONE; }
- (void)setWordWrapEnabled:(BOOL)value {
    [_scintilla message:SCI_SETWRAPMODE wParam:value && !_binaryDocument ? SC_WRAP_WORD : SC_WRAP_NONE];
    _searchOverviewNeedsRefresh = YES;
}
- (BOOL)isWrapMarkerVisible {
    return [_scintilla message:SCI_GETWRAPVISUALFLAGS] != SC_WRAPVISUALFLAG_NONE;
}
- (void)setWrapMarkerVisible:(BOOL)value {
    const uptr_t flags = value
        ? SC_WRAPVISUALFLAG_START | SC_WRAPVISUALFLAG_END
        : SC_WRAPVISUALFLAG_NONE;
    [_scintilla message:SCI_SETWRAPVISUALFLAGS wParam:flags];
}
- (BOOL)isWhitespaceVisible { return [_scintilla message:SCI_GETVIEWWS] != SCWS_INVISIBLE; }
- (void)setWhitespaceVisible:(BOOL)visible {
    [_scintilla message:SCI_SETVIEWWS wParam:visible ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
}
- (BOOL)areLineEndingsVisible { return [_scintilla message:SCI_GETVIEWEOL] != 0; }
- (void)setLineEndingsVisible:(BOOL)visible { [_scintilla message:SCI_SETVIEWEOL wParam:visible]; }
- (NSString *)editorFontName { return _editorFontName; }
- (double)editorFontSize { return _editorFontSize; }

- (NSInteger)editorLeftPadding { return [_scintilla message:SCI_GETMARGINLEFT]; }
- (NSInteger)editorRightPadding { return _baseRightPadding; }
- (BOOL)isCaretWordHighlightEnabled { return _caretWordHighlightEnabled; }
- (void)setCaretWordHighlightEnabled:(BOOL)value {
    if (_caretWordHighlightEnabled == value) return;
    _caretWordHighlightEnabled = value;
    [self scheduleWordHighlights:YES];
}

- (BOOL)isMinimapVisible { return _minimapVisible; }
- (void)setMinimapVisible:(BOOL)visible {
    _minimapVisible = visible;
    self.needsLayout = YES;
}
- (void)setMinimapNavigationLabel:(NSString *)label { _minimap.navigationLabel = label; }
- (NSString *)minimapNavigationLabel { return _minimap.navigationLabel; }
- (NSInteger)editorLineSpacing {
    return [_scintilla message:SCI_GETEXTRAASCENT] + [_scintilla message:SCI_GETEXTRADESCENT];
}

- (void)configureTextLayoutWithLeftPadding:(NSInteger)leftPadding
                            rightPadding:(NSInteger)rightPadding
                             lineSpacing:(NSInteger)lineSpacing {
    const NSInteger spacing = MIN(MAX(lineSpacing, 0), 20);
    [_scintilla message:SCI_SETMARGINLEFT wParam:0 lParam:MIN(MAX(leftPadding, 0), 32)];
    _baseRightPadding = MIN(MAX(rightPadding, 0), 32);
    [_scintilla message:SCI_SETMARGINRIGHT wParam:0 lParam:_baseRightPadding + _minimapReservedWidth];
    // Split the extra line height around the font's normal metrics.
    [_scintilla message:SCI_SETEXTRAASCENT wParam:spacing / 2 lParam:0];
    [_scintilla message:SCI_SETEXTRADESCENT wParam:spacing - spacing / 2 lParam:0];
}
- (void)configureEditorFont:(NSString *)name size:(double)size {
    double boundedSize = std::isfinite(size) ? std::round(MAX(6.0, MIN(72.0, size)) * 100.0) / 100.0 : 13.0;
    NSFont *font = [NSFont fontWithName:name size:boundedSize] ?: [NSFont fontWithName:@"Menlo" size:boundedSize];
    NSString *resolved = font.fontName ?: @"Menlo";
    if ([_editorFontName isEqualToString:resolved] && _editorFontSize == boundedSize) return;
    _editorFontName = [resolved copy];
    _editorFontSize = boundedSize;
    // Change only typography: preserve token colours, documents, undo and zoom.
    for (int style = 0; style <= STYLE_MAX; ++style) {
        [_scintilla message:SCI_STYLESETFONT wParam:style lParam:reinterpret_cast<sptr_t>(_editorFontName.UTF8String)];
        [_scintilla message:SCI_STYLESETSIZEFRACTIONAL wParam:style lParam:std::lround(_editorFontSize * 100)];
    }
    [_scintilla message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_LINENUMBER lParam:std::lround(MAX(6.0, _editorFontSize - 2) * 100)];
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
}

- (void)updateLineNumberMargin:(BOOL)visible {
    const std::string digits(std::max<size_t>(5, std::to_string(self.lineCount).size()), '9');
    const sptr_t width = visible
        ? [_scintilla message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER
                       lParam:reinterpret_cast<sptr_t>(digits.c_str())] + 8
        : 0;
    if ([_scintilla message:SCI_GETMARGINWIDTHN wParam:0] != width) {
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:0 lParam:width];
    }
    _searchOverviewNeedsRefresh = YES;
}

- (NSInteger)zoomLevel { return [_scintilla message:SCI_GETZOOM]; }
- (void)setZoomLevel:(NSInteger)level {
    [_scintilla message:SCI_SETZOOM wParam:(uptr_t)MAX(-10, MIN(20, level))];
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
}
- (NSUInteger)lineCount { return (NSUInteger)MAX(1, [_scintilla message:SCI_GETLINECOUNT]); }
- (BOOL)overtype { return [_scintilla message:SCI_GETOVERTYPE] != 0; }
- (void)setOvertype:(BOOL)value {
    [_scintilla message:SCI_SETOVERTYPE wParam:value];
    if (self.onStatusChange) self.onStatusChange();
}
- (NSUInteger)selectedCharacterCount {
    std::vector<std::pair<NSInteger, NSInteger>> ranges;
    const NSInteger selections = [_scintilla message:SCI_GETSELECTIONS];
    for (NSInteger index = 0; index < selections; ++index) {
        const NSInteger start = [_scintilla message:SCI_GETSELECTIONNSTART wParam:index];
        const NSInteger end = [_scintilla message:SCI_GETSELECTIONNEND wParam:index];
        if (end > start) ranges.emplace_back(start, end);
    }
    if (_selectedCountGeneration != _statusContentGeneration || ranges != _countedSelections) {
        _selectedCharacterCount = 0;
        for (const auto &range : ranges) {
            _selectedCharacterCount += _binaryDocument ? range.second - range.first
                : [_scintilla message:SCI_COUNTCHARACTERS wParam:range.first lParam:range.second];
        }
        _selectedCountGeneration = _statusContentGeneration;
        _countedSelections = std::move(ranges);
    }
    return _selectedCharacterCount;
}
- (NSUInteger)selectedLineCount {
    NSUInteger count = 0;
    const NSInteger selections = [_scintilla message:SCI_GETSELECTIONS];
    for (NSInteger index = 0; index < selections; ++index) {
        const NSInteger start = [_scintilla message:SCI_GETSELECTIONNSTART wParam:index];
        const NSInteger end = [_scintilla message:SCI_GETSELECTIONNEND wParam:index];
        if (end > start) {
            count += [_scintilla message:SCI_LINEFROMPOSITION wParam:end - 1]
                   - [_scintilla message:SCI_LINEFROMPOSITION wParam:start] + 1;
        }
    }
    return count;
}
- (NSUInteger)caretLine {
    return (NSUInteger)MAX(0, [_scintilla message:SCI_LINEFROMPOSITION wParam:self.caretUTF8Position]);
}
- (NSUInteger)caretColumn {
    if (_binaryDocument) {
        const NSUInteger position = self.caretUTF8Position;
        const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:position];
        return position - [_scintilla message:SCI_POSITIONFROMLINE wParam:line];
    }
    return (NSUInteger)MAX(0, [_scintilla message:SCI_GETCOLUMN wParam:self.caretUTF8Position]);
}
- (BOOL)goToOneBasedLine:(NSUInteger)line column:(NSUInteger)column {
    if (line == 0 || column == 0 || line > self.lineCount) return NO;
    const NSInteger target = [_scintilla message:SCI_FINDCOLUMN wParam:line - 1 lParam:column - 1];
    if (target < 0) return NO;
    [_scintilla message:SCI_GOTOPOS wParam:(uptr_t)target];
    [_scintilla message:SCI_SCROLLCARET];
    return YES;
}
- (BOOL)goToUTF8Offset:(NSUInteger)offset {
    const NSUInteger length = self.documentByteLength;
    if (offset > length) return NO;
    if (offset > 0 && offset < length) {
        const NSInteger boundary = [_scintilla message:SCI_POSITIONAFTER wParam:offset - 1];
        if ((NSUInteger)MAX(0, boundary) != offset) return NO;
    }
    [_scintilla message:SCI_GOTOPOS wParam:offset];
    [_scintilla message:SCI_SCROLLCARET];
    return YES;
}
- (NSData *)pasteSelectionIdentity {
    const NSUInteger length = [_scintilla message:SCI_GETSELECTIONSERIALIZED];
    std::string selection(length + 1, '\0');
    [_scintilla message:SCI_GETSELECTIONSERIALIZED wParam:0
                lParam:reinterpret_cast<sptr_t>(selection.data())];
    return [NSData dataWithBytes:selection.data() length:length];
}

- (NSUInteger)selectionCount { return (NSUInteger)[_scintilla message:SCI_GETSELECTIONS]; }
- (NSUInteger)caretUTF8Position { return (NSUInteger)[_scintilla message:SCI_GETCURRENTPOS]; }
- (NSUInteger)anchorUTF8Position { return (NSUInteger)[_scintilla message:SCI_GETANCHOR]; }
- (NSUInteger)firstVisibleLine { return (NSUInteger)[_scintilla message:SCI_GETFIRSTVISIBLELINE]; }
- (NSUInteger)horizontalScrollOffset { return (NSUInteger)[_scintilla message:SCI_GETXOFFSET]; }
- (NSArray<NSNumber *> *)bookmarkedLines {
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    NSInteger line = [_scintilla message:SCI_MARKERNEXT wParam:0 lParam:DPBookmarkMask];
    while (line >= 0) {
        [result addObject:@(line)];
        line = [_scintilla message:SCI_MARKERNEXT wParam:(uptr_t)line + 1 lParam:DPBookmarkMask];
    }
    return result;
}

- (void)restoreBookmarkedLines:(NSArray<NSNumber *> *)lines {
    [_scintilla message:SCI_MARKERDELETEALL wParam:DPBookmarkMarker];
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    for (NSNumber *value in lines) {
        const NSInteger line = value.integerValue;
        if (line >= 0 && line < lineCount) {
            [_scintilla message:SCI_MARKERADD wParam:(uptr_t)line lParam:DPBookmarkMarker];
        }
    }
}

- (void)toggleBookmarkAtCaret {
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:self.caretUTF8Position];
    const NSInteger markers = [_scintilla message:SCI_MARKERGET wParam:(uptr_t)line];
    if ((markers & DPBookmarkMask) != 0) {
        [_scintilla message:SCI_MARKERDELETE wParam:(uptr_t)line lParam:DPBookmarkMarker];
    } else {
        [_scintilla message:SCI_MARKERADD wParam:(uptr_t)line lParam:DPBookmarkMarker];
    }
}

- (BOOL)navigateToBookmarkForward:(BOOL)forward {
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    if (lineCount <= 0) return NO;
    const NSInteger current = [_scintilla message:SCI_LINEFROMPOSITION wParam:self.caretUTF8Position];
    NSInteger target = -1;
    if (forward) {
        target = [_scintilla message:SCI_MARKERNEXT
                              wParam:(uptr_t)MIN(current + 1, lineCount)
                              lParam:DPBookmarkMask];
    } else if (current > 0) {
        target = [_scintilla message:SCI_MARKERPREVIOUS
                              wParam:(uptr_t)current - 1
                              lParam:DPBookmarkMask];
    }
    if (target < 0) {
        target = forward
            ? [_scintilla message:SCI_MARKERNEXT wParam:0 lParam:DPBookmarkMask]
            : [_scintilla message:SCI_MARKERPREVIOUS wParam:(uptr_t)lineCount - 1 lParam:DPBookmarkMask];
    }
    if (target < 0) return NO;
    [_scintilla message:SCI_GOTOLINE wParam:(uptr_t)target];
    [_scintilla message:SCI_SCROLLCARET];
    return YES;
}

- (void)clearBookmarks {
    [_scintilla message:SCI_MARKERDELETEALL wParam:DPBookmarkMarker];
}

- (void)updateModificationEventMask {
    if (_binaryDocument) {
        // Every pane needs fresh layout/cache state, but binary appends never become user edits.
        [_scintilla message:SCI_SETMODEVENTMASK wParam:SC_MOD_BEFOREINSERT | SC_MOD_INSERTTEXT];
        return;
    }
    uptr_t mask = _publishesDocumentEdits
        ? SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_MOD_CONTAINER
            | SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE
        : 0;
    if (_smartEditingEnabled || _plainTextIndentationEnabled) mask |= SC_MOD_INSERTCHECK;
    [_scintilla message:SCI_SETMODEVENTMASK wParam:mask];
}

- (void)shareDocumentWithView:(DPScintillaEditorView *)source {
    if (source == nil || source == self) return;
    [_wordHighlighter removeView:_scintilla];
    _wordHighlighter = source->_wordHighlighter;
    [self clearDeclarationHover];
    _collapseAllFoldsAfterStyling = NO;
    [_searchMarkerPeers removeObject:self];
    _searchMarkerPeers = source->_searchMarkerPeers;
    [_searchMarkerPeers addObject:self];
    _searchMarkerOffsets = source->_searchMarkerOffsets;
    _searchHighlightsActive = source->_searchHighlightsActive;
    _binaryDocument = source->_binaryDocument;
    _loadingText = source->_loadingText;
    [_scintilla message:SCI_SETLAYOUTCACHE wParam:_binaryDocument ? SC_CACHE_PAGE : SC_CACHE_NONE];
    [_scintilla message:SCI_SETUNDOSELECTIONHISTORY
                 wParam:_binaryDocument ? SC_UNDO_SELECTION_HISTORY_DISABLED : SC_UNDO_SELECTION_HISTORY_ENABLED];
    if (_binaryDocument) [_scintilla message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
    const sptr_t document = [source->_scintilla message:SCI_GETDOCPOINTER];
    [_scintilla message:SCI_SETDOCPOINTER wParam:0 lParam:document];
    [_scintilla message:SCI_SETCHANGEHISTORY wParam:(_binaryDocument || _loadingText) ? SC_CHANGE_HISTORY_DISABLED
        : SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
    [_scintilla message:SCI_SETMARGINWIDTHN wParam:3 lParam:_binaryDocument ? 0 : 3];
    [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
    _statusContentGeneration += 1;
    // The primary view remains the sole document-modification observer. A
    // shared document notifies every attached Scintilla view, so enabling this
    // mask here would publish each edit twice to Application.
    _publishesDocumentEdits = NO;
    _documentPublisher = source;
    [self updateModificationEventMask];
    [self synchronizeRevision:source.revision];
    [self attachWordHighlighter];
    [_minimap invalidateContent];
    self.needsLayout = YES;
    _searchOverviewNeedsRefresh = YES;
    [self refreshSearchOverview];
}

- (void)synchronizeRevision:(uint64_t)revision {
    if (_revision != revision) [self clearDeclarationHover];
    _revision = revision;
    if (_documentPublisher != nil) _loadingText = _documentPublisher->_loadingText;
    [_scintilla setEditable:_requestedInputEnabled && !_binaryDocument && !_loadingText && revision != UINT64_MAX];
}
- (void)publishMetadataToken:(NSInteger)token origin:(DPScintillaEditOrigin)origin {
    const uint64_t base = _revision;
    _revision += 1;
    if (_revision == UINT64_MAX) [_scintilla setEditable:NO];
    DPScintillaEdit *edit = [[DPScintillaEdit alloc] initWithRange:NSMakeRange(0, 0)
        insertedUTF8:[NSData data] deletedUTF8:[NSData data]
        baseRevision:base resultingRevision:_revision origin:origin];
    edit.metadataToken = token;
    if (self.onEdit) self.onEdit(edit);
    if (self.onStatusChange) self.onStatusChange();
}

- (void)beginMetadataReload:(NSInteger)token {
    [_scintilla message:SCI_BEGINUNDOACTION];
    [_scintilla message:SCI_ADDUNDOACTION wParam:token lParam:0];
}
- (void)endMetadataReload { [_scintilla message:SCI_ENDUNDOACTION]; }

- (BOOL)addMetadataUndoAction:(NSInteger)token expectedRevision:(uint64_t)revision {
    if (token <= 0 || token > INT_MAX || _revision != revision || _revision == UINT64_MAX
        || _binaryDocument || _loadingText) return NO;
    // An admitted file command may finish while termination locks typing.
    // Application validates read-only state and drains this command before recovery.
    // No coalescing: each format selection is a distinct step among text edits.
    [_scintilla message:SCI_ADDUNDOACTION wParam:token lParam:0];
    [self publishMetadataToken:token origin:DPScintillaEditOriginUser];
    return YES;
}

- (void)recordSavePointAtRevision:(uint64_t)revision {
    if (!_binaryDocument && _revision == revision) [_scintilla message:SCI_SETSAVEPOINT];
}

- (NSUInteger)changeHistoryStateAtLine:(NSUInteger)line {
    if (_binaryDocument || line >= self.lineCount) return 0;
    return ([_scintilla message:SCI_MARKERGET wParam:line] >> SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) & 0xF;
}

- (BOOL)canUndo { return [[_scintilla content] canUndo]; }
- (BOOL)canRedo { return [[_scintilla content] canRedo]; }
- (BOOL)canCut {
    return self.isInputEnabled && DPContentCanPerform([_scintilla content], @selector(cut:));
}
- (BOOL)canCopy { return DPContentCanPerform([_scintilla content], @selector(copy:)); }
- (BOOL)canPaste {
    return self.isInputEnabled && DPContentCanPerform([_scintilla content], @selector(paste:));
}
- (BOOL)canDelete {
    if (!self.isInputEnabled) return NO;
    return [_scintilla message:SCI_GETSELECTIONEMPTY] == 0
        || [_scintilla message:SCI_GETCURRENTPOS] < [_scintilla message:SCI_GETLENGTH];
}
- (BOOL)canSelectAll { return [_scintilla message:SCI_GETLENGTH] > 0; }
- (BOOL)cursorResourcesAvailable {
    NSImage *busy = [[NSImage alloc] initWithContentsOfFile:DPScintillaResourcePath(@"mac_cursor_busy.png")];
    NSImage *flipped = [[NSImage alloc] initWithContentsOfFile:DPScintillaResourcePath(@"mac_cursor_flipped.png")];
    return busy != nil && flipped != nil;
}
- (BOOL)hasEditorFocus { return self.window.firstResponder == [_scintilla content]; }

- (BOOL)setSearchHighlights:(NSArray<NSValue *> *)ranges revision:(uint64_t)revision {
    if (_binaryDocument || _revision != revision || ranges.count > 100000) return NO;
    const NSUInteger length = self.documentByteLength;
    // Text documents already contain validated UTF-8. A continuation byte is
    // the only interior position that is not a boundary; avoid two native
    // character-navigation requests per edge for each of 100,000 matches.
    auto boundary = [&](NSUInteger position) {
        return position == 0 || position == length
            || ([_scintilla message:SCI_GETCHARAT wParam:position] & 0xC0) != 0x80;
    };
    for (NSValue *value in ranges) {
        const NSRange range = value.rangeValue;
        if (range.location > length || range.length > length - range.location
            || !boundary(range.location) || !boundary(NSMaxRange(range))) return NO;
    }
    [self clearSearchHighlights];
    [_scintilla message:SCI_SETINDICATORCURRENT wParam:DPSearchIndicator];
    [_scintilla message:SCI_SETINDICATORVALUE wParam:1];
    NSMutableIndexSet *offsets = [NSMutableIndexSet indexSet];
    for (NSValue *value in ranges) {
        const NSRange range = value.rangeValue;
        [offsets addIndex:range.location];
        if (range.length > 0) {
            [_scintilla message:SCI_INDICATORFILLRANGE wParam:range.location lParam:range.length];
        }
    }
    for (DPScintillaEditorView *peer in _searchMarkerPeers) {
        peer->_searchHighlightsActive = YES;
        peer->_searchMarkerOffsets = [offsets copy];
        peer->_searchOverviewNeedsRefresh = YES;
        [peer refreshSearchOverview];
        peer.needsLayout = YES;
    }
    return YES;
}

- (void)clearSearchHighlights {
    BOOL active = NO;
    for (DPScintillaEditorView *peer in _searchMarkerPeers) active |= peer->_searchHighlightsActive;
    if (!active) return;
    for (DPScintillaEditorView *peer in _searchMarkerPeers) {
        peer->_searchHighlightsActive = NO;
        peer->_searchMarkerOffsets = [NSIndexSet indexSet];
        peer->_searchOverviewNeedsRefresh = YES;
        [peer refreshSearchOverview];
    }
    if (_binaryDocument) return;
    [_scintilla message:SCI_SETINDICATORCURRENT wParam:DPSearchIndicator];
    [_scintilla message:SCI_INDICATORCLEARRANGE wParam:0 lParam:self.documentByteLength];
}

- (BOOL)isSearchHighlightedAtUTF8Position:(NSUInteger)position {
    if (_binaryDocument || position >= self.documentByteLength) return NO;
    return [_scintilla message:SCI_INDICATORVALUEAT wParam:DPSearchIndicator lParam:position] != 0;
}

- (void)setPrimarySelectionUTF8Range:(NSRange)range {
    [_scintilla message:SCI_SETSEL wParam:(uptr_t)range.location lParam:(sptr_t)NSMaxRange(range)];
    [_scintilla message:SCI_SCROLLCARET];
    [self scheduleWordHighlights:YES];
}

- (NSArray<NSDictionary<NSString *, NSNumber *> *> *)selectionUTF8Positions {
    const NSInteger count = [_scintilla message:SCI_GETSELECTIONS];
    if (count > 10000) return @[];
    NSMutableArray *positions = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger index = 0; index < count; ++index) {
        [positions addObject:@{@"anchor": @([_scintilla message:SCI_GETSELECTIONNANCHOR wParam:index]),
                               @"caret": @([_scintilla message:SCI_GETSELECTIONNCARET wParam:index])}];
    }
    return positions;
}

- (NSUInteger)mainSelectionIndex { return [_scintilla message:SCI_GETMAINSELECTION]; }

- (BOOL)setSelectionUTF8Positions:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)positions mainIndex:(NSUInteger)mainIndex {
    if (!_scintilla || positions.count == 0 || positions.count > 10000 || mainIndex >= positions.count) return NO;
    const NSUInteger length = self.documentByteLength;
    std::vector<std::pair<NSInteger, NSInteger>> validated;
    for (NSDictionary *position in positions) {
        NSInteger anchor, caret;
        if (!DPIntegerFromNumber(position[@"anchor"], &anchor) || !DPIntegerFromNumber(position[@"caret"], &caret)
            || anchor < 0 || caret < 0 || anchor > length || caret > length
            || ![self isUTF8Boundary:anchor documentLength:length] || ![self isUTF8Boundary:caret documentLength:length]) return NO;
        validated.emplace_back(anchor, caret);
    }
    BOOL first = YES;
    for (const auto [anchor, caret] : validated) {
        [_scintilla message:first ? SCI_SETSELECTION : SCI_ADDSELECTION wParam:caret lParam:anchor];
        first = NO;
    }
    [_scintilla message:SCI_SETMAINSELECTION wParam:mainIndex];
    [self scheduleWordHighlights:YES];
    return YES;
}

- (void)attachWordHighlighter {
    __weak DPScintillaEditorView *weakSelf = self;
    [_wordHighlighter addView:_scintilla onChange:^{
        DPScintillaEditorView *owner = weakSelf;
        if (!owner || !owner->_scintilla) return;
        owner->_searchOverviewNeedsRefresh = YES;
        [owner refreshSearchOverview];
    }];
}

- (NSIndexSet *)overviewMarkerOffsets {
    return _searchHighlightsActive ? _searchMarkerOffsets : _wordHighlighter.matchOffsets;
}

- (void)scheduleWordHighlights:(BOOL)selectionChanged {
    if (!_scintilla) return;
    [_wordHighlighter scheduleForView:_scintilla enabled:!_binaryDocument && !_loadingText
        caretWordEnabled:_caretWordHighlightEnabled selectionChanged:selectionChanged];
}

- (BOOL)isWordHighlightedAtUTF8Position:(NSUInteger)position {
    return [DPWordOccurrenceHighlighter isHighlightedInView:_scintilla atPosition:position];
}

- (NSUInteger)wordHighlightInspectedByteCount { return _wordHighlighter.inspectedByteCount; }

- (void)revealDeclarationInUTF8Range:(NSRange)range {
    const NSUInteger length = self.documentByteLength;
    if (!_scintilla || _binaryDocument || range.location > length || range.length > length - range.location) return;
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:range.location];
    [_scintilla message:SCI_ENSUREVISIBLE wParam:line];
    [self setPrimarySelectionUTF8Range:range];
    // Use display rows, so folded regions and wrapped logical lines count as rendered.
    const NSInteger lineHeight = MAX(1, [_scintilla message:SCI_TEXTHEIGHT wParam:0]);
    const NSInteger targetRow = [_scintilla message:SCI_GETFIRSTVISIBLELINE]
        + [_scintilla message:SCI_POINTYFROMPOSITION wParam:0 lParam:range.location] / lineHeight;
    const NSInteger contextRows = [_scintilla message:SCI_LINESONSCREEN] / 5;
    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:MAX(0, targetRow - contextRows)];
}

- (void)restoreCaretUTF8Position:(NSUInteger)caret
                  anchorPosition:(NSUInteger)anchor
                firstVisibleLine:(NSUInteger)firstVisibleLine
          horizontalScrollOffset:(NSUInteger)horizontalScrollOffset
                 wordWrapEnabled:(BOOL)wordWrapEnabled {
    const NSUInteger length = (NSUInteger)[_scintilla message:SCI_GETLENGTH];
    const NSUInteger safeCaret = MIN(caret, length);
    const NSUInteger safeAnchor = MIN(anchor, length);
    if (safeCaret != length || safeAnchor != length) _observedFollowEnd = NO;
    [_scintilla message:SCI_SETSEL wParam:(uptr_t)safeAnchor lParam:(sptr_t)safeCaret];
    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)firstVisibleLine];
    [_scintilla message:SCI_SETXOFFSET wParam:(uptr_t)horizontalScrollOffset];
    [_scintilla message:SCI_SETWRAPMODE wParam:wordWrapEnabled && !_binaryDocument ? SC_WRAP_WORD : SC_WRAP_NONE];
    _searchOverviewNeedsRefresh = YES;
}

- (BOOL)addSelectionUTF8Range:(NSRange)range {
    const NSUInteger length = (NSUInteger)[_scintilla message:SCI_GETLENGTH];
    if (range.location > length || range.length > length - range.location) return NO;
    [_scintilla message:SCI_ADDSELECTION
                 wParam:(uptr_t)NSMaxRange(range)
                 lParam:(sptr_t)range.location];
    return YES;
}

- (void)insertCommittedText:(NSString *)text {
    if (![self preflightUserMutation]) return;
    if ([[_scintilla content] hasMarkedText]) {
        [[_scintilla content] insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        return;
    }
    _textInputSourceKnown = YES;
    _directInputInsertion = YES;
    _directInputByteLengthKnown = YES;
    _directInputByteLength = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [self captureDirectInputPreflightState];
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil) publisher->_directInputInitiator = self;
    if (![self scintillaHandleDirectSelectionText:text]) {
        [[_scintilla content] insertText:text];
    }
    if (publisher != nil && publisher->_directInputInitiator == self) {
        publisher->_directInputInitiator = nil;
    }
    [self clearDirectInputPreflightState];
    _directInputInsertion = NO;
    _textInputSourceKnown = NO;
}

- (void)scintillaWillInsertTextFromSource:(SCITextInputSource)source {
    [self clearDeclarationHover];
    _textInputSourceKnown = YES;
    _directInputInsertion = source == SCITextInputSourceDirect || source == SCITextInputSourceDirectNewline;
    if (source == SCITextInputSourceDirectNewline) {
        _directInputByteLengthKnown = YES;
        _directInputByteLength = 1; // A single Return command, independent of the document's EOL width.
    }
    if (!_directInputByteLengthKnown && _directInputInsertion) {
        NSEvent *event = NSApp.currentEvent;
        if (event.type == NSEventTypeKeyDown && event.characters != nil) {
            _directInputByteLengthKnown = YES;
            _directInputByteLength = [event.characters
                lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
    }
    [self captureDirectInputPreflightState];
    if (_directInputInsertion && _documentPublisher != nil) {
        _documentPublisher->_directInputInitiator = self;
    }
}

- (void)scintillaDidInsertText {
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil && publisher->_directInputInitiator == self) {
        publisher->_directInputInitiator = nil;
    }
    [self clearDirectInputPreflightState];
    _directInputInsertion = NO;
    _textInputSourceKnown = NO;
}

- (BOOL)scintillaHandleDirectSelectionText:(NSString *)text {
    if (!_smartEditingEnabled || !_directInputInsertion || self.hasMarkedText
        || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != 1
        || [_scintilla message:SCI_GETSELECTIONMODE] != SC_SEL_STREAM) return NO;
    const char *pair = DPSmartPairForOpening(static_cast<unsigned char>(text.UTF8String[0]));
    if (pair == nullptr) return NO;

    struct SurroundSelection {
        NSUInteger anchor;
        NSUInteger caret;
        NSUInteger index;
        NSUInteger lower() const { return MIN(anchor, caret); }
        NSUInteger upper() const { return MAX(anchor, caret); }
    };
    const NSUInteger count = (NSUInteger)[_scintilla message:SCI_GETSELECTIONS];
    const NSUInteger mainSelection = (NSUInteger)[_scintilla message:SCI_GETMAINSELECTION];
    const NSUInteger length = self.documentByteLength;
    std::vector<SurroundSelection> selections;
    BOOL hasSelection = NO;
    for (NSUInteger index = 0; index < count; ++index) {
        if ([_scintilla message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:index] != 0
            || [_scintilla message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:index] != 0) return NO;
        const NSUInteger anchor = (NSUInteger)[_scintilla message:SCI_GETSELECTIONNANCHOR wParam:index];
        const NSUInteger caret = (NSUInteger)[_scintilla message:SCI_GETSELECTIONNCARET wParam:index];
        if (anchor > length || caret > length
            || ![self isUTF8Boundary:anchor documentLength:length]
            || ![self isUTF8Boundary:caret documentLength:length]) return NO;
        selections.push_back({anchor, caret, index});
        hasSelection |= anchor != caret;
    }
    if (!hasSelection) return NO; // Preserve existing single/multiple-caret typing.
    std::sort(selections.begin(), selections.end(), [](const auto &a, const auto &b) {
        return a.lower() < b.lower() || (a.lower() == b.lower() && a.upper() < b.upper());
    });
    for (NSUInteger index = 1; index < count; ++index) {
        if (selections[index].lower() < selections[index - 1].upper()) return NO;
    }
    DPScintillaEditorView *publisher = _documentPublisher ?: self;
    if (![self preflightUserMutation] || ![publisher preflightUserMutation]) return YES;
    // Reserve the forward edits and their undo as a complete operation.
    if (count > (UINT64_MAX - publisher.revision) / 4
        || count > (static_cast<NSUInteger>(NSIntegerMax) - length) / 2) {
        [publisher publishMutationError:DPScintillaErrorRevisionOverflow
                            description:@"Insufficient revision or position space for selection surround"];
        return YES;
    }

    // Insert only the delimiters: no selected-text copy or full-range replacement
    // enters native undo history or the incremental recovery journal.
    _directInputInsertion = NO;
    [_scintilla message:SCI_BEGINUNDOACTION];
    @try {
        for (auto iterator = selections.rbegin(); iterator != selections.rend(); ++iterator) {
            const NSUInteger positions[] = {iterator->upper(), iterator->lower()};
            for (NSUInteger boundary = 0; boundary < 2; ++boundary) {
                if (!self.isInputEnabled || !publisher.isInputEnabled) return YES;
                [_scintilla message:SCI_SETTARGETSTART wParam:positions[boundary]];
                [_scintilla message:SCI_SETTARGETEND wParam:positions[boundary]];
                [_scintilla message:SCI_REPLACETARGET wParam:1
                             lParam:reinterpret_cast<sptr_t>(pair + (boundary == 0 ? 1 : 0))];
            }
        }
        if (!self.isInputEnabled || !publisher.isInputEnabled) return YES;
        for (NSUInteger index = 0; index < count; ++index) {
            selections[index].anchor += 2 * index + 1;
            selections[index].caret += 2 * index + 1;
        }
        std::sort(selections.begin(), selections.end(), [](const auto &a, const auto &b) {
            return a.index < b.index;
        });
        for (NSUInteger index = 0; index < count; ++index) {
            [_scintilla message:index == 0 ? SCI_SETSELECTION : SCI_ADDSELECTION
                         wParam:selections[index].caret lParam:selections[index].anchor];
        }
        [_scintilla message:SCI_SETMAINSELECTION wParam:mainSelection];
        [_scintilla message:SCI_SCROLLCARET];
    } @finally {
        [_scintilla message:SCI_ENDUNDOACTION];
        _directInputInsertion = YES;
    }
    return YES;
}

- (void)captureDirectInputPreflightState {
    const sptr_t selectionCount = [_scintilla message:SCI_GETSELECTIONS];
    const sptr_t caretVirtualSpace = [_scintilla
        message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:0];
    const sptr_t anchorVirtualSpace = [_scintilla
        message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:0];
    const sptr_t anchor = [_scintilla message:SCI_GETANCHOR];
    const sptr_t caret = [_scintilla message:SCI_GETCURRENTPOS];
    _directInputSelectionEligible = selectionCount == 1
        && caretVirtualSpace == 0 && anchorVirtualSpace == 0
        && anchor == caret
        && DPSelectionShapeFromScintilla([_scintilla message:SCI_GETSELECTIONMODE])
            == DPScintillaSelectionShapeStream;
}

- (NSRange)declarationHoverRange { return _declarationHoverRange; }
- (uint64_t)declarationContentGeneration {
    return _documentPublisher ? _documentPublisher->_statusContentGeneration : _statusContentGeneration;
}

- (void)clearDeclarationHoverDecoration {
    if (_declarationHoverRange.length) {
        const sptr_t previous = [_scintilla message:SCI_GETINDICATORCURRENT];
        [_scintilla message:SCI_SETINDICATORCURRENT wParam:DPDeclarationIndicator];
        [_scintilla message:SCI_INDICATORCLEARRANGE wParam:_declarationHoverRange.location lParam:_declarationHoverRange.length];
        [_scintilla message:SCI_SETINDICATORCURRENT wParam:previous];
    }
    _declarationHoverRange = NSMakeRange(NSNotFound, 0);
    [_scintilla content].declarationLinkCursor = NO;
}

- (void)clearDeclarationHover {
    const BOOL pending = _declarationHoverPosition != NSNotFound;
    _declarationHoverPosition = NSNotFound;
    [self clearDeclarationHoverDecoration];
    if (pending && self.onDeclarationHovered) self.onDeclarationHovered(NSNotFound);
}

- (void)scintillaClearDeclarationHover { [self clearDeclarationHover]; }

- (void)scintillaDeclarationHoverAt:(NSPoint)location modifiers:(NSEventModifierFlags)modifiers {
    const NSEventModifierFlags relevant = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    if (relevant != NSEventModifierFlagCommand || !self.onDeclarationHovered || !_requestedInputEnabled
        || _binaryDocument || _loadingText || [[_scintilla content] hasMarkedText] || !self.window.isKeyWindow) {
        [self clearDeclarationHover]; return;
    }
    const NSPoint point = [_scintilla.scrollView convertPoint:location fromView:nil];
    const sptr_t position = (point.x < 0 || point.y < 0) ? -1 : [_scintilla message:SCI_CHARPOSITIONFROMPOINTCLOSE
        wParam:static_cast<uptr_t>(point.x) lParam:static_cast<sptr_t>(point.y)];
    if (position < 0) { [self clearDeclarationHover]; return; }
    if (_declarationHoverPosition == static_cast<NSUInteger>(position)) return;
    _declarationHoverPosition = position;
    if (_declarationHoverRange.length && NSLocationInRange(position, _declarationHoverRange)) return;
    [self clearDeclarationHoverDecoration];
    self.onDeclarationHovered(position);
}

- (BOOL)showDeclarationHoverRange:(NSRange)range expectedRevision:(uint64_t)revision expectedPosition:(NSUInteger)position {
    if (!_scintilla || !_requestedInputEnabled || _binaryDocument || _loadingText || !self.window.isKeyWindow
        || [[_scintilla content] hasMarkedText] || _revision != revision || _declarationHoverPosition != position
        || !range.length || range.length > 256 || range.location > self.documentByteLength
        || range.length > self.documentByteLength - range.location || !NSLocationInRange(position, range)) return NO;
    [self clearDeclarationHoverDecoration];
    const sptr_t previous = [_scintilla message:SCI_GETINDICATORCURRENT];
    [_scintilla message:SCI_SETINDICATORCURRENT wParam:DPDeclarationIndicator];
    [_scintilla message:SCI_INDICATORFILLRANGE wParam:range.location lParam:range.length];
    [_scintilla message:SCI_SETINDICATORCURRENT wParam:previous];
    _declarationHoverRange = range;
    [_scintilla content].declarationLinkCursor = YES;
    return YES;
}

- (BOOL)scintillaHandleSelectionEscape {
    if ([_scintilla message:SCI_AUTOCACTIVE] || [_scintilla message:SCI_CALLTIPACTIVE]
        || [_scintilla message:SCI_GETSELECTIONS] <= 1) return NO;
    if (![self canPerformSelection:DPScintillaSelectionCommandCollapseSelections]) return NO;
    [self performSelection:DPScintillaSelectionCommandCollapseSelections];
    return YES;
}

- (BOOL)scintillaHandleMouseDown:(NSEvent *)event {
    [self clearDeclarationHover];
    const NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift)) == (NSEventModifierFlagCommand | NSEventModifierFlagOption)
        && event.clickCount == 1 && _requestedInputEnabled && !_loadingText && !_binaryDocument
        && ![[_scintilla content] hasMarkedText]) {
        const NSPoint point = [_scintilla.scrollView convertPoint:event.locationInWindow fromView:nil];
        const sptr_t position = [_scintilla message:SCI_POSITIONFROMPOINTCLOSE wParam:point.x lParam:point.y];
        if (position >= 0) {
            [self focusEditor];
            [_scintilla message:SCI_ADDSELECTION wParam:position lParam:position];
            return YES;
        }
    }
    if ((modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift)) != NSEventModifierFlagCommand
        || event.clickCount != 1 || self.onDeclarationRequested == nil
        || !_requestedInputEnabled || _binaryDocument || [[_scintilla content] hasMarkedText]) return NO;
    // Match the viewport coordinates used by firstRectForCharacterRange.
    NSPoint point = [_scintilla.scrollView convertPoint:event.locationInWindow fromView:nil];
    if (point.x < 0 || point.y < 0) return NO;
    const sptr_t position = [_scintilla message:SCI_POSITIONFROMPOINTCLOSE
                                       wParam:static_cast<uptr_t>(point.x)
                                       lParam:static_cast<sptr_t>(point.y)];
    if (position < 0) return NO;
    [self focusEditor];
    self.onDeclarationRequested(static_cast<NSUInteger>(position));
    return YES;
}

- (void)clearDirectInputPreflightState {
    _directInputByteLengthKnown = NO;
    _directInputByteLength = 0;
    _directInputSelectionEligible = NO;
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    [self clearDeclarationHover];
    if (![self preflightUserMutation]) return;
    [[_scintilla content] setMarkedText:text selectedRange:selectedRange replacementRange:replacementRange];
}
- (void)unmarkText { [[_scintilla content] unmarkText]; }
- (BOOL)hasMarkedText { return [[_scintilla content] hasMarkedText]; }
- (void)scintillaDidCopyToPasteboard:(NSPasteboard *)pasteboard {
    if (self.didCopySelection) self.didCopySelection(pasteboard);
}
- (void)copySelectionAsPlainText {
    void (^handler)(NSPasteboard *) = self.didCopySelection;
    self.didCopySelection = nil;
    @try { [[_scintilla content] copy:nil]; }
    @finally { self.didCopySelection = handler; }
}
- (NSAttributedString *)copyPresentationWithMaximumBytes:(NSUInteger)maximumBytes {
    // Keep rectangular/multiple selections on Scintilla's existing clipboard path.
    if ([_scintilla message:SCI_GETSELECTIONS] != 1
        || [_scintilla message:SCI_GETSELECTIONMODE] != SC_SEL_STREAM
        || [_scintilla message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:0] != 0
        || [_scintilla message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:0] != 0) return nil;
    const sptr_t start = [_scintilla message:SCI_GETSELECTIONSTART];
    const sptr_t end = [_scintilla message:SCI_GETSELECTIONEND];
    const NSUInteger length = end - start;
    if (!length || length > MIN(maximumBytes, (NSUInteger)1048576)) return nil;
    // Read only selected bytes and their existing styles. Never force lexing to EOF.
    std::vector<char> bytes(length * 2 + 2);
    Sci_TextRangeFull range = {{start, end}, bytes.data()};
    [_scintilla message:SCI_GETSTYLEDTEXTFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&range)];
    // Match ViewStyle::FontRealised: zoom is additive, with a one-point minimum.
    const double displayedFontSize = MAX(1.0, _editorFontSize + self.zoomLevel);
    NSFont *font = [NSFont fontWithName:_editorFontName size:displayedFontSize]
        ?: [NSFont monospacedSystemFontOfSize:displayedFontSize weight:NSFontWeightRegular];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.minimumLineHeight = [_scintilla message:SCI_TEXTHEIGHT wParam:0];
    paragraph.maximumLineHeight = paragraph.minimumLineHeight;
    paragraph.tabStops = @[];
    paragraph.defaultTabInterval = [@" " sizeWithAttributes:@{NSFontAttributeName:font}].width
        * MAX(1, [_scintilla message:SCI_GETTABWIDTH]);
    const int lightColors[] = {0x202020, 0x397A32, 0x7C2F8E, 0xA23B00, 0x176A7A, 0x204F9B, 0x2020D0};
    int colors[256];
    std::fill(std::begin(colors), std::end(colors), lightColors[0]);
    for (const auto &[style, role] : _semanticStyleRoles) {
        if (style >= 0 && style < 256 && role >= 0 && role < 7) colors[style] = lightColors[role];
    }
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:@""];
    NSUInteger runCount = 0;
    for (NSUInteger index = 0; index < length;) {
        if (++runCount > 4096) return nil;
        unsigned char style = bytes[index * 2 + 1];
        std::string run;
        do { run.push_back(bytes[index++ * 2]); }
        while (index < length && (unsigned char)bytes[index * 2 + 1] == style);
        NSString *text = [[NSString alloc] initWithBytes:run.data() length:run.size() encoding:NSUTF8StringEncoding];
        if (!text) return nil;
        int color = colors[style];
        NSColor *foreground = [NSColor colorWithSRGBRed:(color & 255) / 255.0
            green:((color >> 8) & 255) / 255.0 blue:((color >> 16) & 255) / 255.0 alpha:1];
        NSFontTraitMask traits = 0;
        if ([_scintilla message:SCI_STYLEGETBOLD wParam:style]) traits |= NSBoldFontMask;
        if ([_scintilla message:SCI_STYLEGETITALIC wParam:style]) traits |= NSItalicFontMask;
        NSFont *runFont = traits ? [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits] : font;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName:runFont, NSForegroundColorAttributeName:foreground,
            NSParagraphStyleAttributeName:paragraph
        }]];
    }
    return result;
}
- (void)copySelection { [[_scintilla content] copy:nil]; }
- (void)cutSelection { if ([self preflightUserMutation]) [[_scintilla content] cut:nil]; }
- (void)paste { if ([self preflightUserMutation]) [[_scintilla content] paste:nil]; }
- (void)deleteSelectionOrNextCharacter { if ([self preflightUserMutation]) [_scintilla message:SCI_CLEAR]; }
- (void)selectAll { [[_scintilla content] selectAll:nil]; }
- (void)undo { if ([self preflightUserMutation]) [[_scintilla content] undo:nil]; }
- (void)redo { if ([self preflightUserMutation]) [[_scintilla content] redo:nil]; }
- (BOOL)canPerformSelection:(DPScintillaSelectionCommand)command {
    if (!_requestedInputEnabled || _loadingText || _binaryDocument || [[_scintilla content] hasMarkedText]) return NO;
    const sptr_t count = [_scintilla message:SCI_GETSELECTIONS];
    const sptr_t caret = [_scintilla message:SCI_GETCURRENTPOS];
    const sptr_t line = [_scintilla message:SCI_LINEFROMPOSITION wParam:caret];
    switch (command) {
        case DPScintillaSelectionCommandUndoAddedSelection: return count > 1;
        case DPScintillaSelectionCommandCollapseSelections:
            return count > 1 || [_scintilla message:SCI_GETANCHOR] != caret;
        case DPScintillaSelectionCommandAddCursorAbove: return line > 0;
        case DPScintillaSelectionCommandAddCursorBelow: return line + 1 < [_scintilla message:SCI_GETLINECOUNT];
        default: return [_scintilla message:SCI_GETLENGTH] > 0;
    }
}

// Count before changing any selection: Scintilla's repeated AddSelection is quadratic.
- (BOOL)canSelectAllFrom:(sptr_t)start to:(sptr_t)end existingCount:(sptr_t)count {
    const sptr_t length = [_scintilla message:SCI_GETLENGTH];
    if (length > DPMaximumBulkSelectionDocumentBytes || end <= start ||
        end - start > DPMaximumBulkSelectionPatternBytes || count > DPMaximumBulkSelections) return NO;
    std::string needle(static_cast<size_t>(end - start) + 1, '\0');
    Sci_TextRangeFull textRange{{start, end}, needle.data()};
    [_scintilla message:SCI_GETTEXTRANGEFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&textRange)];
    const sptr_t targetStart = [_scintilla message:SCI_GETTARGETSTART];
    const sptr_t targetEnd = [_scintilla message:SCI_GETTARGETEND];
    const sptr_t flags = [_scintilla message:SCI_GETSEARCHFLAGS];
    [_scintilla message:SCI_SETSEARCHFLAGS wParam:SCFIND_MATCHCASE];
    BOOL allowed = YES;
    for (const auto &range : {std::make_pair(end, length), std::make_pair(sptr_t(0), start)}) {
        sptr_t position = range.first;
        while (position < range.second && allowed) {
            [_scintilla message:SCI_SETTARGETSTART wParam:position];
            [_scintilla message:SCI_SETTARGETEND wParam:range.second];
            const sptr_t found = [_scintilla message:SCI_SEARCHINTARGET wParam:end - start
                                                lParam:reinterpret_cast<sptr_t>(needle.data())];
            if (found < 0) break;
            position = [_scintilla message:SCI_GETTARGETEND];
            if (++count > DPMaximumBulkSelections) allowed = NO;
        }
        if (!allowed) break;
    }
    [_scintilla message:SCI_SETTARGETSTART wParam:targetStart];
    [_scintilla message:SCI_SETTARGETEND wParam:targetEnd];
    [_scintilla message:SCI_SETSEARCHFLAGS wParam:flags];
    return allowed;
}

- (void)performSelection:(DPScintillaSelectionCommand)command {
    if (![self canPerformSelection:command]) return;
    const sptr_t main = [_scintilla message:SCI_GETMAINSELECTION];
    const sptr_t caret = [_scintilla message:SCI_GETSELECTIONNCARET wParam:main];
    switch (command) {
        case DPScintillaSelectionCommandSelectNextOccurrence:
        case DPScintillaSelectionCommandSelectAllOccurrences:
        case DPScintillaSelectionCommandSkipCurrentOccurrence: {
            const bool empty = [_scintilla message:SCI_GETSELECTIONNSTART wParam:main] ==
                [_scintilla message:SCI_GETSELECTIONNEND wParam:main];
            const sptr_t before = [_scintilla message:SCI_GETSELECTIONS];
            const sptr_t start = empty ? [_scintilla message:SCI_WORDSTARTPOSITION wParam:caret lParam:1] :
                [_scintilla message:SCI_GETSELECTIONNSTART wParam:main];
            const sptr_t end = empty ? [_scintilla message:SCI_WORDENDPOSITION wParam:start lParam:1] :
                [_scintilla message:SCI_GETSELECTIONNEND wParam:main];
            if (end <= start) return;
            if (command == DPScintillaSelectionCommandSelectAllOccurrences &&
                ![self canSelectAllFrom:start to:end existingCount:empty ? 1 : before]) { NSBeep(); return; }
            if (!empty && command != DPScintillaSelectionCommandSelectAllOccurrences && before >= DPMaximumBulkSelections) {
                NSBeep(); return;
            }
            // An empty primary range beside a nonempty range must never search a zero-length needle.
            if (empty) [_scintilla message:SCI_SETSELECTION wParam:end lParam:start];
            if (empty && command != DPScintillaSelectionCommandSelectAllOccurrences) break;
            // Selection search must not alter the find/replace target or flags.
            const sptr_t targetStart = [_scintilla message:SCI_GETTARGETSTART];
            const sptr_t targetEnd = [_scintilla message:SCI_GETTARGETEND];
            const sptr_t flags = [_scintilla message:SCI_GETSEARCHFLAGS];
            [_scintilla message:SCI_TARGETWHOLEDOCUMENT];
            [_scintilla message:SCI_SETSEARCHFLAGS wParam:SCFIND_MATCHCASE];
            [_scintilla message:command == DPScintillaSelectionCommandSelectAllOccurrences ?
                SCI_MULTIPLESELECTADDEACH : SCI_MULTIPLESELECTADDNEXT];
            if (!empty && command == DPScintillaSelectionCommandSkipCurrentOccurrence &&
                [_scintilla message:SCI_GETSELECTIONS] > before)
                [_scintilla message:SCI_DROPSELECTIONN wParam:main];
            [_scintilla message:SCI_SETTARGETSTART wParam:targetStart];
            [_scintilla message:SCI_SETTARGETEND wParam:targetEnd];
            [_scintilla message:SCI_SETSEARCHFLAGS wParam:flags];
            break;
        }
        case DPScintillaSelectionCommandUndoAddedSelection:
            [_scintilla message:SCI_DROPSELECTIONN wParam:main];
            break;
        case DPScintillaSelectionCommandCollapseSelections:
            [_scintilla message:SCI_SETEMPTYSELECTION wParam:caret];
            break;
        case DPScintillaSelectionCommandAddCursorAbove:
        case DPScintillaSelectionCommandAddCursorBelow: {
            const sptr_t line = [_scintilla message:SCI_LINEFROMPOSITION wParam:caret] +
                (command == DPScintillaSelectionCommandAddCursorAbove ? -1 : 1);
            const sptr_t column = [_scintilla message:SCI_GETCOLUMN wParam:caret] +
                [_scintilla message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:main];
            const sptr_t position = [_scintilla message:SCI_FINDCOLUMN wParam:line lParam:column];
            const sptr_t count = [_scintilla message:SCI_GETSELECTIONS];
            for (sptr_t i = 0; i < count; ++i) {
                if ([_scintilla message:SCI_GETSELECTIONNCARET wParam:i] == position) {
                    [_scintilla message:SCI_SETMAINSELECTION wParam:i];
                    [_scintilla message:SCI_SCROLLCARET];
                    return;
                }
            }
            [_scintilla message:SCI_ADDSELECTION wParam:position lParam:position];
            const sptr_t added = [_scintilla message:SCI_GETMAINSELECTION];
            const sptr_t space = MAX(0, column - [_scintilla message:SCI_GETCOLUMN wParam:position]);
            [_scintilla message:SCI_SETSELECTIONNCARETVIRTUALSPACE wParam:added lParam:space];
            [_scintilla message:SCI_SETSELECTIONNANCHORVIRTUALSPACE wParam:added lParam:space];
            break;
        }
        case DPScintillaSelectionCommandSplitSelectionIntoLines: {
            std::vector<std::pair<sptr_t, sptr_t>> ranges;
            const sptr_t count = [_scintilla message:SCI_GETSELECTIONS];
            if (count > DPMaximumBulkSelections) { NSBeep(); return; }
            for (sptr_t i = 0; i < count; ++i) {
                const sptr_t start = [_scintilla message:SCI_GETSELECTIONNSTART wParam:i];
                const sptr_t end = [_scintilla message:SCI_GETSELECTIONNEND wParam:i];
                const sptr_t first = [_scintilla message:SCI_LINEFROMPOSITION wParam:start];
                sptr_t last = [_scintilla message:SCI_LINEFROMPOSITION wParam:end];
                if (end > start && [_scintilla message:SCI_POSITIONFROMLINE wParam:last] == end) --last;
                if (last - first + 1 > DPMaximumBulkSelections - static_cast<sptr_t>(ranges.size())) {
                    NSBeep(); return;
                }
                for (sptr_t line = first; line <= last; ++line) {
                    const sptr_t a = MAX(start, [_scintilla message:SCI_POSITIONFROMLINE wParam:line]);
                    const sptr_t b = MIN(end, [_scintilla message:SCI_GETLINEENDPOSITION wParam:line]);
                    ranges.emplace_back(a, MAX(a, b));
                }
            }
            if (!ranges.empty()) {
                [_scintilla message:SCI_SETSELECTION wParam:ranges[0].second lParam:ranges[0].first];
                for (size_t i = 1; i < ranges.size(); ++i)
                    [_scintilla message:SCI_ADDSELECTION wParam:ranges[i].second lParam:ranges[i].first];
            }
            break;
        }
    }
    [_scintilla message:SCI_SCROLLCARET];
}

- (BOOL)canPerformEditingCommand:(DPScintillaEditingCommand)command {
    if (!self.isInputEnabled || [[_scintilla content] hasMarkedText]) return NO;
    const NSInteger length = [_scintilla message:SCI_GETLENGTH];
    // A native command may publish multiple synchronous SCN_MODIFIED records.
    // Reserve a conservative whole-command budget before any byte changes so
    // revision exhaustion can never leave a partially applied operation.
    const uint64_t byteLength = static_cast<uint64_t>(MAX(0, length));
    if (byteLength > (UINT64_MAX / 2) - 1) return NO;
    const uint64_t requiredRevisionBudget = 2 * (byteLength + 1);
    if (_revision > UINT64_MAX - requiredRevisionBudget) return NO;
    const NSInteger anchor = [_scintilla message:SCI_GETANCHOR];
    const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
    const NSInteger lower = MIN(anchor, caret);
    const NSInteger upper = MAX(anchor, caret);
    const NSInteger firstLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:lower];
    NSInteger lastLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:upper];
    if (upper > lower && [_scintilla message:SCI_POSITIONFROMLINE wParam:lastLine] == upper) lastLine -= 1;
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    switch (command) {
        case DPScintillaEditingCommandDuplicateLine:
        case DPScintillaEditingCommandIndent:
        case DPScintillaEditingCommandUnindent:
            return YES;
        case DPScintillaEditingCommandMoveLineUp:
            return firstLine > 0;
        case DPScintillaEditingCommandMoveLineDown:
            return lastLine + 1 < lineCount;
        case DPScintillaEditingCommandDeleteLine:
        case DPScintillaEditingCommandTrimTrailingWhitespace:
            return length > 0;
        case DPScintillaEditingCommandJoinLines:
            return firstLine < lastLine || lastLine + 1 < lineCount;
        case DPScintillaEditingCommandUppercase:
        case DPScintillaEditingCommandLowercase:
            return upper > lower;
    }
}

- (void)performEditingCommand:(DPScintillaEditingCommand)command {
    if (![self canPerformEditingCommand:command] || ![self preflightUserMutation]) return;
    switch (command) {
        case DPScintillaEditingCommandDuplicateLine:
            [_scintilla message:SCI_LINEDUPLICATE];
            break;
        case DPScintillaEditingCommandMoveLineUp:
            [_scintilla message:SCI_MOVESELECTEDLINESUP];
            break;
        case DPScintillaEditingCommandMoveLineDown:
            [_scintilla message:SCI_MOVESELECTEDLINESDOWN];
            break;
        case DPScintillaEditingCommandDeleteLine:
            [_scintilla message:SCI_LINEDELETE];
            break;
        case DPScintillaEditingCommandJoinLines: {
            const NSInteger anchor = [_scintilla message:SCI_GETANCHOR];
            const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
            NSInteger lower = MIN(anchor, caret);
            NSInteger upper = MAX(anchor, caret);
            const NSInteger firstLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:lower];
            NSInteger lastLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:upper];
            if (upper > lower && [_scintilla message:SCI_POSITIONFROMLINE wParam:lastLine] == upper) {
                lastLine -= 1;
            }
            if (firstLine == lastLine) lastLine += 1;
            lower = [_scintilla message:SCI_POSITIONFROMLINE wParam:firstLine];
            upper = [_scintilla message:SCI_GETLINEENDPOSITION wParam:lastLine];
            [_scintilla message:SCI_SETTARGETSTART wParam:lower];
            [_scintilla message:SCI_SETTARGETEND wParam:upper];
            [_scintilla message:SCI_LINESJOIN];
            break;
        }
        case DPScintillaEditingCommandUppercase:
            [_scintilla message:SCI_UPPERCASE];
            break;
        case DPScintillaEditingCommandLowercase:
            [_scintilla message:SCI_LOWERCASE];
            break;
        case DPScintillaEditingCommandIndent:
            [_scintilla message:SCI_TAB];
            break;
        case DPScintillaEditingCommandUnindent:
            [_scintilla message:SCI_BACKTAB];
            break;
        case DPScintillaEditingCommandTrimTrailingWhitespace: {
            const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
            std::vector<std::pair<NSInteger, NSInteger>> ranges;
            ranges.reserve(static_cast<size_t>(MAX(0, lineCount)));
            for (NSInteger line = 0; line < lineCount; line += 1) {
                const NSInteger start = [_scintilla message:SCI_POSITIONFROMLINE wParam:line];
                const NSInteger end = [_scintilla message:SCI_GETLINEENDPOSITION wParam:line];
                NSInteger whitespaceStart = end;
                while (whitespaceStart > start) {
                    const NSInteger character = [_scintilla message:SCI_GETCHARAT wParam:whitespaceStart - 1];
                    if (character != ' ' && character != '\t') break;
                    whitespaceStart -= 1;
                }
                if (whitespaceStart < end) ranges.push_back({whitespaceStart, end});
            }
            [_scintilla message:SCI_BEGINUNDOACTION];
            static const char empty = '\0';
            for (auto iterator = ranges.rbegin(); iterator != ranges.rend(); ++iterator) {
                [_scintilla message:SCI_SETTARGETSTART wParam:iterator->first];
                [_scintilla message:SCI_SETTARGETEND wParam:iterator->second];
                [_scintilla message:SCI_REPLACETARGET
                             wParam:0
                             lParam:reinterpret_cast<sptr_t>(&empty)];
            }
            [_scintilla message:SCI_ENDUNDOACTION];
            break;
        }
    }
}
- (void)beginGroupedUndo { [_scintilla message:SCI_BEGINUNDOACTION]; }
- (void)endGroupedUndo { [_scintilla message:SCI_ENDUNDOACTION]; }
- (void)publishFocus {
    [self scheduleWordHighlights:YES];
    _focusEventGeneration += 1;
    if (self.onFocus) self.onFocus();
}

- (void)focusEditor {
    const BOOL wasFocused = self.hasEditorFocus;
    const NSUInteger generation = _focusEventGeneration;
    [self.window makeFirstResponder:[_scintilla content]];
    if (!wasFocused && self.hasEditorFocus && generation == _focusEventGeneration) {
        [self publishFocus];
    }
}

+ (BOOL)supportsLexerNamed:(NSString *)lexerName {
    if (lexerName.length == 0) return NO;
    Scintilla::ILexer5 *lexer = [lexerName isEqualToString:@"plantuml"] ? DPCreatePlantUMLLexer() : [lexerName isEqualToString:@"duckpadlog"] ? DPCreateLogLexer() : CreateLexer(lexerName.UTF8String);
    if (lexer == nullptr) return NO;
    lexer->Release();
    return YES;
}

- (BOOL)applyLexerNamed:(NSString *)lexerName
               keywords:(NSArray<NSString *> *)keywords
                tabWidth:(NSUInteger)tabWidth
                 useTabs:(BOOL)useTabs
                 folding:(BOOL)folding
           braceMatching:(BOOL)braceMatching
        maximumStyleBytes:(NSUInteger)maximumStyleBytes {
    _languageConfigurationCount += 1;
    _maximumStyleBytes = maximumStyleBytes;
    const BOOL overBudget = _binaryDocument || (self.documentByteLength > maximumStyleBytes && ![lexerName isEqualToString:@"duckpadlog"]);
    const BOOL nextBraceMatchingEnabled = braceMatching && !overBudget;
    NSString *effectiveName = overBudget ? @"null" : lexerName;
    Scintilla::ILexer5 *lexer = [effectiveName isEqualToString:@"plantuml"] ? DPCreatePlantUMLLexer() : [effectiveName isEqualToString:@"duckpadlog"] ? DPCreateLogLexer() : CreateLexer(effectiveName.UTF8String);
    if (lexer == nullptr) return NO;
    [self cancelPendingSmartIndentation];
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    _braceMatchingEnabled = nextBraceMatchingEnabled;
    _plainTextIndentationEnabled = !_binaryDocument && [lexerName isEqualToString:@"null"];
    _smartEditingEnabled = _braceMatchingEnabled
        && ![effectiveName isEqualToString:@"null"];
    [self updateModificationEventMask];
    _semanticStyleRoles.clear();
    const int namedStyles = lexer->NamedStyles();
    for (int style = 0; style < namedStyles; style += 1) {
        std::string semantic;
        if (const char *name = lexer->NameOfStyle(style)) semantic += name;
        if (const char *tags = lexer->TagsOfStyle(style)) semantic += tags;
        if (const char *description = lexer->DescriptionOfStyle(style)) semantic += description;
        std::transform(semantic.begin(), semantic.end(), semantic.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        int role = 0;
        if (semantic.find("error") != std::string::npos || semantic.find("bad") != std::string::npos
            || semantic.find("unterminated") != std::string::npos) role = 6;
        else if (semantic.find("comment") != std::string::npos) role = 1;
        else if (semantic.find("number") != std::string::npos) role = 2;
        else if (semantic.find("keyword") != std::string::npos || semantic.find("word") != std::string::npos) role = 3;
        else if (semantic.find("string") != std::string::npos || semantic.find("character") != std::string::npos) role = 4;
        else if (semantic.find("operator") != std::string::npos || semantic.find("brace") != std::string::npos) role = 5;
        else if (semantic.find("property") != std::string::npos || semantic.find("attribute") != std::string::npos
                 || semantic.find("tag") != std::string::npos) role = 7;
        _semanticStyleRoles.emplace_back(style, role);
    }
    if (namedStyles == 0) DPAppendLegacyStyleRoles(effectiveName.UTF8String, _semanticStyleRoles);
    // Legacy Markdown has style IDs but does not publish NamedStyles metadata.
    if ([effectiveName isEqualToString:@"markdown"]) {
        for (int style = SCE_MARKDOWN_DEFAULT; style <= SCE_MARKDOWN_CODEBK; ++style) {
            int role = 0;
            if (style >= SCE_MARKDOWN_HEADER1 && style <= SCE_MARKDOWN_HEADER6) role = 3;
            else if (style == SCE_MARKDOWN_STRONG1 || style == SCE_MARKDOWN_STRONG2) role = 3;
            else if (style == SCE_MARKDOWN_EM1 || style == SCE_MARKDOWN_EM2 || style == SCE_MARKDOWN_BLOCKQUOTE) role = 1;
            else if (style >= SCE_MARKDOWN_CODE && style <= SCE_MARKDOWN_CODEBK) role = 4;
            else if (style == SCE_MARKDOWN_LINK || style == SCE_MARKDOWN_ULIST_ITEM
                     || style == SCE_MARKDOWN_OLIST_ITEM || style == SCE_MARKDOWN_HRULE) role = 5;
            _semanticStyleRoles.emplace_back(style, role);
        }
    }
    if ([_lexerName isEqualToString:@"duckpadlog"] && ![effectiveName isEqualToString:@"duckpadlog"]) {
        for (int indicator : {DPLogForegroundIndicator, DPLogBackgroundIndicator}) {
            [_scintilla message:SCI_SETINDICATORCURRENT wParam:indicator];
            [_scintilla message:SCI_INDICATORCLEARRANGE wParam:0 lParam:self.documentByteLength];
        }
    }
    _collapseAllFoldsAfterStyling = NO;
    [_scintilla message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(DPWrapAsyncLexer(lexer))];
    [_colorPreview closeChooser];
    _lexerName = [effectiveName copy];
    // ANSI foreground/background updates do not change glyph metrics. Retain
    // the visible line layouts while bounded colour slices arrive.
    [_scintilla message:SCI_SETLAYOUTCACHE wParam:_binaryDocument || [_lexerName isEqualToString:@"duckpadlog"] ? SC_CACHE_PAGE : SC_CACHE_NONE];
    if ([_lexerName isEqualToString:@"markdown"]) {
        [_scintilla message:SCI_SETPROPERTY
                     wParam:reinterpret_cast<uptr_t>("lexer.markdown.header.eolfill")
                     lParam:reinterpret_cast<sptr_t>("1")];
    }
    _languageStylingFallback = overBudget && ![lexerName isEqualToString:@"null"];
    [_scintilla message:SCI_SETINDENT wParam:MAX(1, MIN(tabWidth, 16))];
    [_scintilla message:SCI_SETTABWIDTH wParam:MAX(1, MIN(tabWidth, 16))];
    [_scintilla message:SCI_SETUSETABS wParam:useTabs ? 1 : 0];
    const BOOL effectiveFolding = folding && !overBudget;
    _foldingEnabled = effectiveFolding;
    [_scintilla message:SCI_SETPROPERTY
                     wParam:reinterpret_cast<uptr_t>("fold")
                     lParam:reinterpret_cast<sptr_t>(effectiveFolding ? "1" : "0")];
    [_scintilla message:SCI_SETMARGINWIDTHN wParam:1 lParam:effectiveFolding ? 12 : 0];
    [_scintilla message:SCI_SETAUTOMATICFOLD
                 wParam:effectiveFolding ? SC_AUTOMATICFOLD_CHANGE : SC_AUTOMATICFOLD_NONE];
    if (!effectiveFolding) {
        if (!_binaryDocument) [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_EXPAND];
        _searchOverviewNeedsRefresh = YES;
        _foldRecoveryProgressPending = NO;
    }
    if (!_braceMatchingEnabled) [self updateBraceHighlight];
    for (NSUInteger index = 0; index < 16; index += 1) {
        [_scintilla message:SCI_SETKEYWORDS wParam:index lParam:reinterpret_cast<sptr_t>("")];
    }
    for (NSUInteger index = 0; index < keywords.count; index += 1) {
        [_scintilla message:SCI_SETKEYWORDS
                     wParam:index
                     lParam:reinterpret_cast<sptr_t>(keywords[index].UTF8String)];
    }
    [self applyPalette:_palette];
    [_scintilla message:SCI_SETIDLESTYLING wParam:SC_IDLESTYLING_AFTERVISIBLE];
    if (!overBudget) {
        const NSUInteger styleEnd = MIN(self.documentByteLength, DPMaximumSynchronousStyleBytes);
        [_scintilla message:SCI_COLOURISE wParam:0 lParam:styleEnd];
        _synchronouslyStyledByteCount += styleEnd;
    }
    return YES;
}

- (void)configureDisplayWithLineNumbers:(BOOL)lineNumbers
                       bookmarkMargin:(BOOL)bookmarkMargin
                 highlightCurrentLine:(BOOL)highlightCurrentLine
                           caretWidth:(NSInteger)caretWidth
                     caretBlinkPeriod:(NSInteger)caretBlinkPeriod
                 scrollBeyondLastLine:(BOOL)scrollBeyondLastLine
                       wrapIndentMode:(NSInteger)wrapIndentMode {
    _highlightCurrentLine = highlightCurrentLine;
    [self updateLineNumberMargin:lineNumbers];
    [_scintilla message:SCI_SETMARGINWIDTHN wParam:2 lParam:bookmarkMargin ? 12 : 0];
    [_scintilla message:SCI_SETCARETLINEVISIBLE wParam:highlightCurrentLine lParam:0];
    [_scintilla message:SCI_SETCARETWIDTH wParam:MIN(MAX(caretWidth, 1), 3) lParam:0];
    [_scintilla message:SCI_SETCARETPERIOD wParam:MIN(MAX(caretBlinkPeriod, 0), 2000) lParam:0];
    [_scintilla message:SCI_SETENDATLASTLINE wParam:!scrollBeyondLastLine lParam:0];
    const int wrapMode = wrapIndentMode == 1 ? SC_WRAPINDENT_SAME : (wrapIndentMode == 2 ? SC_WRAPINDENT_INDENT : SC_WRAPINDENT_FIXED);
    [_scintilla message:SCI_SETWRAPINDENTMODE wParam:wrapMode lParam:0];
}

- (void)configureIndentationSize:(NSUInteger)size tabWidth:(NSUInteger)width {
    [_scintilla message:SCI_SETINDENT wParam:MAX(1, MIN(size, 16))];
    [_scintilla message:SCI_SETTABWIDTH wParam:MAX(1, MIN(width, 16))];
}

- (void)configureIndentationWithWidth:(NSUInteger)width useTabs:(BOOL)useTabs {
    [_scintilla message:SCI_SETINDENT wParam:MAX(1, MIN(width, 16))];
    [_scintilla message:SCI_SETTABWIDTH wParam:MAX(1, MIN(width, 16))];
    [_scintilla message:SCI_SETUSETABS wParam:useTabs ? 1 : 0];
}

- (void)configureGuidesWithIndentation:(BOOL)indentation virtualSpace:(BOOL)virtualSpace edgeVisible:(BOOL)edgeVisible edgeColumn:(NSInteger)edgeColumn {
    [_scintilla message:SCI_SETINDENTATIONGUIDES wParam:indentation ? SC_IV_LOOKBOTH : SC_IV_NONE];
    [_scintilla message:SCI_SETVIRTUALSPACEOPTIONS wParam:virtualSpace ? SCVS_USERACCESSIBLE | SCVS_RECTANGULARSELECTION : SCVS_NONE];
    [_scintilla message:SCI_SETEDGEMODE wParam:edgeVisible ? EDGE_LINE : EDGE_NONE];
    [_scintilla message:SCI_SETEDGECOLUMN wParam:MIN(MAX(edgeColumn, 1), 500)];
}

- (void)applyPalette:(DPScintillaPalette)palette {
    _palette = palette;
    _searchOverview.markerColor = palette == DPScintillaPaletteDark || palette == DPScintillaPaletteHighContrastDark
        ? [NSColor colorWithSRGBRed:0.39 green:0.80 blue:0.53 alpha:0.48]
        : [NSColor colorWithSRGBRed:0.18 green:0.56 blue:0.29 alpha:0.42];
    _searchOverviewNeedsRefresh = YES;
    const BOOL dark = palette == DPScintillaPaletteDark || palette == DPScintillaPaletteHighContrastDark;
    const BOOL highContrast = palette == DPScintillaPaletteHighContrastLight || palette == DPScintillaPaletteHighContrastDark;
    [_minimap configureDark:dark highContrast:highContrast];
    [(DPEditorScroller *)_scintilla.scrollView.verticalScroller configureDark:dark highContrast:highContrast];
    [(DPEditorScroller *)_scintilla.scrollView.horizontalScroller configureDark:dark highContrast:highContrast];
    const int foreground = dark ? 0xE8E8E8 : 0x202020;
    // BGR counterparts of WorkspaceColors.editor; the gutter shares this surface.
    const int background = dark ? 0x332C28 : 0xFAFAFA;
    const int gutterBackground = background;
    const int gutterForeground = highContrast ? (dark ? 0xBEBEBE : 0x585858) : (dark ? 0x8E8278 : 0x96908A);
    [_scintilla message:SCI_SETEDGECOLOUR wParam:dark ? 0x505050 : 0xD0D0D0];
    const int caretLineBackground = dark ? 0x463C36 : 0xEDEDEE;
    const int comment = dark ? 0x7FD47F : 0x397A32;
    const int number = dark ? 0xD7A0F8 : 0x7C2F8E;
    const int keyword = dark ? 0xFFB36B : 0xA23B00;
    const int stringColour = dark ? 0x7DD6E8 : 0x176A7A;
    const int operatorColour = dark ? 0xA9C7FF : 0x204F9B;
    const int errorColour = dark ? 0x8080FF : 0x2020D0;
    const int propertyColour = dark ? 0xF7BD87 : 0xA05F30;
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:foreground];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:background];
    [_scintilla message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:reinterpret_cast<sptr_t>(_editorFontName.UTF8String)];
    [_scintilla message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:std::lround(_editorFontSize * 100)];
    // Let Scintilla verify fixed-width ASCII once per font instead of shaping
    // every character of a long line with CoreText on each edit. Unicode and
    // fonts that fail the width check retain the normal shaping path.
    [_scintilla message:SCI_STYLESETCHECKMONOSPACED wParam:STYLE_DEFAULT lParam:1];
    [_scintilla message:SCI_STYLECLEARALL];
    // Scintilla uses BGR. Keep indent guides quieter than text, with a stronger accessible palette.
    const int indentGuide = highContrast ? (dark ? 0x91837A : 0xACA098) : (dark ? 0x524944 : 0xE2DCD8);
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_INDENTGUIDE lParam:indentGuide];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_INDENTGUIDE lParam:background];
    // Search decorations belong to the document, while their appearance belongs to each pane.
    [DPWordOccurrenceHighlighter applyAppearanceToView:_scintilla dark:dark highContrast:highContrast];
    [_scintilla message:SCI_INDICSETSTYLE wParam:DPDeclarationIndicator lParam:INDIC_PLAIN];
    [_scintilla message:SCI_INDICSETFORE wParam:DPDeclarationIndicator lParam:dark ? 0xFFBC80 : 0xD56B00];
    [_scintilla message:SCI_INDICSETUNDER wParam:DPDeclarationIndicator lParam:0];
    [_scintilla message:SCI_INDICSETSTYLE wParam:DPSearchIndicator lParam:INDIC_ROUNDBOX];
    [_scintilla message:SCI_INDICSETFORE wParam:DPSearchIndicator lParam:dark ? 0x86CB63 : 0x70D880];
    [_scintilla message:SCI_INDICSETALPHA wParam:DPSearchIndicator lParam:highContrast ? 160 : 110];
    [_scintilla message:SCI_INDICSETOUTLINEALPHA wParam:DPSearchIndicator lParam:180];
    [_scintilla message:SCI_INDICSETUNDER wParam:DPSearchIndicator lParam:1];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:gutterForeground];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:gutterBackground];
    [_scintilla message:SCI_STYLESETFONT wParam:STYLE_LINENUMBER lParam:reinterpret_cast<sptr_t>(_editorFontName.UTF8String)];
    [_scintilla message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_LINENUMBER lParam:std::lround(MAX(6.0, _editorFontSize - 2) * 100)];
    [_scintilla message:SCI_SETMARGINBACKN wParam:0 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:2 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:3 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:4 lParam:gutterBackground];
    // Scintilla colour values are 0xBBGGRR: modified lines use blue in both palettes.
    const int modifiedColour = dark ? 0xF4B564 : 0xD57E24;
    const int changeColors[] = { dark ? 0xE8B574 : 0xB57838, dark ? 0x87BC72 : 0x528A36,
                                 modifiedColour, modifiedColour };
    for (int index = 0; index < 4; ++index) {
        const int marker = SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN + index;
        [_scintilla message:SCI_MARKERSETFORE wParam:marker lParam:changeColors[index]];
        [_scintilla message:SCI_MARKERSETBACK wParam:marker lParam:changeColors[index]];
    }
    [_scintilla message:SCI_SETFOLDMARGINCOLOUR wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_BRACELIGHT lParam:dark ? 0x80FFFF : 0x7A3D00];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_BRACELIGHT lParam:dark ? 0x503000 : 0xB8F1FF];
    [_scintilla message:SCI_STYLESETBOLD wParam:STYLE_BRACELIGHT lParam:1];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_BRACEBAD lParam:dark ? 0xA0A0FF : 0x0000CC];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_BRACEBAD lParam:dark ? 0x302060 : 0xD8D8FF];
    [_scintilla message:SCI_STYLESETBOLD wParam:STYLE_BRACEBAD lParam:1];
    for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; marker += 1) {
        [_scintilla message:SCI_MARKERSETFORE wParam:marker lParam:gutterForeground];
        [_scintilla message:SCI_MARKERSETBACK wParam:marker lParam:gutterForeground];
    }
    [_scintilla message:SCI_MARKERSETFORE wParam:DPBookmarkMarker lParam:dark ? 0x263238 : 0xFFFFFF];
    [_scintilla message:SCI_MARKERSETBACK wParam:DPBookmarkMarker lParam:dark ? 0x4AA3FF : 0x006EDC];
    for (const auto &[style, role] : _semanticStyleRoles) {
        if (style >= STYLE_DEFAULT && style <= STYLE_LASTPREDEFINED) continue;
        int colour = foreground;
        switch (role) {
            case 1: colour = comment; break;
            case 2: colour = number; break;
            case 3: colour = keyword; break;
            case 4: colour = stringColour; break;
            case 5: colour = operatorColour; break;
            case 6: colour = errorColour; break;
            case 7: colour = propertyColour; break;
            default: break;
        }
        [_scintilla message:SCI_STYLESETFORE wParam:style lParam:colour];
        [_scintilla message:SCI_STYLESETBOLD wParam:style lParam:highContrast && role == 3];
    }
    if ([_lexerName isEqualToString:@"duckpadlog"]) {
        const int roles[] = {foreground, dark ? 0xB0A89E : 0x706860, dark ? 0xD8ADD2 : 0x904F8A,
            dark ? 0xA1D19C : 0x387A25, dark ? 0x7CCCE8 : 0x0079A0,
            errorColour, errorColour, dark ? 0xC0B48C : 0x77662F,
            dark ? 0xD9A9C5 : 0x864A74, propertyColour};
        for (int role = 0; role < DPLogRoleCount; ++role) for (int attributes = 0; attributes < 8; ++attributes) {
            const int style = DPLogStyleBase + role * 8 + attributes;
            [_scintilla message:SCI_STYLESETFORE wParam:style lParam:roles[role]];
            [_scintilla message:SCI_STYLESETBOLD wParam:style lParam:(attributes & 1) || role == 5 || role == 6];
            [_scintilla message:SCI_STYLESETITALIC wParam:style lParam:(attributes & 2) != 0];
            [_scintilla message:SCI_STYLESETUNDERLINE wParam:style lParam:(attributes & 4) != 0];
        }
        [_scintilla message:SCI_STYLESETVISIBLE wParam:DPLogEscapeStyle lParam:0];
        [_scintilla message:SCI_INDICSETSTYLE wParam:DPLogForegroundIndicator lParam:INDIC_TEXTFORE];
        [_scintilla message:SCI_INDICSETFLAGS wParam:DPLogForegroundIndicator lParam:SC_INDICFLAG_VALUEFORE];
        [_scintilla message:SCI_INDICSETSTYLE wParam:DPLogBackgroundIndicator lParam:INDIC_FULLBOX];
        [_scintilla message:SCI_INDICSETFLAGS wParam:DPLogBackgroundIndicator lParam:SC_INDICFLAG_VALUEFORE];
        [_scintilla message:SCI_INDICSETUNDER wParam:DPLogBackgroundIndicator lParam:1];
        [_scintilla message:SCI_INDICSETALPHA wParam:DPLogBackgroundIndicator lParam:255];
        [_scintilla message:SCI_INDICSETOUTLINEALPHA wParam:DPLogBackgroundIndicator lParam:255];
        auto asRGB = [](int bgr) { return (bgr & 255) << 16 | (bgr & 0xFF00) | (bgr >> 16 & 255); };
        for (const auto &[key, value] : {std::pair{"duckpad.log.foreground", asRGB(foreground)},
                std::pair{"duckpad.log.background", asRGB(background)}, std::pair{"duckpad.log.dark", dark ? 1 : 0}}) {
            const std::string text = std::to_string(value);
            [_scintilla message:SCI_SETPROPERTY wParam:reinterpret_cast<uptr_t>(key) lParam:reinterpret_cast<sptr_t>(text.c_str())];
        }
    }
    if ([_lexerName isEqualToString:@"markdown"]) {
        for (int style = SCE_MARKDOWN_HEADER1; style <= SCE_MARKDOWN_HEADER6; ++style) {
            [_scintilla message:SCI_STYLESETBOLD wParam:style lParam:1];
        }
        for (int style : {SCE_MARKDOWN_STRONG1, SCE_MARKDOWN_STRONG2}) {
            [_scintilla message:SCI_STYLESETBOLD wParam:style lParam:1];
        }
        for (int style : {SCE_MARKDOWN_EM1, SCE_MARKDOWN_EM2, SCE_MARKDOWN_BLOCKQUOTE}) {
            [_scintilla message:SCI_STYLESETITALIC wParam:style lParam:1];
        }
        [_scintilla message:SCI_STYLESETUNDERLINE wParam:SCE_MARKDOWN_LINK lParam:1];
        for (int style : {SCE_MARKDOWN_CODE, SCE_MARKDOWN_CODE2, SCE_MARKDOWN_CODEBK}) {
            [_scintilla message:SCI_STYLESETBACK wParam:style lParam:caretLineBackground];
        }
    }
    [_scintilla message:SCI_SETCARETFORE wParam:highContrast ? (dark ? 0xFFFFFF : 0x000000) : foreground];
    [_scintilla message:SCI_SETCARETLINEVISIBLE wParam:_highlightCurrentLine lParam:0];
    [_scintilla message:SCI_SETCARETLINEBACK wParam:caretLineBackground lParam:0];
    [_scintilla message:SCI_SETCARETLINEBACKALPHA wParam:SC_ALPHA_NOALPHA lParam:0];
    [_scintilla message:SCI_SETSELBACK wParam:1 lParam:dark ? 0x704020 : 0xFFD8B0];
    [_scintilla setNeedsDisplay:YES];
}

- (NSData *)contentPrefixUTF8WithMaximumLength:(NSUInteger)maximumLength {
    const NSUInteger count = MIN(self.documentByteLength, maximumLength);
    NSMutableData *bytes = [NSMutableData dataWithLength:count + 1];
    [_scintilla message:SCI_GETTEXT wParam:count + 1 lParam:reinterpret_cast<sptr_t>(bytes.mutableBytes)];
    bytes.length = count;
    return bytes;
}

- (NSInteger)styleAtUTF8Position:(NSUInteger)position {
    if (position >= self.documentByteLength) return -1;
    return [_scintilla message:SCI_GETSTYLEINDEXAT wParam:position];
}
- (NSUInteger)foregroundColorForStyle:(NSInteger)style { return (NSUInteger)[_scintilla message:SCI_STYLEGETFORE wParam:style]; }
- (BOOL)configuredFoldingEnabled { return _foldingEnabled; }
- (BOOL)configuredBraceMatchingEnabled { return _braceMatchingEnabled; }

- (NSInteger)foldLevelAtLine:(NSUInteger)line {
    return [_scintilla message:SCI_GETFOLDLEVEL wParam:line];
}
- (BOOL)isFoldExpandedAtLine:(NSUInteger)line { return [_scintilla message:SCI_GETFOLDEXPANDED wParam:line] != 0; }

- (NSInteger)foldHeaderForLine:(NSInteger)line {
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    if (!_foldingEnabled || line < 0 || line >= lineCount) return -1;
    const NSInteger level = [_scintilla message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
    if ((level & SC_FOLDLEVELHEADERFLAG) != 0) return line;
    return [_scintilla message:SCI_GETFOLDPARENT wParam:(uptr_t)line];
}

- (NSInteger)currentFoldHeader {
    const NSInteger position = [_scintilla message:SCI_GETCURRENTPOS];
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:(uptr_t)position];
    return [self foldHeaderForLine:line];
}

- (NSArray<NSNumber *> *)contractedFoldHeaderLinesWithMaximumCount:(NSUInteger)maximumCount {
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    NSInteger line = [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:0];
    while (line >= 0 && lines.count < maximumCount) {
        [lines addObject:@(line)];
        line = [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:(uptr_t)(line + 1)];
    }
    return lines;
}

- (BOOL)isLineVisibleAtLine:(NSUInteger)line {
    if (line >= (NSUInteger)[_scintilla message:SCI_GETLINECOUNT]) return NO;
    return [_scintilla message:SCI_GETLINEVISIBLE wParam:line] != 0;
}

- (BOOL)hasContractedFolds {
    return _foldingEnabled && (_collapseAllFoldsAfterStyling
        || [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:0] >= 0);
}

- (BOOL)canCollapseCurrentFold {
    const NSInteger header = [self currentFoldHeader];
    return header >= 0 && [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] != 0;
}

- (BOOL)canExpandCurrentFold {
    const NSInteger header = [self currentFoldHeader];
    return header >= 0 && [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] == 0;
}

- (BOOL)setFoldHeader:(NSInteger)header expanded:(BOOL)expanded publishChange:(BOOL)publishChange {
    if (!_foldingEnabled || header < 0) return NO;
    if (publishChange) _collapseAllFoldsAfterStyling = NO;
    const BOOL wasExpanded = [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] != 0;
    if (wasExpanded == expanded) return NO;
    [_scintilla message:SCI_FOLDLINE
                 wParam:(uptr_t)header
                 lParam:expanded ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT];
    _searchOverviewNeedsRefresh = YES;
    [self refreshSearchOverview];
    const BOOL isExpanded = [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] != 0;
    if (isExpanded == wasExpanded) return NO;
    if (publishChange && self.onFoldStateChange) self.onFoldStateChange();
    return YES;
}

- (void)toggleFoldAtLine:(NSUInteger)line {
    const NSInteger header = [self foldHeaderForLine:(NSInteger)line];
    if (header < 0) return;
    const BOOL expanded = [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] != 0;
    [self setFoldHeader:header expanded:!expanded publishChange:YES];
}

- (BOOL)collapseCurrentFold {
    return [self setFoldHeader:[self currentFoldHeader] expanded:NO publishChange:YES];
}

- (BOOL)expandCurrentFold {
    return [self setFoldHeader:[self currentFoldHeader] expanded:YES publishChange:YES];
}

- (void)continueCollapseAllFoldsAtLine:(NSInteger)line insideFold:(BOOL)insideFold generation:(NSUInteger)generation {
    if (!_collapseAllFoldsAfterStyling || generation != _collapseAllFoldsGeneration
        || !_scintilla || self.asynchronousStylingPending) return;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(2);
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    NSInteger hideStart = -1;
    while (line < lineCount) {
        const NSInteger level = [_scintilla message:SCI_GETFOLDLEVEL wParam:line];
        const NSInteger number = level & SC_FOLDLEVELNUMBERMASK;
        const BOOL whitespace = (level & SC_FOLDLEVELWHITEFLAG) != 0;
        const BOOL subordinate = whitespace || number > SC_FOLDLEVELBASE;
        BOOL hide = insideFold && subordinate;
        if (!subordinate) insideFold = NO;
        // Match GetLastChild's trailing-whitespace adjustment on an outdent.
        if (hide && whitespace && ([_scintilla message:SCI_GETFOLDLEVEL wParam:line + 1]
            & SC_FOLDLEVELNUMBERMASK) < SC_FOLDLEVELBASE) {
            hide = NO;
            insideFold = NO;
        }
        if (hide && hideStart < 0) hideStart = line;
        if (!hide && hideStart >= 0) {
            [_scintilla message:SCI_HIDELINES wParam:hideStart lParam:line - 1];
            hideStart = -1;
        }
        if (level & SC_FOLDLEVELHEADERFLAG) {
            // FoldAll marks every header, including childless EOF headers, but
            // hides descendants only beneath base-level headers. Do not invoke
            // FoldLine's subtree walk or caret movement for each nested header.
            [_scintilla message:SCI_SETFOLDEXPANDED wParam:line lParam:0];
            if (number == SC_FOLDLEVELBASE) insideFold = YES;
        }
        ++line;
        if (line % 64 == 0 && std::chrono::steady_clock::now() >= deadline) break;
    }
    if (hideStart >= 0) [_scintilla message:SCI_HIDELINES wParam:hideStart lParam:line - 1];
    if (line < lineCount) {
        __weak DPScintillaEditorView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf continueCollapseAllFoldsAtLine:line insideFold:insideFold generation:generation];
        });
    } else {
        _collapseAllFoldsAfterStyling = NO;
        _searchOverviewNeedsRefresh = YES;
        [self refreshSearchOverview];
        if (self.onFoldStateChange) self.onFoldStateChange();
    }
}

- (BOOL)collapseAllFolds {
    if (!_foldingEnabled) return NO;
    if ((NSUInteger)[_scintilla message:SCI_GETENDSTYLED] < self.documentByteLength) {
        [_scintilla message:SCI_COLOURISE wParam:0 lParam:-1];
    }
    if (self.asynchronousStylingPending || _collapseAllFoldsAfterStyling) {
        _collapseAllFoldsAfterStyling = YES;
        const NSUInteger generation = ++_collapseAllFoldsGeneration;
        if (!self.asynchronousStylingPending) [self continueCollapseAllFoldsAtLine:0 insideFold:NO generation:generation];
        if (self.onFoldStateChange) self.onFoldStateChange();
        return YES;
    }
    NSArray<NSNumber *> *before = [self contractedFoldHeaderLinesWithMaximumCount:NSUIntegerMax];
    [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_CONTRACT_EVERY_LEVEL];
    _searchOverviewNeedsRefresh = YES;
    [self refreshSearchOverview];
    NSArray<NSNumber *> *after = [self contractedFoldHeaderLinesWithMaximumCount:NSUIntegerMax];
    if ([before isEqualToArray:after]) return NO;
    if (self.onFoldStateChange) self.onFoldStateChange();
    return YES;
}

- (BOOL)expandAllFolds {
    const BOOL cancelledPendingCollapse = _collapseAllFoldsAfterStyling;
    _collapseAllFoldsAfterStyling = NO;
    if (!self.hasContractedFolds) {
        if (cancelledPendingCollapse && self.onFoldStateChange) self.onFoldStateChange();
        return cancelledPendingCollapse;
    }
    [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_EXPAND];
    _searchOverviewNeedsRefresh = YES;
    [self refreshSearchOverview];
    if (self.onFoldStateChange) self.onFoldStateChange();
    return YES;
}

- (NSArray<NSNumber *> *)restoreContractedFoldHeaderLines:(NSArray<NSNumber *> *)lines {
    if (!_foldingEnabled || lines.count == 0
        || lines.count > DPMaximumFoldRecoveryHeaderCount) {
        _foldRecoveryProgressPending = NO;
        return @[];
    }
    const NSUInteger styleEnd = MIN(self.documentByteLength, DPMaximumSynchronousStyleBytes);
    if ((NSUInteger)[_scintilla message:SCI_GETENDSTYLED] < styleEnd) {
        [_scintilla message:SCI_COLOURISE wParam:0 lParam:styleEnd];
        _synchronouslyStyledByteCount += styleEnd;
    }
    const NSInteger endStyled = [_scintilla message:SCI_GETENDSTYLED];
    const NSInteger lineCount = [_scintilla message:SCI_GETLINECOUNT];
    NSMutableArray<NSNumber *> *pending = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (NSNumber *number in lines) {
        NSInteger candidate;
        if (!DPIntegerFromNumber(number, &candidate)) continue;
        if (candidate < 0 || candidate >= lineCount) continue;
        NSNumber *canonical = @(candidate);
        if ([seen containsObject:canonical]) continue;
        [seen addObject:canonical];
        const NSInteger line = candidate;
        const NSInteger lineEnd = [_scintilla message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
        if (self.asynchronousStylingPending || lineEnd > endStyled) {
            [pending addObject:canonical];
            continue;
        }
        const NSInteger level = [_scintilla message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if ((level & SC_FOLDLEVELHEADERFLAG) == 0) continue;
        [self setFoldHeader:line expanded:NO publishChange:NO];
    }
    _foldRecoveryProgressPending = pending.count > 0;
    return pending;
}

- (void)scheduleFoldRecoveryProgress {
    if (!_foldRecoveryProgressPending || _foldRecoveryProgressScheduled
        || self.onFoldRecoveryProgress == nil) return;
    _foldRecoveryProgressScheduled = YES;
    __weak DPScintillaEditorView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        DPScintillaEditorView *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_foldRecoveryProgressScheduled = NO;
        if (!strongSelf->_foldRecoveryProgressPending) return;
        void (^progress)(void) = strongSelf.onFoldRecoveryProgress;
        if (progress) progress();
    });
}

- (void)updateBraceHighlight {
    if (!_braceMatchingEnabled) {
        [_scintilla message:SCI_BRACEHIGHLIGHT wParam:-1 lParam:-1];
        _highlightedBraceUTF8Position = -1;
        _matchingBraceUTF8Position = -1;
        _badBraceUTF8Position = -1;
        return;
    }
    const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
    NSInteger brace = -1;
    const auto isBrace = [](NSInteger character) {
        return character == '(' || character == ')' || character == '[' || character == ']'
            || character == '{' || character == '}';
    };
    if (caret > 0) {
        const NSInteger before = [_scintilla message:SCI_GETCHARAT wParam:caret - 1];
        if (isBrace(before)) brace = caret - 1;
    }
    if (brace < 0) {
        const NSInteger at = [_scintilla message:SCI_GETCHARAT wParam:caret];
        if (isBrace(at)) brace = caret;
    }
    if (brace < 0) {
        [_scintilla message:SCI_BRACEHIGHLIGHT wParam:-1 lParam:-1];
        _highlightedBraceUTF8Position = -1;
        _matchingBraceUTF8Position = -1;
        _badBraceUTF8Position = -1;
        return;
    }
    const NSInteger matching = [_scintilla message:SCI_BRACEMATCH wParam:brace lParam:0];
    if (matching < 0) {
        [_scintilla message:SCI_BRACEBADLIGHT wParam:brace];
        _highlightedBraceUTF8Position = -1;
        _matchingBraceUTF8Position = -1;
        _badBraceUTF8Position = brace;
    } else {
        [_scintilla message:SCI_BRACEHIGHLIGHT wParam:brace lParam:matching];
        _highlightedBraceUTF8Position = brace;
        _matchingBraceUTF8Position = matching;
        _badBraceUTF8Position = -1;
    }
}

- (BOOL)toggleLineCommentsWithPrefixUTF8:(NSData *)prefix {
    if (prefix.length == 0 || [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding] == nil) return NO;
    const NSInteger anchor = [_scintilla message:SCI_GETANCHOR];
    const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
    const NSInteger lower = MIN(anchor, caret);
    const NSInteger upper = MAX(anchor, caret);
    NSInteger firstLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:lower];
    NSInteger lastLine = [_scintilla message:SCI_LINEFROMPOSITION wParam:upper];
    if (upper > lower && [_scintilla message:SCI_POSITIONFROMLINE wParam:lastLine] == upper) lastLine -= 1;
    if (lastLine < firstLine) lastLine = firstLine;

    struct LineEdit { NSUInteger position; BOOL remove; };
    std::vector<LineEdit> edits;
    BOOL allCommented = YES;
    for (NSInteger line = firstLine; line <= lastLine; line += 1) {
        const NSInteger start = [_scintilla message:SCI_POSITIONFROMLINE wParam:line];
        const NSInteger end = [_scintilla message:SCI_GETLINEENDPOSITION wParam:line];
        const NSInteger indent = [_scintilla message:SCI_GETLINEINDENTPOSITION wParam:line];
        if (end <= indent) continue;
        BOOL hasPrefix = indent + (NSInteger)prefix.length <= end;
        for (NSUInteger index = 0; hasPrefix && index < prefix.length; index += 1) {
            const NSInteger character = [_scintilla message:SCI_GETCHARAT wParam:indent + index];
            _commentCommandInspectedByteCount += 1;
            if (character != ((const unsigned char *)prefix.bytes)[index]) hasPrefix = NO;
        }
        edits.push_back({static_cast<NSUInteger>(indent), hasPrefix});
        if (!hasPrefix) allCommented = NO;
        _commentCommandInspectedByteCount += static_cast<NSUInteger>(MAX(0, indent - start));
    }
    if (edits.empty()) return YES;
    [_scintilla message:SCI_BEGINUNDOACTION];
    for (auto iterator = edits.rbegin(); iterator != edits.rend(); ++iterator) {
        const NSUInteger removeLength = allCommented ? prefix.length : 0;
        [_scintilla message:SCI_SETTARGETSTART wParam:iterator->position];
        [_scintilla message:SCI_SETTARGETEND wParam:iterator->position + removeLength];
        static const char empty = '\0';
        const void *bytes = allCommented ? static_cast<const void *>(&empty) : prefix.bytes;
        const NSUInteger length = allCommented ? 0 : prefix.length;
        [_scintilla message:SCI_REPLACETARGET wParam:length lParam:reinterpret_cast<sptr_t>(bytes)];
    }
    [_scintilla message:SCI_ENDUNDOACTION];
    return YES;
}

+ (BOOL)blockCommentSupportsSelectionShape:(DPScintillaSelectionShape)shape
                                     count:(NSUInteger)count
                         caretVirtualSpace:(NSUInteger)caretVirtualSpace
                        anchorVirtualSpace:(NSUInteger)anchorVirtualSpace {
    return shape == DPScintillaSelectionShapeStream
        && count == 1
        && caretVirtualSpace == 0
        && anchorVirtualSpace == 0;
}

- (BOOL)canToggleBlockCommentsWithStartUTF8:(NSData *)start
                                    endUTF8:(NSData *)end
                             selectionOwner:(DPScintillaEditorView *)selectionOwner {
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil) {
        return [publisher canToggleBlockCommentsWithStartUTF8:start
                                                       endUTF8:end
                                                selectionOwner:selectionOwner];
    }
    if (!_publishesDocumentEdits) return NO;
    if (!DPBlockCommentDelimiterIsValid(start) || !DPBlockCommentDelimiterIsValid(end)
        || _scintilla == nil || selectionOwner == nil || selectionOwner->_scintilla == nil
        || !self.isInputEnabled || !selectionOwner.isInputEnabled
        || self.revision == UINT64_MAX || selectionOwner.revision != self.revision
        || selectionOwner.hasMarkedText) {
        return NO;
    }
    // One aggregate forward edit may be followed by two raw SCN_MODIFIED
    // components when native Undo restores its replace target.
    if (_revision > UINT64_MAX - DPBlockCommentRequiredRevisionBudget) return NO;
    if ([_scintilla message:SCI_GETDOCPOINTER]
        != [selectionOwner->_scintilla message:SCI_GETDOCPOINTER]) {
        return NO;
    }
    const sptr_t selectionCount = [selectionOwner->_scintilla message:SCI_GETSELECTIONS];
    const sptr_t caretVirtualSpace = [selectionOwner->_scintilla
        message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:0];
    const sptr_t anchorVirtualSpace = [selectionOwner->_scintilla
        message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:0];
    if (selectionCount < 0 || caretVirtualSpace < 0 || anchorVirtualSpace < 0) return NO;
    const DPScintillaSelectionShape shape = DPSelectionShapeFromScintilla(
        [selectionOwner->_scintilla message:SCI_GETSELECTIONMODE]
    );
    if (![DPScintillaEditorView blockCommentSupportsSelectionShape:shape
                                                              count:(NSUInteger)selectionCount
                                                  caretVirtualSpace:(NSUInteger)caretVirtualSpace
                                                 anchorVirtualSpace:(NSUInteger)anchorVirtualSpace]) {
        return NO;
    }
    const NSUInteger documentLength = self.documentByteLength;
    const NSUInteger anchor = selectionOwner.anchorUTF8Position;
    const NSUInteger caret = selectionOwner.caretUTF8Position;
    if (anchor > documentLength || caret > documentLength) return NO;
    return [self isUTF8Boundary:anchor documentLength:documentLength]
        && [self isUTF8Boundary:caret documentLength:documentLength];
}

- (BOOL)applyAggregateUserEditInRange:(NSRange)range
                       selectionOwner:(DPScintillaEditorView *)selectionOwner
                 resultingAnchorUTF8:(NSUInteger)anchor
                  resultingCaretUTF8:(NSUInteger)caret
              replacementBuilder:(DPScintillaAggregateReplacementBuilder)replacementBuilder {
    return [self applyAggregateUserEditInRange:range selectionOwner:selectionOwner
        resultingAnchorUTF8:anchor resultingCaretUTF8:caret preserveSelection:NO replacementBuilder:replacementBuilder];
}

- (BOOL)applyAggregateUserEditInRange:(NSRange)range
                       selectionOwner:(DPScintillaEditorView *)selectionOwner
                 resultingAnchorUTF8:(NSUInteger)anchor
                  resultingCaretUTF8:(NSUInteger)caret
                   preserveSelection:(BOOL)preserveSelection
              replacementBuilder:(DPScintillaAggregateReplacementBuilder)replacementBuilder {
    if (replacementBuilder == nil || _scintilla == nil || selectionOwner == nil
        || selectionOwner->_scintilla == nil || !selectionOwner.isInputEnabled
        || selectionOwner.hasMarkedText || ![self preflightUserMutation]) {
        return NO;
    }
    if ([_scintilla message:SCI_GETDOCPOINTER]
        != [selectionOwner->_scintilla message:SCI_GETDOCPOINTER]) {
        return NO;
    }
    const NSUInteger documentLength = self.documentByteLength;
    if (range.location > documentLength || range.length > documentLength - range.location
        || range.length == NSUIntegerMax) {
        return NO;
    }
    const NSUInteger rangeEnd = range.location + range.length;
    if (![self isUTF8Boundary:range.location documentLength:documentLength]
        || ![self isUTF8Boundary:rangeEnd documentLength:documentLength]) {
        return NO;
    }
    NSMutableData *deleted = [NSMutableData dataWithLength:range.length + 1];
    Sci_TextRangeFull textRange = {
        { static_cast<Sci_Position>(range.location), static_cast<Sci_Position>(rangeEnd) },
        static_cast<char *>(deleted.mutableBytes)
    };
    [_scintilla message:SCI_GETTEXTRANGEFULL
                 wParam:0
                 lParam:reinterpret_cast<sptr_t>(&textRange)];
    deleted.length = range.length;

    NSData *replacement = replacementBuilder(deleted);
    if (replacement == nil
        || [[NSString alloc] initWithData:replacement encoding:NSUTF8StringEncoding] == nil) {
        return NO;
    }
    if (replacement.length > NSUIntegerMax - deleted.length
        || _incrementalNotificationCount == NSUIntegerMax
        || _incrementalPayloadByteCount > NSUIntegerMax - (deleted.length + replacement.length)) {
        return NO;
    }
    const NSUInteger retainedLength = documentLength - range.length;
    if (replacement.length > NSUIntegerMax - retainedLength) return NO;
    const NSUInteger resultingLength = retainedLength + replacement.length;
    if (anchor > resultingLength || caret > resultingLength) return NO;

    const NSInteger viewportLine = [selectionOwner->_scintilla message:SCI_GETFIRSTVISIBLELINE];
    const NSInteger viewportX = [selectionOwner->_scintilla message:SCI_GETXOFFSET];
    const uint64_t baseRevision = _revision;
    if (baseRevision == UINT64_MAX) return NO;
    if (_publishesDocumentEdits && self.onWillModifyDocument) {
        self.onWillModifyDocument();
    }
    const BOOL wasSuppressingEdit = _suppressEdit;
    _suppressEdit = YES;
    @try {
        [_scintilla message:SCI_SETTARGETSTART wParam:(uptr_t)range.location];
        [_scintilla message:SCI_SETTARGETEND wParam:(uptr_t)rangeEnd];
        static const char emptyReplacement = '\0';
        const void *replacementBytes = replacement.length > 0 ? replacement.bytes : &emptyReplacement;
        [_scintilla message:SCI_REPLACETARGET
                     wParam:(uptr_t)replacement.length
                     lParam:(sptr_t)replacementBytes];
        if (_foldingEnabled) {
            const NSInteger changedLine = [_scintilla message:SCI_LINEFROMPOSITION
                                                        wParam:(uptr_t)range.location];
            const NSInteger lineStart = [_scintilla message:SCI_POSITIONFROMLINE
                                                      wParam:(uptr_t)changedLine];
            const NSInteger nextLineStart = changedLine + 1 < (NSInteger)self.lineCount
                ? [_scintilla message:SCI_POSITIONFROMLINE wParam:(uptr_t)(changedLine + 1)]
                : (NSInteger)self.documentByteLength;
            [_scintilla message:SCI_COLOURISE wParam:(uptr_t)lineStart lParam:nextLineStart];
        }
        if (!preserveSelection) {
            [selectionOwner->_scintilla message:SCI_SETSEL wParam:(uptr_t)anchor lParam:(sptr_t)caret];
            [selectionOwner->_scintilla message:SCI_SCROLLCARET];
        } else {
            // Native ReplaceTarget adjusts all selection positions without discarding
            // rectangular/line mode, virtual columns, or secondary carets.
            [selectionOwner->_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:viewportLine];
            [selectionOwner->_scintilla message:SCI_SETXOFFSET wParam:viewportX];
        }
    } @finally {
        _suppressEdit = wasSuppressingEdit;
    }

    _revision = baseRevision + 1;
    if (_revision == UINT64_MAX) [_scintilla setEditable:NO];
    _incrementalNotificationCount += 1;
    _incrementalPayloadByteCount += deleted.length + replacement.length;
    DPScintillaEdit *edit = [[DPScintillaEdit alloc] initWithRange:range
                                                      insertedUTF8:replacement
                                                       deletedUTF8:deleted
                                                      baseRevision:baseRevision
                                                 resultingRevision:_revision
                                                            origin:DPScintillaEditOriginUser];
    if (self.onEdit) self.onEdit(edit);
    return YES;
}

- (BOOL)toggleBlockCommentsWithStartUTF8:(NSData *)start
                                 endUTF8:(NSData *)end
                          selectionOwner:(DPScintillaEditorView *)selectionOwner {
    DPScintillaEditorView *publisher = _documentPublisher;
    if (publisher != nil) {
        return [publisher toggleBlockCommentsWithStartUTF8:start
                                                   endUTF8:end
                                            selectionOwner:selectionOwner];
    }
    if (!_publishesDocumentEdits) return NO;
    if (![self preflightUserMutation]
        || ![self canToggleBlockCommentsWithStartUTF8:start
                                               endUTF8:end
                                        selectionOwner:selectionOwner]) {
        return NO;
    }

    const NSUInteger documentLength = self.documentByteLength;
    const NSUInteger originalAnchor = selectionOwner.anchorUTF8Position;
    const NSUInteger originalCaret = selectionOwner.caretUTF8Position;
    const NSUInteger lower = MIN(originalAnchor, originalCaret);
    const NSUInteger upper = MAX(originalAnchor, originalCaret);
    const BOOL isReversed = originalAnchor > originalCaret;
    if (start.length > NSUIntegerMax - end.length) return NO;
    const NSUInteger delimiterLength = start.length + end.length;

    if (lower == upper) {
        const BOOL hasAdjacentPair = lower >= start.length
            && end.length <= documentLength - lower
        && DPScintillaBytesMatch(_scintilla, lower - start.length, start)
            && DPScintillaBytesMatch(_scintilla, lower, end);
        if (hasAdjacentPair) {
            const NSRange range = NSMakeRange(lower - start.length, delimiterLength);
            const NSUInteger caret = lower - start.length;
            return [self applyAggregateUserEditInRange:range
                                        selectionOwner:selectionOwner
                                  resultingAnchorUTF8:caret
                                   resultingCaretUTF8:caret
                               replacementBuilder:^NSData * _Nullable(NSData *deletedUTF8) {
                if (deletedUTF8.length != delimiterLength
                    || ![[deletedUTF8 subdataWithRange:NSMakeRange(0, start.length)] isEqualToData:start]
                    || ![[deletedUTF8 subdataWithRange:NSMakeRange(start.length, end.length)] isEqualToData:end]) {
                    return nil;
                }
                return [NSData data];
            }];
        }
        const NSUInteger insertionLength = delimiterLength;
        if (insertionLength > NSUIntegerMax - documentLength
            || start.length > NSUIntegerMax - lower) {
            return NO;
        }
        const NSUInteger caret = lower + start.length;
        return [self applyAggregateUserEditInRange:NSMakeRange(lower, 0)
                                    selectionOwner:selectionOwner
                              resultingAnchorUTF8:caret
                               resultingCaretUTF8:caret
                           replacementBuilder:^NSData * _Nullable(NSData *deletedUTF8) {
            if (deletedUTF8.length != 0) return nil;
            NSMutableData *replacement = [NSMutableData dataWithCapacity:insertionLength];
            [replacement appendData:start];
            [replacement appendData:end];
            return replacement;
        }];
    }

    const NSUInteger selectedLength = upper - lower;
    const BOOL unwrap = selectedLength >= delimiterLength
        && DPScintillaBytesMatch(_scintilla, lower, start)
        && DPScintillaBytesMatch(_scintilla, upper - end.length, end);
    NSUInteger replacementLength = 0;
    if (unwrap) {
        replacementLength = selectedLength - delimiterLength;
    } else {
        if (selectedLength > NSUIntegerMax - delimiterLength) return NO;
        replacementLength = selectedLength + delimiterLength;
    }
    if (replacementLength > NSUIntegerMax - (documentLength - selectedLength)) {
        return NO;
    }
    const NSUInteger selectionEnd = lower + replacementLength;
    const NSUInteger resultingAnchor = isReversed ? selectionEnd : lower;
    const NSUInteger resultingCaret = isReversed ? lower : selectionEnd;
    return [self applyAggregateUserEditInRange:NSMakeRange(lower, selectedLength)
                                selectionOwner:selectionOwner
                          resultingAnchorUTF8:resultingAnchor
                           resultingCaretUTF8:resultingCaret
                       replacementBuilder:^NSData * _Nullable(NSData *deletedUTF8) {
        if (deletedUTF8.length != selectedLength) return nil;
        if (unwrap) {
            return [deletedUTF8 subdataWithRange:NSMakeRange(
                start.length,
                selectedLength - delimiterLength
            )];
        }
        NSMutableData *replacement = [NSMutableData dataWithCapacity:replacementLength];
        [replacement appendData:start];
        [replacement appendData:deletedUTF8];
        [replacement appendData:end];
        return replacement;
    }];
}

- (void)finishPendingSmartIndentation {
    const BOOL hasPending = _pendingSmartIndentationInsertionPosition >= 0
        || _pendingSmartIndentationUndoGroupOpen;
    if (!hasPending) return;
    DPScintillaEditorView *publisher = _pendingSmartIndentationPublisher;
    if (_pendingSmartIndentationUndoGroupOpen && _scintilla != nil) {
        [_scintilla message:SCI_ENDUNDOACTION];
    }
    if (publisher != nil) {
        publisher->_suppressEdit = _pendingSmartIndentationPublisherWasSuppressingEdit;
    }
    _pendingSmartIndentationInsertionPosition = -1;
    _pendingSmartIndentationRange = NSMakeRange(0, 0);
    _pendingSmartIndentationOriginalUTF8 = nil;
    _pendingSmartIndentationReplacementUTF8 = nil;
    _pendingSmartIndentationExpectedPostInsertCaret = -1;
    _pendingSmartIndentationCloser = 0;
    _pendingSmartIndentationBaseRevision = 0;
    _pendingSmartIndentationUndoGroupOpen = NO;
    _pendingSmartIndentationPublisher = nil;
    _pendingSmartIndentationPublisherWasSuppressingEdit = NO;
    _pendingSmartIndentationCharacterAdded = NO;
    _pendingSmartIndentationSuppressedNativeComponentCount = 0;
    _pendingSmartIndentationApplyingReplacement = NO;
    if (self.onSmartIndentationStateChange) self.onSmartIndentationStateChange(NO);
}

- (void)cancelPendingSmartIndentation {
    [self finishPendingSmartIndentation];
}

- (BOOL)prepareClosingDelimiterDedent:(SCNotification *)notification {
    if (!_smartEditingEnabled || !_textInputSourceKnown || !_directInputInsertion
        || !_directInputByteLengthKnown || _directInputByteLength != 1
        || !_directInputSelectionEligible || [[_scintilla content] hasMarkedText]
        || notification->text == nullptr || notification->length != 1) {
        return NO;
    }
    const int closer = static_cast<unsigned char>(notification->text[0]);
    if (!DPIsClosingDelimiter(closer)) return NO;

    DPScintillaEditorView *publisher = _documentPublisher ?: self;
    if (publisher == nil || _scintilla == nil || publisher->_scintilla == nil
        || !self.isInputEnabled || !publisher.isInputEnabled
        || publisher->_revision != _revision
        || publisher->_revision > UINT64_MAX - DPSmartCloserRequiredRevisionBudget
        || [_scintilla message:SCI_GETDOCPOINTER]
            != [publisher->_scintilla message:SCI_GETDOCPOINTER]) {
        return NO;
    }

    const sptr_t selectionCount = [_scintilla message:SCI_GETSELECTIONS];
    const sptr_t caretVirtualSpace = [_scintilla
        message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:0];
    const sptr_t anchorVirtualSpace = [_scintilla
        message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:0];
    const NSInteger anchor = [_scintilla message:SCI_GETANCHOR];
    const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
    if (selectionCount != 1 || caretVirtualSpace != 0 || anchorVirtualSpace != 0
        || anchor != caret
        || DPSelectionShapeFromScintilla([_scintilla message:SCI_GETSELECTIONMODE])
            != DPScintillaSelectionShapeStream) {
        return NO;
    }

    const NSInteger insertionPosition = notification->position;
    if (insertionPosition < 0 || insertionPosition != caret
        || insertionPosition == NSIntegerMax) {
        return NO;
    }
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION
                                        wParam:(uptr_t)insertionPosition];
    const NSInteger lineStart = [_scintilla message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    if (lineStart < 0 || lineStart > insertionPosition) return NO;
    const NSUInteger prefixLength = static_cast<NSUInteger>(insertionPosition - lineStart);
    if (prefixLength == 0 || prefixLength > DPSmartIndentScanLimit) return NO;

    std::string original;
    original.reserve(prefixLength);
    for (NSUInteger index = 0; index < prefixLength; index += 1) {
        const int character = static_cast<int>([_scintilla message:SCI_GETCHARAT
                                                        wParam:(uptr_t)(lineStart + (NSInteger)index)]);
        if (character != ' ' && character != '\t') return NO;
        original.push_back(static_cast<char>(character));
    }

    const NSUInteger tabWidth = static_cast<NSUInteger>(MAX(1, [_scintilla message:SCI_GETTABWIDTH]));
    const NSUInteger currentColumns = DPIndentationColumns(original, tabWidth);
    if (currentColumns == 0) return NO;
    const NSUInteger indentWidth = static_cast<NSUInteger>(MAX(1, [_scintilla message:SCI_GETINDENT]));
    const NSUInteger targetColumns = currentColumns > indentWidth ? currentColumns - indentWidth : 0;
    if (targetColumns >= currentColumns) return NO;
    const std::string replacement = DPCanonicalIndentation(
        targetColumns,
        tabWidth,
        [_scintilla message:SCI_GETUSETABS] != 0
    );
    if (replacement == original) return NO;

    _pendingSmartIndentationInsertionPosition = insertionPosition;
    _pendingSmartIndentationRange = NSMakeRange((NSUInteger)lineStart, prefixLength);
    _pendingSmartIndentationOriginalUTF8 = [NSData dataWithBytes:original.data() length:original.size()];
    _pendingSmartIndentationReplacementUTF8 = [NSData dataWithBytes:replacement.data() length:replacement.size()];
    _pendingSmartIndentationExpectedPostInsertCaret = insertionPosition + 1;
    _pendingSmartIndentationCloser = closer;
    _pendingSmartIndentationBaseRevision = publisher->_revision;
    _pendingSmartIndentationUndoGroupOpen = YES;
    _pendingSmartIndentationPublisher = publisher;
    _pendingSmartIndentationPublisherWasSuppressingEdit = publisher->_suppressEdit;
    _pendingSmartIndentationCharacterAdded = NO;
    _pendingSmartIndentationSuppressedNativeComponentCount = 1;
    _pendingSmartIndentationApplyingReplacement = NO;
    publisher->_suppressEdit = YES;
    [_scintilla message:SCI_BEGINUNDOACTION];
    if (self.onSmartIndentationStateChange) self.onSmartIndentationStateChange(YES);
    return YES;
}

- (BOOL)publishPendingSmartCloser {
    DPScintillaEditorView *publisher = _pendingSmartIndentationPublisher;
    const NSInteger position = _pendingSmartIndentationInsertionPosition;
    if (publisher == nil || publisher->_scintilla == nil || position < 0
        || _pendingSmartIndentationCloser == 0
        || publisher->_revision != _pendingSmartIndentationBaseRevision
        || _revision != _pendingSmartIndentationBaseRevision
        || [_scintilla message:SCI_GETCHARAT wParam:(uptr_t)position]
            != _pendingSmartIndentationCloser
        || publisher->_incrementalNotificationCount == NSUIntegerMax
        || publisher->_incrementalPayloadByteCount == NSUIntegerMax) {
        return NO;
    }
    const uint64_t baseRevision = publisher->_revision;
    if (baseRevision == UINT64_MAX) return NO;
    const unsigned char closer = static_cast<unsigned char>(_pendingSmartIndentationCloser);
    NSData *inserted = [NSData dataWithBytes:&closer length:1];
    publisher->_revision = baseRevision + 1;
    if (publisher->_revision == UINT64_MAX) [publisher->_scintilla setEditable:NO];
    publisher->_incrementalNotificationCount += 1;
    publisher->_incrementalPayloadByteCount += inserted.length;
    DPScintillaEdit *edit = [[DPScintillaEdit alloc] initWithRange:NSMakeRange((NSUInteger)position, 0)
                                                      insertedUTF8:inserted
                                                       deletedUTF8:[NSData data]
                                                      baseRevision:baseRevision
                                                 resultingRevision:publisher->_revision
                                                            origin:DPScintillaEditOriginUser];
    if (publisher.onEdit) publisher.onEdit(edit);
    return YES;
}

- (void)handleSmartCharacterAdded:(SCNotification *)notification {
    DPScintillaEditorView *directInputInitiator = _directInputInitiator;
    if (directInputInitiator != nil && directInputInitiator != self
        && (directInputInitiator->_pendingSmartIndentationInsertionPosition >= 0
            || directInputInitiator->_pendingSmartCaretPosition >= 0)) {
        [directInputInitiator handleSmartCharacterAdded:notification];
        return;
    }
    if (_pendingSmartIndentationInsertionPosition >= 0) {
        DPScintillaEditorView *publisher = _pendingSmartIndentationPublisher;
        const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
        const uint64_t expectedCloserRevision = _pendingSmartIndentationBaseRevision + 1;
        if (publisher == nil
            || notification->characterSource != SC_CHARACTERSOURCE_DIRECT_INPUT
            || notification->ch != _pendingSmartIndentationCloser
            || caret != _pendingSmartIndentationExpectedPostInsertCaret
            || [_scintilla message:SCI_GETCHARAT
                         wParam:(uptr_t)_pendingSmartIndentationInsertionPosition]
                != _pendingSmartIndentationCloser
            || ![self publishPendingSmartCloser]) {
            [self cancelPendingSmartIndentation];
            return;
        }
        if (_pendingSmartIndentationInsertionPosition < 0) return;
        if (publisher->_revision != expectedCloserRevision
            || _revision != expectedCloserRevision
            || _pendingSmartIndentationOriginalUTF8 == nil
            || _pendingSmartIndentationReplacementUTF8 == nil) {
            [self cancelPendingSmartIndentation];
            return;
        }
        const NSRange range = _pendingSmartIndentationRange;
        NSData *original = _pendingSmartIndentationOriginalUTF8;
        NSData *replacement = _pendingSmartIndentationReplacementUTF8;
        if (range.location > NSUIntegerMax - replacement.length - 1) {
            [self cancelPendingSmartIndentation];
            return;
        }
        const NSUInteger resultingCaret = range.location + replacement.length + 1;
        const NSUInteger replacementComponentCount = replacement.length > 0 ? 2 : 1;
        if (_pendingSmartIndentationSuppressedNativeComponentCount
            > NSUIntegerMax - replacementComponentCount) {
            [self cancelPendingSmartIndentation];
            return;
        }
        _pendingSmartIndentationSuppressedNativeComponentCount += replacementComponentCount;
        _pendingSmartIndentationApplyingReplacement = YES;
        const BOOL replaced = [publisher applyAggregateUserEditInRange:range
                                                        selectionOwner:self
                                                  resultingAnchorUTF8:resultingCaret
                                                   resultingCaretUTF8:resultingCaret
                                               replacementBuilder:^NSData * _Nullable(NSData *deletedUTF8) {
            return [deletedUTF8 isEqualToData:original] ? replacement : nil;
        }];
        _pendingSmartIndentationApplyingReplacement = NO;
        if (!replaced) {
            _pendingSmartIndentationSuppressedNativeComponentCount -= replacementComponentCount;
        }
        if (_pendingSmartIndentationInsertionPosition >= 0) {
            _pendingSmartIndentationCharacterAdded = YES;
            if (_pendingSmartIndentationSuppressedNativeComponentCount == 0) {
                [self finishPendingSmartIndentation];
            }
        }
        return;
    }
    if (_pendingSmartCaretPosition < 0) return;
    const NSInteger caret = [_scintilla message:SCI_GETCURRENTPOS];
    if (notification->characterSource == SC_CHARACTERSOURCE_DIRECT_INPUT
        && notification->ch == _pendingSmartCharacter
        && caret == _pendingSmartInsertionEnd) {
        [_scintilla message:SCI_SETEMPTYSELECTION wParam:(uptr_t)_pendingSmartCaretPosition];
    }
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
}

- (void)handleSmartInsertionCheck:(SCNotification *)notification {
    if (_pendingSmartIndentationInsertionPosition >= 0
        && _pendingSmartIndentationPublisher != nil
        && _pendingSmartIndentationPublisher->_suppressEdit) {
        return;
    }
    const BOOL isSingleClosingDelimiter = notification->text != nullptr
        && notification->length == 1
        && DPIsClosingDelimiter(static_cast<unsigned char>(notification->text[0]));
    if (isSingleClosingDelimiter
        && _pendingSmartIndentationInsertionPosition == notification->position
        && _pendingSmartIndentationCloser == static_cast<unsigned char>(notification->text[0])) {
        return;
    }
    [self cancelPendingSmartIndentation];
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    DPScintillaEditorView *directInputInitiator = _directInputInitiator;
    DPScintillaEditorView *inputOwner = directInputInitiator ?: self;
    const BOOL isSingleCharacter = notification->text != nullptr
        && notification->length == 1;
    const int insertedCharacter = isSingleCharacter
        ? static_cast<unsigned char>(notification->text[0]) : 0;
    const BOOL isEligibleDirectCharacter = inputOwner != nil
        && inputOwner->_smartEditingEnabled
        && inputOwner->_textInputSourceKnown
        && inputOwner->_directInputInsertion
        && inputOwner->_directInputByteLengthKnown
        && inputOwner->_directInputByteLength == 1
        && inputOwner->_directInputSelectionEligible
        && ![[inputOwner->_scintilla content] hasMarkedText]
        && isSingleCharacter;
    const NSInteger documentLength = [_scintilla message:SCI_GETLENGTH];
    if (isEligibleDirectCharacter
        && DPIsSmartClosingCharacter(insertedCharacter)
        && notification->position >= 0
        && notification->position < documentLength
        && [_scintilla message:SCI_GETCHARAT wParam:(uptr_t)notification->position]
            == insertedCharacter) {
        static const char emptyInsertion = '\0';
        [_scintilla message:SCI_CHANGEINSERTION
                     wParam:0
                     lParam:reinterpret_cast<sptr_t>(&emptyInsertion)];
        inputOwner->_pendingSmartCaretPosition = notification->position + 1;
        inputOwner->_pendingSmartInsertionEnd = notification->position;
        inputOwner->_pendingSmartCharacter = insertedCharacter;
        return;
    }
    if (isSingleClosingDelimiter && directInputInitiator != nil
        && directInputInitiator != self) {
        [directInputInitiator cancelPendingSmartIndentation];
        if ([directInputInitiator prepareClosingDelimiterDedent:notification]) return;
    }
    if ([self prepareClosingDelimiterDedent:notification]) return;
    if ((!_smartEditingEnabled && !_plainTextIndentationEnabled) || [[_scintilla content] hasMarkedText]
        || notification->length <= 0 || notification->text == nullptr) return;
    if (notification->length > 2) return;
    const std::string inserted(notification->text, static_cast<size_t>(notification->length));
    const BOOL isNewline = inserted == "\n" || inserted == "\r" || inserted == "\r\n";
    const int opening = inserted.size() == 1 ? static_cast<unsigned char>(inserted[0]) : 0;
    const char *pair = _smartEditingEnabled ? DPSmartPairForOpening(opening) : nullptr;
    BOOL isDirectInput = inputOwner->_textInputSourceKnown
        && inputOwner->_directInputInsertion;
    if (!inputOwner->_textInputSourceKnown
        && inputOwner.window.firstResponder == [inputOwner->_scintilla content]) {
        NSEvent *event = NSApp.currentEvent;
        const NSEventModifierFlags modifiers = event.modifierFlags
            & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);
        NSString *characters = event.characters;
        isDirectInput = event.type == NSEventTypeKeyDown
            && modifiers == 0
            && ((pair != nullptr && [characters isEqualToString:[NSString stringWithFormat:@"%c", opening]])
                || (isNewline && ([characters isEqualToString:@"\r"] || [characters isEqualToString:@"\n"])));
    }
    if (!isDirectInput) return;
    if (!inputOwner->_directInputByteLengthKnown
        || inputOwner->_directInputByteLength != 1
        || !inputOwner->_directInputSelectionEligible) {
        return;
    }
    if (pair != nullptr) {
        [_scintilla message:SCI_CHANGEINSERTION
                     wParam:2
                     lParam:reinterpret_cast<sptr_t>(pair)];
        inputOwner->_pendingSmartCaretPosition = notification->position + 1;
        inputOwner->_pendingSmartInsertionEnd = notification->position + 2;
        inputOwner->_pendingSmartCharacter = opening;
        return;
    }
    if (!isNewline) return;

    const NSInteger position = notification->position;
    const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:(uptr_t)position];
    const NSInteger lineStart = [_scintilla message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    std::string baseIndent;
    for (NSInteger cursor = lineStart; cursor < position; cursor += 1) {
        const int character = static_cast<int>([_scintilla message:SCI_GETCHARAT wParam:(uptr_t)cursor]);
        if (character != ' ' && character != '\t') break;
        if (baseIndent.size() >= static_cast<size_t>(DPSmartIndentScanLimit)) return;
        baseIndent.push_back(static_cast<char>(character));
    }
    if (_plainTextIndentationEnabled) {
        const std::string replacement = inserted + baseIndent;
        [_scintilla message:SCI_CHANGEINSERTION
                     wParam:(uptr_t)replacement.size()
                     lParam:reinterpret_cast<sptr_t>(replacement.c_str())];
        return;
    }
    NSInteger previous = position - 1;
    NSInteger trailingWhitespaceLength = 0;
    while (previous >= lineStart) {
        const int character = static_cast<int>([_scintilla message:SCI_GETCHARAT wParam:(uptr_t)previous]);
        if (character != ' ' && character != '\t') break;
        if (trailingWhitespaceLength >= DPSmartIndentScanLimit) return;
        previous -= 1;
        trailingWhitespaceLength += 1;
    }
    const int previousCharacter = previous >= lineStart
        ? static_cast<int>([_scintilla message:SCI_GETCHARAT wParam:(uptr_t)previous]) : 0;
    const int nextCharacter = static_cast<int>([_scintilla message:SCI_GETCHARAT wParam:(uptr_t)position]);
    const BOOL previousIsOpener = previousCharacter == '{'
        || previousCharacter == '[' || previousCharacter == '(';
    const BOOL previousStartsBlock = previousIsOpener
        || (previousCharacter == ':' && [_lexerName isEqualToString:@"python"]);
    const BOOL beforeCloser = nextCharacter == '}'
        || nextCharacter == ']' || nextCharacter == ')';
    const NSUInteger tabWidth = static_cast<NSUInteger>(MAX(
        1, [_scintilla message:SCI_GETTABWIDTH]
    ));
    const NSUInteger indentWidth = static_cast<NSUInteger>(MAX(1, [_scintilla message:SCI_GETINDENT]));
    const BOOL useTabs = [_scintilla message:SCI_GETUSETABS] != 0;
    std::string innerIndent = baseIndent;
    std::string closerIndent = baseIndent;
    if (indentWidth == tabWidth) {
        const std::string indentUnit = useTabs ? "\t" : std::string(tabWidth, ' ');
        if (previousStartsBlock) innerIndent += indentUnit;
        if (!previousIsOpener && !closerIndent.empty()) {
            if (closerIndent.back() == '\t') closerIndent.pop_back();
            else {
                NSUInteger removed = 0;
                while (!closerIndent.empty() && closerIndent.back() == ' ' && removed < tabWidth) {
                    closerIndent.pop_back(); removed += 1;
                }
            }
        }
    } else {
        const NSUInteger baseColumns = DPIndentationColumns(baseIndent, tabWidth);
        if (previousStartsBlock) innerIndent = DPCanonicalIndentation(baseColumns + indentWidth, tabWidth, useTabs);
        if (!previousIsOpener && !closerIndent.empty()) {
            closerIndent = DPCanonicalIndentation(baseColumns > indentWidth ? baseColumns - indentWidth : 0, tabWidth, useTabs);
        }
    }
    std::string replacement = inserted + innerIndent;
    const NSInteger desiredCaret = position + static_cast<NSInteger>(replacement.size());
    if (beforeCloser) replacement += inserted + closerIndent;
    [_scintilla message:SCI_CHANGEINSERTION
                 wParam:(uptr_t)replacement.size()
                 lParam:reinterpret_cast<sptr_t>(replacement.c_str())];
    if (beforeCloser) {
        _pendingSmartCaretPosition = desiredCaret;
        _pendingSmartInsertionEnd = position + static_cast<NSInteger>(replacement.size());
        _pendingSmartCharacter = static_cast<unsigned char>(inserted.front());
    }
}

- (void)notification:(SCNotification *)notification {
    if (notification->nmhdr.code == SCN_SAVEPOINTREACHED && _publishesDocumentEdits && !_suppressEdit) {
        if (self.onSavePointReached) self.onSavePointReached();
    }
    if (notification->nmhdr.code == SCN_MODIFIED && [_lexerName isEqualToString:@"duckpadlog"]
        && (notification->modificationType & (SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE))) {
        [_scintilla message:SCI_PRIVATELEXERCALL wParam:DPLogInvalidateOperation lParam:MAX(0, notification->position)];
    }
    if (notification->nmhdr.code == SCN_MODIFIED
        && (notification->modificationType & (SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE | SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        // Only the publisher receives text notifications for a shared document.
        // Clear before mutation while indicator ranges still use the old offsets.
        for (DPScintillaEditorView *peer in _searchMarkerPeers) [peer clearDeclarationHover];
    }
    if (_binaryDocument && notification->nmhdr.code == SCN_MODIFIED) {
        if (notification->modificationType & SC_MOD_BEFOREINSERT) {
            const NSUInteger length = [_scintilla message:SCI_GETSELECTIONSERIALIZED];
            _binarySelectionBeforeAppend.resize(length + 1);
            [_scintilla message:SCI_GETSELECTIONSERIALIZED wParam:0
                        lParam:reinterpret_cast<sptr_t>(_binarySelectionBeforeAppend.data())];
            _binaryFirstVisibleLine = [_scintilla message:SCI_GETFIRSTVISIBLELINE];
            _binaryHorizontalScroll = [_scintilla message:SCI_GETXOFFSET];
        }
        if (notification->modificationType & SC_MOD_INSERTTEXT) {
            ++_statusContentGeneration;
            if (!_binarySelectionBeforeAppend.empty()) {
                const NSUInteger length = [_scintilla message:SCI_GETSELECTIONSERIALIZED];
                std::string currentSelection(length + 1, '\0');
                [_scintilla message:SCI_GETSELECTIONSERIALIZED wParam:0
                            lParam:reinterpret_cast<sptr_t>(currentSelection.data())];
                if (currentSelection != _binarySelectionBeforeAppend) {
                    [_scintilla message:SCI_SETSELECTIONSERIALIZED wParam:0
                                lParam:reinterpret_cast<sptr_t>(_binarySelectionBeforeAppend.c_str())];
                }
                if ([_scintilla message:SCI_GETFIRSTVISIBLELINE] != _binaryFirstVisibleLine) {
                    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:_binaryFirstVisibleLine];
                }
                if ([_scintilla message:SCI_GETXOFFSET] != _binaryHorizontalScroll) {
                    [_scintilla message:SCI_SETXOFFSET wParam:_binaryHorizontalScroll];
                }
                _binarySelectionBeforeAppend.clear();
            }
            [self updateLineNumberMargin:[_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
        }
        return;
    }
    if (_binaryDocument && notification->nmhdr.code == SCN_UPDATEUI && self.isInputEnabled) return;
    if (notification->nmhdr.code == SCN_FOCUSIN) {
        [self scheduleWordHighlights:YES];
        [self publishFocus];
        return;
    }
    if (notification->nmhdr.code == SCN_MARGINCLICK && notification->margin == 1) {
        const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:notification->position];
        [self toggleFoldAtLine:(NSUInteger)line];
        return;
    }
    if (notification->nmhdr.code == SCN_CHARADDED) {
        [self handleSmartCharacterAdded:notification];
        return;
    }
    if (notification->nmhdr.code == SCN_PAINTED) {
        if (_observedFollowEnd && [_scintilla message:SCI_GETSELECTIONEMPTY]
            && [_scintilla message:SCI_GETCURRENTPOS] == self.documentByteLength) {
            const sptr_t rows = [_scintilla message:SCI_VISIBLEFROMDOCLINE wParam:[_scintilla message:SCI_GETLINECOUNT]];
            if ([_scintilla message:SCI_GETFIRSTVISIBLELINE] + [_scintilla message:SCI_LINESONSCREEN] < rows)
                [_scintilla message:SCI_SCROLLCARET];
        }
        [self refreshColorPreviews];
        // Idle wrapping can finish after layout/SC_UPDATE_CONTENT. Check the
        // O(1) display count; scrolling alone must not remap every match.
        if ([self overviewMarkerOffsets].count > 0 && !_binaryDocument) {
            const NSInteger displayLines = [_scintilla message:SCI_VISIBLEFROMDOCLINE
                                                       wParam:[_scintilla message:SCI_GETLINECOUNT]];
            if (displayLines != _searchOverviewDisplayLineCount
                || _scintilla.scrollView.documentView.frame.size.height != _searchOverviewDocumentHeight) {
                _searchOverviewNeedsRefresh = YES;
            }
        }
        [self refreshSearchOverview];
    }
    if (notification->nmhdr.code == SCN_UPDATEUI) {
        [_minimap refreshViewport];
        [self scheduleWordHighlights:(notification->updated & SC_UPDATE_SELECTION) != 0];
        if (notification->updated & SC_UPDATE_CONTENT) _searchOverviewNeedsRefresh = YES;
        // Scrolling/wrapping alone cannot change the matching pair. In
        // particular, do not rescan a long line during each redraw phase.
        if (notification->updated & (SC_UPDATE_CONTENT | SC_UPDATE_SELECTION)) {
            [self updateBraceHighlight];
        }
        [self scheduleFoldRecoveryProgress];
        if (self.onStatusChange && (notification->updated & (SC_UPDATE_CONTENT | SC_UPDATE_SELECTION))) {
            self.onStatusChange();
        }
    }
    if (notification->nmhdr.code != SCN_MODIFIED) return;
    const int flags = notification->modificationType;
    if (flags & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
        for (DPScintillaEditorView *peer in _searchMarkerPeers) [peer->_minimap invalidateContent];
        [_wordHighlighter documentChanged];
        [self scheduleWordHighlights:NO];
        if (notification->linesAdded != 0) {
            // The publisher receives text notifications for every shared pane.
            // Update each pane's width while preserving its own visibility/font/zoom.
            for (DPScintillaEditorView *peer in _searchMarkerPeers) {
                [peer updateLineNumberMargin:[peer->_scintilla message:SCI_GETMARGINWIDTHN wParam:0] > 0];
            }
        }
        ++_statusContentGeneration;
        [_colorPreview closeChooser];
        [self clearSearchHighlights];
    }
    if (!_suppressEdit
        && (flags & (SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE)) != 0) {
        if (_publishesDocumentEdits && self.onWillModifyDocument) {
            self.onWillModifyDocument();
        }
        return;
    }
    if (_suppressEdit) {
        const BOOL isSingleInsertedCharacter = (flags & SC_MOD_INSERTTEXT) != 0
            && notification->text != nullptr && notification->length == 1;
        const int insertedCharacter = isSingleInsertedCharacter
            ? static_cast<unsigned char>(notification->text[0]) : 0;
        DPScintillaEditorView *pendingOwner = _directInputInitiator ?: self;
        const BOOL matchesCloser = isSingleInsertedCharacter
            && pendingOwner != nil
            && notification->position == pendingOwner->_pendingSmartIndentationInsertionPosition
            && insertedCharacter == pendingOwner->_pendingSmartIndentationCloser;
        const BOOL matchesIndentationDeletion = pendingOwner != nil
            && (flags & SC_MOD_DELETETEXT) != 0
            && notification->position == (NSInteger)pendingOwner->_pendingSmartIndentationRange.location
            && notification->length
                == (NSInteger)pendingOwner->_pendingSmartIndentationOriginalUTF8.length;
        const BOOL matchesIndentationInsertion = pendingOwner != nil
            && (flags & SC_MOD_INSERTTEXT) != 0
            && pendingOwner->_pendingSmartIndentationReplacementUTF8.length > 0
            && notification->position == (NSInteger)pendingOwner->_pendingSmartIndentationRange.location
            && notification->length
                == (NSInteger)pendingOwner->_pendingSmartIndentationReplacementUTF8.length;
        if ((matchesCloser || matchesIndentationDeletion || matchesIndentationInsertion)
            && pendingOwner->_pendingSmartIndentationSuppressedNativeComponentCount > 0) {
            pendingOwner->_pendingSmartIndentationSuppressedNativeComponentCount -= 1;
            if (pendingOwner->_pendingSmartIndentationCharacterAdded
                && !pendingOwner->_pendingSmartIndentationApplyingReplacement
                && pendingOwner->_pendingSmartIndentationSuppressedNativeComponentCount == 0) {
                [pendingOwner finishPendingSmartIndentation];
            }
        }
        return;
    }
    if ((flags & SC_MOD_INSERTCHECK) != 0) {
        [self handleSmartInsertionCheck:notification];
        return;
    }
    if ((flags & SC_MOD_CONTAINER) != 0 && _revision != UINT64_MAX) {
        [self publishMetadataToken:notification->token
                            origin:(flags & SC_PERFORMED_UNDO) ? DPScintillaEditOriginUndo : DPScintillaEditOriginRedo];
        return;
    }
    const BOOL inserted = (flags & SC_MOD_INSERTTEXT) != 0;
    const BOOL deleted = (flags & SC_MOD_DELETETEXT) != 0;
    if (!inserted && !deleted) return;
    if (_revision == UINT64_MAX) {
        _suppressEdit = YES;
        [_scintilla message:SCI_UNDO];
        _suppressEdit = NO;
        [_scintilla setEditable:NO];
        [self publishMutationError:DPScintillaErrorRevisionOverflow
                       description:@"Revision-exhausted document is read-only"];
        return;
    }
    const NSUInteger byteLength = notification->length < 0 ? 0 : (NSUInteger)notification->length;
    NSData *payload = notification->text != nullptr
        ? [NSData dataWithBytes:notification->text length:byteLength]
        : [NSData data];
    NSData *insertedBytes = inserted ? payload : [NSData data];
    NSData *deletedBytes = deleted ? payload : [NSData data];
    NSRange range = NSMakeRange((NSUInteger)notification->position, deleted ? byteLength : 0);
    const uint64_t base = _revision;
    _revision += 1;
    if (_revision == UINT64_MAX) {
        [_scintilla setEditable:NO];
    }
    _incrementalNotificationCount += 1;
    _incrementalPayloadByteCount += insertedBytes.length + deletedBytes.length;
    DPScintillaEditOrigin origin = DPScintillaEditOriginUser;
    if ((flags & SC_PERFORMED_UNDO) != 0) origin = DPScintillaEditOriginUndo;
    if ((flags & SC_PERFORMED_REDO) != 0) origin = DPScintillaEditOriginRedo;
    DPScintillaEdit *edit = [[DPScintillaEdit alloc] initWithRange:range
                                                      insertedUTF8:insertedBytes
                                                       deletedUTF8:deletedBytes
                                                      baseRevision:base
                                                 resultingRevision:_revision
                                                            origin:origin];
    edit.isIntermediateUndoRedo = origin != DPScintillaEditOriginUser
        && (flags & SC_MULTISTEPUNDOREDO) != 0
        && (flags & SC_LASTSTEPINUNDOREDO) == 0;
    if (self.onEdit) self.onEdit(edit);
}

- (BOOL)isUTF8Boundary:(NSUInteger)position documentLength:(NSUInteger)length {
    if (position == 0 || position == length) return YES;
    const NSInteger before = [_scintilla message:SCI_POSITIONBEFORE
                                          wParam:(uptr_t)position];
    const NSInteger after = [_scintilla message:SCI_POSITIONAFTER
                                         wParam:(uptr_t)before];
    return after == (NSInteger)position;
}

- (BOOL)preflightUserMutation {
    if (_revision != UINT64_MAX && [_scintilla isEditable]) {
        _lastMutationError = nil;
        return YES;
    }
    if (_revision == UINT64_MAX) {
        [self publishMutationError:DPScintillaErrorRevisionOverflow
                       description:@"Revision-exhausted document is read-only"];
    }
    return NO;
}

- (void)publishMutationError:(DPScintillaErrorCode)code description:(NSString *)description {
    _lastMutationError = [NSError errorWithDomain:DPScintillaErrorDomain
                                              code:code
                                          userInfo:@{NSLocalizedDescriptionKey: description}];
    if (self.onError) self.onError(_lastMutationError);
}

- (void)resetInstrumentation {
    _snapshotReadCount = 0;
    _incrementalNotificationCount = 0;
    _incrementalPayloadByteCount = 0;
    _synchronouslyStyledByteCount = 0;
    _commentCommandInspectedByteCount = 0;
}

- (BOOL)fail:(DPScintillaErrorCode)code description:(NSString *)description error:(NSError **)error {
    NSError *failure = [NSError errorWithDomain:DPScintillaErrorDomain
                                            code:code
                                        userInfo:@{NSLocalizedDescriptionKey: description}];
    _lastMutationError = failure;
    if (self.onError) self.onError(failure);
    if (error) *error = failure;
    return NO;
}
@end
