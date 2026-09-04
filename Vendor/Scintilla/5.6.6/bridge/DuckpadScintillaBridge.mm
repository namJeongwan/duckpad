#import "DuckpadScintillaBridge.h"

#import "ScintillaView.h"

#include <limits>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <utility>
#include <vector>
#include "ILexer.h"
#include "Lexilla.h"

NSErrorDomain const DPScintillaErrorDomain = @"app.duckpad.scintilla";
static NSURL *DPScintillaResourceDirectory;
static constexpr int DPBookmarkMarker = 20;
static constexpr int DPBookmarkMask = 1 << DPBookmarkMarker;
static constexpr NSInteger DPSmartIndentScanLimit = 4096;
static constexpr NSUInteger DPMaximumSynchronousStyleBytes = 262144;
static constexpr NSUInteger DPMaximumFoldRecoveryHeaderCount = 10000;

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

void DPScintillaConfigureResourceDirectory(NSURL *directoryURL) {
    DPScintillaResourceDirectory = [directoryURL copy];
}

NSString *DPScintillaResourcePath(NSString *name) {
    if (DPScintillaResourceDirectory == nil) return nil;
    return [[DPScintillaResourceDirectory URLByAppendingPathComponent:name] path];
}

@interface DPScintillaEdit ()
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
    uint64_t _revision;
    BOOL _suppressEdit;
    BOOL _requestedInputEnabled;
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
    BOOL _smartEditingEnabled;
    BOOL _textInputSourceKnown;
    BOOL _directInputInsertion;
    NSInteger _pendingSmartCaretPosition;
    NSInteger _pendingSmartInsertionEnd;
    int _pendingSmartCharacter;
    BOOL _foldRecoveryProgressPending;
    BOOL _foldRecoveryProgressScheduled;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _scintilla = [[ScintillaView alloc] initWithFrame:self.bounds];
        _scintilla.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scintilla.delegate = self;
        [self addSubview:_scintilla];
        [_scintilla message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_scintilla message:SCI_SETMODEVENTMASK
                     wParam:SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT];
        [_scintilla message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];
        [_scintilla setFontName:@"Menlo" size:13 bold:NO italic:NO];
        _lexerName = @"null";
        _maximumStyleBytes = 16 * 1024 * 1024;
        _foldingEnabled = YES;
        _braceMatchingEnabled = YES;
        _highlightedBraceUTF8Position = -1;
        _matchingBraceUTF8Position = -1;
        _badBraceUTF8Position = -1;
        _publishesDocumentEdits = YES;
        _pendingSmartCaretPosition = -1;
        _pendingSmartInsertionEnd = -1;
        [_scintilla message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:0 lParam:40];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:1 lParam:SC_MASK_FOLDERS];
        [_scintilla message:SCI_SETMARGINSENSITIVEN wParam:1 lParam:1];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:1 lParam:12];
        [_scintilla message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
        [_scintilla message:SCI_SETMARGINMASKN wParam:2 lParam:DPBookmarkMask];
        [_scintilla message:SCI_SETMARGINWIDTHN wParam:2 lParam:12];
        [_scintilla message:SCI_MARKERDEFINE wParam:DPBookmarkMarker lParam:SC_MARK_BOOKMARK];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN lParam:SC_MARK_BOXMINUS];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER lParam:SC_MARK_BOXPLUS];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB lParam:SC_MARK_VLINE];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL lParam:SC_MARK_LCORNER];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND lParam:SC_MARK_BOXPLUSCONNECTED];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_BOXMINUSCONNECTED];
        [_scintilla message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_TCORNER];
        [_scintilla message:SCI_SETINDENTATIONGUIDES wParam:SC_IV_LOOKBOTH];
        [self applyPalette:DPScintillaPaletteLight];
        _requestedInputEnabled = YES;
        self.accessibilityIdentifier = @"duckpad.editor.scintilla";
    }
    return self;
}

- (void)dealloc {
    _scintilla.delegate = nil;
}

