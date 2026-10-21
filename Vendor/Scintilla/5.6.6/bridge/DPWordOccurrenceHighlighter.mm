#import "DPWordOccurrenceHighlighter.h"
#import "ScintillaView.h"
#include <algorithm>
#include <cstring>
#include <string>

static constexpr NSUInteger DPWordHighlightEnabled = 1 << 0;
static constexpr NSUInteger DPCaretWordHighlightEnabled = 1 << 1;
static constexpr int DPWordIndicator = 10;
static constexpr sptr_t DPWordScanBudget = 64 * 1024;
static constexpr NSUInteger DPWordMatchLimit = 100000;

@implementation DPWordOccurrenceHighlighter {
    NSMapTable<ScintillaView *, NSNumber *> *_views;
    __weak ScintillaView *_active;
    BOOL _scheduled;
    NSUInteger _inspectedByteCount;
    NSMapTable<ScintillaView *, void (^)(void)> *_callbacks;
    NSMutableIndexSet *_matchOffsets;
    NSIndexSet *_publishedOffsets;
    NSData *_pattern;
    BOOL _wholeWord;
    NSUInteger _generation;
    sptr_t _scanPosition;
}

- (instancetype)init {
    if ((self = [super init])) {
        _views = [NSMapTable weakToStrongObjectsMapTable];
        _callbacks = [NSMapTable weakToStrongObjectsMapTable];
        _matchOffsets = [NSMutableIndexSet indexSet];
        _publishedOffsets = [NSIndexSet indexSet];
    }
    return self;
}

+ (void)applyAppearanceToView:(ScintillaView *)view dark:(BOOL)dark highContrast:(BOOL)highContrast {
    [view message:SCI_INDICSETSTYLE wParam:DPWordIndicator lParam:INDIC_ROUNDBOX];
    [view message:SCI_INDICSETFORE wParam:DPWordIndicator lParam:dark ? 0xD8AD79 : 0xA56F35];
    [view message:SCI_INDICSETALPHA wParam:DPWordIndicator lParam:highContrast ? 95 : 45];
    [view message:SCI_INDICSETOUTLINEALPHA wParam:DPWordIndicator lParam:highContrast ? 220 : 110];
    [view message:SCI_INDICSETUNDER wParam:DPWordIndicator lParam:1];
}

+ (BOOL)isHighlightedInView:(ScintillaView *)view atPosition:(NSUInteger)position {
    return position < (NSUInteger)[view message:SCI_GETLENGTH]
        && [view message:SCI_INDICATORVALUEAT wParam:DPWordIndicator lParam:position] != 0;
}

- (NSUInteger)inspectedByteCount { return _inspectedByteCount; }
- (NSIndexSet *)matchOffsets { return _publishedOffsets; }
- (NSUInteger)matchedByteLength { return _pattern.length; }

- (void)addView:(ScintillaView *)view onChange:(void (^)(void))onChange {
    [_callbacks setObject:[onChange copy] forKey:view];
}

- (void)publish {
    for (void (^callback)(void) in _callbacks.objectEnumerator) callback();
}

- (void)scheduleForView:(ScintillaView *)view enabled:(BOOL)enabled caretWordEnabled:(BOOL)caretWordEnabled selectionChanged:(BOOL)selectionChanged {
    const NSUInteger options = (enabled ? DPWordHighlightEnabled : 0)
        | (caretWordEnabled ? DPCaretWordHighlightEnabled : 0);
    [_views setObject:@(options) forKey:view];
    if (!_active || (selectionChanged && (view.window.firstResponder == view.content
        || !_active.window || !_active.window.isVisible))) _active = view;
    if (_scheduled) return;
    _scheduled = YES;
    __weak DPWordOccurrenceHighlighter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        DPWordOccurrenceHighlighter *owner = weakSelf;
        if (!owner) return;
        owner->_scheduled = NO;
        [owner refresh];
    });
}

- (void)clear {
    ScintillaView *view = _active ?: _views.keyEnumerator.nextObject;
    if (!view) return;
    const sptr_t previous = [view message:SCI_GETINDICATORCURRENT];
    [view message:SCI_SETINDICATORCURRENT wParam:DPWordIndicator];
    [view message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[view message:SCI_GETLENGTH]];
    [view message:SCI_SETINDICATORCURRENT wParam:previous];
}

- (void)removeView:(ScintillaView *)view {
    if (!view) return;
    [_callbacks removeObjectForKey:view];
    if (_active == view) { [self documentChanged]; _active = nil; }
    [_views removeObjectForKey:view];
}

- (void)documentChanged {
    ++_generation;
    _inspectedByteCount = 0;
    _pattern = nil;
    [self clear];
    [_matchOffsets removeAllIndexes];
    _publishedOffsets = [NSIndexSet indexSet];
    [self publish];
}

