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