- (void)invalidate {
    self.onEdit = nil;
    self.onError = nil;
    self.onFoldStateChange = nil;
    self.onFoldRecoveryProgress = nil;
    _foldRecoveryProgressPending = NO;
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
- (NSUInteger)synchronouslyStyledByteCount { return _synchronouslyStyledByteCount; }
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
    if ([[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding] == nil) {
        return [self fail:DPScintillaErrorInvalidUTF8 description:@"Content is not valid UTF-8" error:error];
    }
    _suppressEdit = YES;
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    [_scintilla setEditable:YES];
    [_scintilla message:SCI_SETEOLMODE wParam:DPEOLModeForUTF8(content)];
    [_scintilla message:SCI_CLEARALL];
    if (content.length > 0) {
        [_scintilla message:SCI_ADDTEXT
                     wParam:(uptr_t)content.length
                     lParam:(sptr_t)content.bytes];
    }
    [_scintilla message:SCI_EMPTYUNDOBUFFER];
    _suppressEdit = NO;
    _revision = revision;
    _lastSearchWasZeroLength = NO;
    _completionItemCount = 0;
    [_scintilla setEditable:_requestedInputEnabled && revision != UINT64_MAX];
    _lastMutationError = nil;
    return YES;
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
    [_scintilla message:SCI_BEGINUNDOACTION];
    for (NSUInteger index = 0; index < ranges.count; index += 1) {
        const NSRange range = ranges[index].rangeValue;
        NSData *replacement = replacements[index];
        if (![self replaceUTF8Range:range
                    withReplacement:replacement
                   expectedRevision:_revision
                  resultingRevision:_revision + 1
                               error:error]) {
            [_scintilla message:SCI_ENDUNDOACTION];
            return NO;
        }
    }
    [_scintilla message:SCI_ENDUNDOACTION];
    return YES;
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
    _requestedInputEnabled = value;
    [_scintilla setEditable:value && _revision != UINT64_MAX];
}
- (BOOL)isWordWrapEnabled { return [_scintilla message:SCI_GETWRAPMODE] != SC_WRAP_NONE; }
- (void)setWordWrapEnabled:(BOOL)value {
    [_scintilla message:SCI_SETWRAPMODE wParam:value ? SC_WRAP_WORD : SC_WRAP_NONE];
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
- (NSInteger)zoomLevel { return [_scintilla message:SCI_GETZOOM]; }
- (void)setZoomLevel:(NSInteger)level {
    [_scintilla message:SCI_SETZOOM wParam:(uptr_t)MAX(-10, MIN(20, level))];
}
- (NSUInteger)lineCount { return (NSUInteger)MAX(1, [_scintilla message:SCI_GETLINECOUNT]); }
- (NSUInteger)caretLine {
    return (NSUInteger)MAX(0, [_scintilla message:SCI_LINEFROMPOSITION wParam:self.caretUTF8Position]);
}
- (NSUInteger)caretColumn {
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
    uptr_t mask = _publishesDocumentEdits
        ? SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT : 0;
    if (_smartEditingEnabled) mask |= SC_MOD_INSERTCHECK;
    [_scintilla message:SCI_SETMODEVENTMASK wParam:mask];
}

- (void)shareDocumentWithView:(DPScintillaEditorView *)source {
    if (source == nil || source == self) return;
    const sptr_t document = [source->_scintilla message:SCI_GETDOCPOINTER];
    [_scintilla message:SCI_SETDOCPOINTER wParam:0 lParam:document];
    // The primary view remains the sole document-modification observer. A
    // shared document notifies every attached Scintilla view, so enabling this
    // mask here would publish each edit twice to Application.
    _publishesDocumentEdits = NO;
    [self updateModificationEventMask];
    [self synchronizeRevision:source.revision];
}

- (void)synchronizeRevision:(uint64_t)revision {
    _revision = revision;
    [_scintilla setEditable:_requestedInputEnabled && revision != UINT64_MAX];
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

- (void)setPrimarySelectionUTF8Range:(NSRange)range {
    [_scintilla message:SCI_SETSEL wParam:(uptr_t)range.location lParam:(sptr_t)NSMaxRange(range)];
    [_scintilla message:SCI_SCROLLCARET];
}

- (void)restoreCaretUTF8Position:(NSUInteger)caret
                  anchorPosition:(NSUInteger)anchor
                firstVisibleLine:(NSUInteger)firstVisibleLine
          horizontalScrollOffset:(NSUInteger)horizontalScrollOffset
                 wordWrapEnabled:(BOOL)wordWrapEnabled {
    const NSUInteger length = (NSUInteger)[_scintilla message:SCI_GETLENGTH];
    const NSUInteger safeCaret = MIN(caret, length);
    const NSUInteger safeAnchor = MIN(anchor, length);
    [_scintilla message:SCI_SETSEL wParam:(uptr_t)safeAnchor lParam:(sptr_t)safeCaret];
    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)firstVisibleLine];
    [_scintilla message:SCI_SETXOFFSET wParam:(uptr_t)horizontalScrollOffset];
    [_scintilla message:SCI_SETWRAPMODE wParam:wordWrapEnabled ? SC_WRAP_WORD : SC_WRAP_NONE];
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
    _textInputSourceKnown = YES;
    _directInputInsertion = YES;
    [[_scintilla content] insertText:text];
    _directInputInsertion = NO;
    _textInputSourceKnown = NO;
}

- (void)scintillaWillInsertTextFromSource:(SCITextInputSource)source {
    _textInputSourceKnown = YES;
    _directInputInsertion = source == SCITextInputSourceDirect;
}

- (void)scintillaDidInsertText {
    _directInputInsertion = NO;
    _textInputSourceKnown = NO;
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    if (![self preflightUserMutation]) return;
    [[_scintilla content] setMarkedText:text selectedRange:selectedRange replacementRange:replacementRange];
}
- (void)unmarkText { [[_scintilla content] unmarkText]; }
- (BOOL)hasMarkedText { return [[_scintilla content] hasMarkedText]; }
- (void)copySelection { [[_scintilla content] copy:nil]; }
- (void)cutSelection { if ([self preflightUserMutation]) [[_scintilla content] cut:nil]; }
- (void)paste { if ([self preflightUserMutation]) [[_scintilla content] paste:nil]; }
- (void)deleteSelectionOrNextCharacter { if ([self preflightUserMutation]) [_scintilla message:SCI_CLEAR]; }
- (void)selectAll { [[_scintilla content] selectAll:nil]; }
- (void)undo { if ([self preflightUserMutation]) [[_scintilla content] undo:nil]; }
- (void)redo { if ([self preflightUserMutation]) [[_scintilla content] redo:nil]; }
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
- (void)focusEditor { [self.window makeFirstResponder:[_scintilla content]]; }

+ (BOOL)supportsLexerNamed:(NSString *)lexerName {
    if (lexerName.length == 0) return NO;
    Scintilla::ILexer5 *lexer = CreateLexer(lexerName.UTF8String);
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
    const BOOL overBudget = self.documentByteLength > maximumStyleBytes;
    const BOOL nextBraceMatchingEnabled = braceMatching && !overBudget;
    NSString *effectiveName = overBudget ? @"null" : lexerName;
    Scintilla::ILexer5 *lexer = CreateLexer(effectiveName.UTF8String);
    if (lexer == nullptr) return NO;
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    _braceMatchingEnabled = nextBraceMatchingEnabled;
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
        if (semantic.find("comment") != std::string::npos) role = 1;
        else if (semantic.find("number") != std::string::npos) role = 2;
        else if (semantic.find("keyword") != std::string::npos || semantic.find("word") != std::string::npos) role = 3;
        else if (semantic.find("string") != std::string::npos || semantic.find("character") != std::string::npos) role = 4;
        else if (semantic.find("operator") != std::string::npos || semantic.find("brace") != std::string::npos) role = 5;
        else if (semantic.find("error") != std::string::npos || semantic.find("bad") != std::string::npos) role = 6;
        _semanticStyleRoles.emplace_back(style, role);
    }
    [_scintilla message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(lexer)];
    _lexerName = [effectiveName copy];
    _languageStylingFallback = overBudget && ![lexerName isEqualToString:@"null"];
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
        [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_EXPAND];
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

- (void)applyPalette:(DPScintillaPalette)palette {
    _palette = palette;
    const BOOL dark = palette == DPScintillaPaletteDark || palette == DPScintillaPaletteHighContrastDark;
    const BOOL highContrast = palette == DPScintillaPaletteHighContrastLight || palette == DPScintillaPaletteHighContrastDark;
    const int foreground = dark ? 0xE8E8E8 : 0x202020;
    const int background = dark ? 0x1E1E1E : 0xFFFFFF;
    const int gutterBackground = dark ? 0x262626 : 0xF6F6F6;
    const int gutterForeground = dark ? 0x8A8A8A : 0x747474;
    const int caretLineBackground = dark ? 0x292929 : 0xF8F8F8;
    const int comment = dark ? 0x7FD47F : 0x397A32;
    const int number = dark ? 0xD7A0F8 : 0x7C2F8E;
    const int keyword = dark ? 0xFFB36B : 0xA23B00;
    const int stringColour = dark ? 0x7DD6E8 : 0x176A7A;
    const int operatorColour = dark ? 0xA9C7FF : 0x204F9B;
    const int errorColour = dark ? 0x8080FF : 0x2020D0;
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:foreground];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:background];
    [_scintilla message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:reinterpret_cast<sptr_t>("Menlo")];
    [_scintilla message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:13];
    [_scintilla message:SCI_STYLECLEARALL];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:gutterForeground];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:gutterBackground];
    [_scintilla message:SCI_STYLESETFONT wParam:STYLE_LINENUMBER lParam:reinterpret_cast<sptr_t>("SF Mono")];
    [_scintilla message:SCI_STYLESETSIZE wParam:STYLE_LINENUMBER lParam:11];
    [_scintilla message:SCI_SETMARGINBACKN wParam:0 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINBACKN wParam:2 lParam:gutterBackground];
    [_scintilla message:SCI_SETFOLDMARGINCOLOUR wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:gutterBackground];
    [_scintilla message:SCI_SETMARGINLEFT wParam:0 lParam:8];
    [_scintilla message:SCI_SETMARGINRIGHT wParam:0 lParam:8];
    [_scintilla message:SCI_SETEXTRAASCENT wParam:2 lParam:0];
    [_scintilla message:SCI_SETEXTRADESCENT wParam:2 lParam:0];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_BRACELIGHT lParam:dark ? 0x80FFFF : 0x7A3D00];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_BRACELIGHT lParam:dark ? 0x503000 : 0xB8F1FF];
    [_scintilla message:SCI_STYLESETBOLD wParam:STYLE_BRACELIGHT lParam:1];
    [_scintilla message:SCI_STYLESETFORE wParam:STYLE_BRACEBAD lParam:dark ? 0xA0A0FF : 0x0000CC];
    [_scintilla message:SCI_STYLESETBACK wParam:STYLE_BRACEBAD lParam:dark ? 0x302060 : 0xD8D8FF];
    [_scintilla message:SCI_STYLESETBOLD wParam:STYLE_BRACEBAD lParam:1];
    for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; marker += 1) {
        [_scintilla message:SCI_MARKERSETFORE wParam:marker lParam:dark ? 0xE8E8E8 : 0x303030];
        [_scintilla message:SCI_MARKERSETBACK wParam:marker lParam:dark ? 0x505050 : 0xD8D8D8];
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
            default: break;
        }
        [_scintilla message:SCI_STYLESETFORE wParam:style lParam:colour];
        [_scintilla message:SCI_STYLESETBOLD wParam:style lParam:highContrast && role == 3];
    }
    [_scintilla message:SCI_SETCARETFORE wParam:highContrast ? (dark ? 0xFFFFFF : 0x000000) : foreground];
    [_scintilla message:SCI_SETCARETLINEVISIBLE wParam:1 lParam:0];
    [_scintilla message:SCI_SETCARETLINEBACK wParam:0 lParam:caretLineBackground];
    [_scintilla message:SCI_SETCARETLINEBACKALPHA wParam:highContrast ? 42 : 24 lParam:0];
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
    return [_scintilla message:SCI_GETSTYLEAT wParam:position];
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
    return _foldingEnabled && [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:0] >= 0;
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
    const BOOL wasExpanded = [_scintilla message:SCI_GETFOLDEXPANDED wParam:(uptr_t)header] != 0;
    if (wasExpanded == expanded) return NO;
    [_scintilla message:SCI_FOLDLINE
                 wParam:(uptr_t)header
                 lParam:expanded ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT];
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