// Inspect at most 512 Unicode scalars around the caret. Native word-start/end
// scans are unbounded on a single enormous token, so never use them here.
- (NSData *)wordInView:(ScintillaView *)view {
    const sptr_t caret = [view message:SCI_GETCURRENTPOS];
    const sptr_t anchor = [view message:SCI_GETANCHOR];
    const sptr_t length = [view message:SCI_GETLENGTH];
    if (std::abs(caret - anchor) > 256 || [view message:SCI_SELECTIONISRECTANGLE]) return nil;
    if (caret != anchor) {
        // Explicit selections are literal substrings, including partial words.
        std::string selected(std::abs(caret - anchor) + 1, '\0');
        Sci_TextRangeFull range{{std::min(caret, anchor), std::max(caret, anchor)}, selected.data()};
        [view message:SCI_GETTEXTRANGEFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&range)];
        NSString *text = [[NSString alloc] initWithBytes:selected.data() length:selected.size() - 1 encoding:NSUTF8StringEncoding];
        if (!text || [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound
            || [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0
            || memchr(selected.data(), 0, selected.size() - 1)) return nil;
        return [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!([[_views objectForKey:view] unsignedIntegerValue] & DPCaretWordHighlightEnabled)) return nil;
    sptr_t lower = caret, upper = caret;
    for (NSUInteger index = 0; index < 256; index++) {
        if (lower > 0) lower = [view message:SCI_POSITIONBEFORE wParam:lower];
        if (upper < length) upper = [view message:SCI_POSITIONAFTER wParam:upper];
        if (lower == 0 && upper == length) break;
    }
    if (upper <= lower || upper - lower > 2048) return nil;
    std::string bytes(upper - lower + 1, '\0');
    Sci_TextRangeFull range{{lower, upper}, bytes.data()};
    [view message:SCI_GETTEXTRANGEFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&range)];
    NSString *text = [[NSString alloc] initWithBytes:bytes.data() length:upper - lower encoding:NSUTF8StringEncoding];
    NSString *prefix = [[NSString alloc] initWithBytes:bytes.data() length:caret - lower encoding:NSUTF8StringEncoding];
    if (!text || !prefix) return nil;
    static NSCharacterSet *nonWord;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *word = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
        [word formUnionWithCharacterSet:NSCharacterSet.nonBaseCharacterSet];
        [word addCharactersInString:@"_"];
        nonWord = word.invertedSet;
    });
    NSRange before = [text rangeOfCharacterFromSet:nonWord options:NSBackwardsSearch range:NSMakeRange(0, prefix.length)];
    NSRange after = [text rangeOfCharacterFromSet:nonWord options:0 range:NSMakeRange(prefix.length, text.length - prefix.length)];
    const NSUInteger wordStart = before.location == NSNotFound ? 0 : NSMaxRange(before);
    const NSUInteger wordEnd = after.location == NSNotFound ? text.length : after.location;
    if (wordEnd <= wordStart || (wordStart == 0 && lower != 0) || (wordEnd == text.length && upper != length)) return nil;
    NSData *word = [[text substringWithRange:NSMakeRange(wordStart, wordEnd - wordStart)] dataUsingEncoding:NSUTF8StringEncoding];
    if (word.length > 256) return nil;
    return word;
}

- (void)refresh {
    ScintillaView *view = _active;
    NSData *word = view && ([[_views objectForKey:view] unsignedIntegerValue] & DPWordHighlightEnabled) && ![view.content hasMarkedText]
        ? [self wordInView:view] : nil;
    const BOOL wholeWord = [view message:SCI_GETCURRENTPOS] == [view message:SCI_GETANCHOR];
    if ((!_pattern && !word) || ([_pattern isEqualToData:word] && _wholeWord == wholeWord)) return;
    [self documentChanged];
    _inspectedByteCount = 0;
    if (!word.length) return;
    _pattern = word;
    _wholeWord = wholeWord;
    _scanPosition = 0;
    [self scanNextChunk:_generation];
}

// Yield between bounded native searches instead of copying/scanning a complete
// document on each drag event. Edits and a different query cancel stale chunks.
- (void)scanNextChunk:(NSUInteger)generation {
    ScintillaView *view = _active;
    if (generation != _generation || !view || !_pattern.length) return;
    const sptr_t length = [view message:SCI_GETLENGTH];
    const sptr_t chunkEnd = std::min(length, _scanPosition + DPWordScanBudget);
    const sptr_t searchEnd = std::min(length, chunkEnd + (sptr_t)_pattern.length - 1);
    _inspectedByteCount = MAX(_inspectedByteCount, (NSUInteger)(searchEnd - _scanPosition));
    std::string needle(static_cast<const char *>(_pattern.bytes), _pattern.length);
    Sci_TextToFindFull find{{_scanPosition, searchEnd}, needle.c_str(), {0, 0}};
    const sptr_t previous = [view message:SCI_GETINDICATORCURRENT];
    const sptr_t previousValue = [view message:SCI_GETINDICATORVALUE];
    [view message:SCI_SETINDICATORCURRENT wParam:DPWordIndicator];
    [view message:SCI_SETINDICATORVALUE wParam:1];
    NSUInteger sliceMatches = 0;
    while (_scanPosition < chunkEnd && sliceMatches < 512 && _matchOffsets.count < DPWordMatchLimit) {
        if ([view message:SCI_FINDTEXTFULL wParam:SCFIND_MATCHCASE | (_wholeWord ? SCFIND_WHOLEWORD : 0)
            lParam:reinterpret_cast<sptr_t>(&find)] < 0 || find.chrgText.cpMin >= chunkEnd) {
            _scanPosition = chunkEnd;
            break;
        }
        [view message:SCI_INDICATORFILLRANGE wParam:find.chrgText.cpMin lParam:find.chrgText.cpMax - find.chrgText.cpMin];
        [_matchOffsets addIndex:find.chrgText.cpMin];
        ++sliceMatches;
        _scanPosition = find.chrgText.cpMax;
        find.chrg.cpMin = _scanPosition;
    }
    [view message:SCI_SETINDICATORCURRENT wParam:previous];
    [view message:SCI_SETINDICATORVALUE wParam:previousValue];
    const BOOL finished = _scanPosition >= length || _matchOffsets.count >= DPWordMatchLimit;
    if (finished) {
        // Paint may request offsets between chunks: expose only a completed snapshot.
        _publishedOffsets = [_matchOffsets copy];
        [self publish];
    }
    if (!finished) {
        __weak DPWordOccurrenceHighlighter *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf scanNextChunk:generation];
        });
    }
}
@end
