#import "DPScintillaBinaryDocument.h"
#import "ScintillaView.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <forward_list>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include "ScintillaTypes.h"
#include "ILoader.h"
#include "ILexer.h"
#include "Debugging.h"
#include "CharacterType.h"
#include "CharacterCategoryMap.h"
#include "Position.h"
#include "SplitVector.h"
#include "Partitioning.h"
#include "RunStyles.h"
#include "CellBuffer.h"
#include "PerLine.h"
#include "CharClassify.h"
#include "Decoration.h"
#include "CaseFolder.h"
#include "Document.h"

@implementation DPScintillaBinaryDocument {
    Scintilla::Internal::Document *_document;
    NSData *_sourceData;
}

- (instancetype)initWithDocument:(Scintilla::Internal::Document *)document sourceData:(NSData *)data {
    self = [super init];
    if (self) {
        _document = document;
        _byteLength = static_cast<NSUInteger>(document->Length());
        _totalByteLength = data.length;
        _sourceData = _byteLength < _totalByteLength ? data : nil;
    }
    return self;
}

+ (void)prepareData:(NSData *)data
  completionHandler:(void (^)(DPScintillaBinaryDocument *, NSError *))completionHandler {
    [self prepareData:data initialByteCount:data.length completionHandler:completionHandler];
}

+ (void)beginData:(NSData *)data
 completionHandler:(void (^)(DPScintillaBinaryDocument *, NSError *))completionHandler {
    [self prepareData:data initialByteCount:64 * 1024 completionHandler:completionHandler];
}

+ (void)prepareData:(NSData *)data initialByteCount:(NSUInteger)initialByteCount
  completionHandler:(void (^)(DPScintillaBinaryDocument *, NSError *))completionHandler {
    // NSData's immutable copy retains mapped storage; mutable callers get a snapshot.
    NSData *bytes = [data copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Scintilla::Internal::Document *prepared = nullptr;
            NSError *error = nil;
            try {
                if (bytes.length > static_cast<NSUInteger>(PTRDIFF_MAX)) {
                    throw std::length_error("Binary document exceeds native position range");
                }
                // Equivalent to SCI_CREATELOADER, without constructing or accessing a view.
                auto document = std::make_unique<Scintilla::Internal::Document>(
                    Scintilla::DocumentOption::StylesNone | Scintilla::DocumentOption::TextLarge);
                document->SetUndoCollection(false);
                document->SetDBCSCodePage(0);
                document->Allocate(static_cast<Sci::Position>(bytes.length));
                const NSUInteger initialLength = MIN(initialByteCount, bytes.length);
                const int status = document->AddData(static_cast<const char *>(bytes.bytes),
                    static_cast<Sci_Position>(initialLength));
                if (status != static_cast<int>(Scintilla::Status::Ok)
                    || document->Length() != static_cast<Sci::Position>(initialLength)) {
                    throw std::runtime_error("Binary document loading failed");
                }
                document->SetReadOnly(true);
                document->AddRef();
                prepared = document.release();
            } catch (...) {
                error = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadUnknownError userInfo:nil];
            }
            // After this hand-off, all document refcount changes happen on the main thread.
            dispatch_async(dispatch_get_main_queue(), ^{
                DPScintillaBinaryDocument *result = prepared == nullptr ? nil
                    : [[self alloc] initWithDocument:prepared sourceData:bytes];
                completionHandler(result, error);
            });
        }
    });
}

- (BOOL)isAttachedToScintillaView:(ScintillaView *)view {
    return [view message:SCI_GETDOCPOINTER]
        == reinterpret_cast<sptr_t>(_document->ConvertToDocument());
}

- (BOOL)appendMaximumBytes:(NSUInteger)maximumBytes error:(NSError **)error {
    NSAssert([NSThread isMainThread], @"Binary document appends must run on the main thread");
    if (_byteLength == _totalByteLength) return YES;
    if (_sourceData == nil) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSUserCancelledError userInfo:nil];
        return NO;
    }
    const NSUInteger count = MIN(maximumBytes, _totalByteLength - _byteLength);
    int status = static_cast<int>(Scintilla::Status::Failure);
    @try {
        _document->SetReadOnly(false);
        status = _document->AddData(static_cast<const char *>(_sourceData.bytes) + _byteLength,
            static_cast<Sci_Position>(count));
    } @finally {
        _document->SetReadOnly(true);
    }
    const NSUInteger expectedLength = _byteLength + count;
    _byteLength = static_cast<NSUInteger>(_document->Length());
    if (status != static_cast<int>(Scintilla::Status::Ok) || _byteLength != expectedLength) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSFileReadUnknownError userInfo:nil];
        return NO;
    }
    if (_byteLength == _totalByteLength) _sourceData = nil;
    return _byteLength == _totalByteLength;
}

- (void)cancelLoading {
    NSAssert([NSThread isMainThread], @"Binary document cancellation must run on the main thread");
    _sourceData = nil;
}

- (void)attachToScintillaView:(ScintillaView *)view {
    NSAssert([NSThread isMainThread], @"Scintilla documents must attach on the main thread");
    [view message:SCI_SETDOCPOINTER wParam:0
           lParam:reinterpret_cast<sptr_t>(_document->ConvertToDocument())];
}

- (void)dealloc {
    auto *document = _document;
    if ([NSThread isMainThread]) {
        document->Release();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ document->Release(); });
    }
}
@end
