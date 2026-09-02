#import "DuckpadScintillaBridge.h"

#import "ScintillaView.h"

#include <limits>

NSErrorDomain const DPScintillaErrorDomain = @"app.duckpad.scintilla";
static NSURL *DPScintillaResourceDirectory;

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
        _requestedInputEnabled = YES;
        self.accessibilityIdentifier = @"duckpad.editor.scintilla";
    }
    return self;
}

- (void)dealloc {
    _scintilla.delegate = nil;
}

- (uint64_t)revision { return _revision; }
- (NSError *)lastMutationError { return _lastMutationError; }
- (NSUInteger)snapshotReadCount { return _snapshotReadCount; }
- (NSUInteger)incrementalNotificationCount { return _incrementalNotificationCount; }
- (NSUInteger)incrementalPayloadByteCount { return _incrementalPayloadByteCount; }

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

- (BOOL)loadUTF8:(NSData *)content revision:(uint64_t)revision error:(NSError **)error {
    if ([[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding] == nil) {
        return [self fail:DPScintillaErrorInvalidUTF8 description:@"Content is not valid UTF-8" error:error];
    }
    _suppressEdit = YES;
    [_scintilla setEditable:YES];
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
    [_scintilla setEditable:_requestedInputEnabled && revision != UINT64_MAX];
    _lastMutationError = nil;
    return YES;
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
- (NSUInteger)selectionCount { return (NSUInteger)[_scintilla message:SCI_GETSELECTIONS]; }
- (NSUInteger)caretUTF8Position { return (NSUInteger)[_scintilla message:SCI_GETCURRENTPOS]; }
- (NSUInteger)anchorUTF8Position { return (NSUInteger)[_scintilla message:SCI_GETANCHOR]; }
- (NSUInteger)firstVisibleLine { return (NSUInteger)[_scintilla message:SCI_GETFIRSTVISIBLELINE]; }
- (NSUInteger)horizontalScrollOffset { return (NSUInteger)[_scintilla message:SCI_GETXOFFSET]; }
- (BOOL)canUndo { return [_scintilla message:SCI_CANUNDO] != 0; }
- (BOOL)canRedo { return [_scintilla message:SCI_CANREDO] != 0; }
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
    [[_scintilla content] insertText:text];
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    if (![self preflightUserMutation]) return;
    [[_scintilla content] setMarkedText:text selectedRange:selectedRange replacementRange:replacementRange];
}
- (void)unmarkText { [[_scintilla content] unmarkText]; }
- (BOOL)hasMarkedText { return [[_scintilla content] hasMarkedText]; }
- (void)copySelection { [_scintilla message:SCI_COPY]; }
- (void)paste { if ([self preflightUserMutation]) [_scintilla message:SCI_PASTE]; }
- (void)undo { if ([self preflightUserMutation]) [_scintilla message:SCI_UNDO]; }
- (void)redo { if ([self preflightUserMutation]) [_scintilla message:SCI_REDO]; }
- (void)beginGroupedUndo { [_scintilla message:SCI_BEGINUNDOACTION]; }
- (void)endGroupedUndo { [_scintilla message:SCI_ENDUNDOACTION]; }
- (void)focusEditor { [self.window makeFirstResponder:[_scintilla content]]; }

- (void)notification:(SCNotification *)notification {
    if (_suppressEdit || notification->nmhdr.code != SCN_MODIFIED) return;
    const int flags = notification->modificationType;
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