- (BOOL)collapseAllFolds {
    if (!_foldingEnabled) return NO;
    NSArray<NSNumber *> *before = [self contractedFoldHeaderLinesWithMaximumCount:NSUIntegerMax];
    [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_CONTRACT_EVERY_LEVEL];
    NSArray<NSNumber *> *after = [self contractedFoldHeaderLinesWithMaximumCount:NSUIntegerMax];
    if ([before isEqualToArray:after]) return NO;
    if (self.onFoldStateChange) self.onFoldStateChange();
    return YES;
}

- (BOOL)expandAllFolds {
    if (!self.hasContractedFolds) return NO;
    [_scintilla message:SCI_FOLDALL wParam:SC_FOLDACTION_EXPAND];
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
        if (lineEnd > endStyled) {
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

- (void)handleSmartCharacterAdded:(SCNotification *)notification {
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
    _pendingSmartCaretPosition = -1;
    _pendingSmartInsertionEnd = -1;
    _pendingSmartCharacter = 0;
    if (!_smartEditingEnabled || [[_scintilla content] hasMarkedText]
        || notification->length <= 0 || notification->text == nullptr) return;
    if (notification->length > 2) return;
    const std::string inserted(notification->text, static_cast<size_t>(notification->length));
    const BOOL isNewline = inserted == "\n" || inserted == "\r" || inserted == "\r\n";
    const int opening = inserted.size() == 1 ? static_cast<unsigned char>(inserted[0]) : 0;
    const char *pair = nullptr;
    switch (opening) {
    case '{': pair = "{}"; break;
    case '[': pair = "[]"; break;
    case '(': pair = "()"; break;
    default: break;
    }
    BOOL isDirectInput = _textInputSourceKnown && _directInputInsertion;
    if (!_textInputSourceKnown && self.window.firstResponder == [_scintilla content]) {
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
    if (pair != nullptr) {
        [_scintilla message:SCI_CHANGEINSERTION
                     wParam:2
                     lParam:reinterpret_cast<sptr_t>(pair)];
        _pendingSmartCaretPosition = notification->position + 1;
        _pendingSmartInsertionEnd = notification->position + 2;
        _pendingSmartCharacter = opening;
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
    const BOOL useTabs = [_scintilla message:SCI_GETUSETABS] != 0;
    const std::string indentUnit = useTabs ? "\t" : std::string(tabWidth, ' ');
    std::string innerIndent = baseIndent;
    if (previousStartsBlock) innerIndent += indentUnit;
    std::string closerIndent = baseIndent;
    if (!previousIsOpener && !closerIndent.empty()) {
        if (closerIndent.back() == '\t') {
            closerIndent.pop_back();
        } else {
            NSUInteger removed = 0;
            while (!closerIndent.empty() && closerIndent.back() == ' ' && removed < tabWidth) {
                closerIndent.pop_back();
                removed += 1;
            }
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
    if (notification->nmhdr.code == SCN_MARGINCLICK && notification->margin == 1) {
        const NSInteger line = [_scintilla message:SCI_LINEFROMPOSITION wParam:notification->position];
        [self toggleFoldAtLine:(NSUInteger)line];
        return;
    }
    if (notification->nmhdr.code == SCN_CHARADDED) {
        [self handleSmartCharacterAdded:notification];
        return;
    }
    if (notification->nmhdr.code == SCN_UPDATEUI) {
        [self updateBraceHighlight];
        [self scheduleFoldRecoveryProgress];
    }
    if (_suppressEdit || notification->nmhdr.code != SCN_MODIFIED) return;
    const int flags = notification->modificationType;
    if ((flags & SC_MOD_INSERTCHECK) != 0) {
        [self handleSmartInsertionCheck:notification];
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
