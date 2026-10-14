// Duckpad-owned asynchronous styling. Live documents are accessed only on main.
#import <Foundation/Foundation.h>
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

#include "Lexilla.h"
#include "DPAsyncLexer.h"

NSNotificationName const DPAsyncLexerDidStyleNotification = @"DPAsyncLexerDidStyle";

namespace {
using namespace Scintilla;
using namespace Scintilla::Internal;
constexpr Sci_Position threshold = 1024 * 1024;
struct LexerDeleter { void operator()(ILexer5 *lexer) const { if (lexer) lexer->Release(); } };
using LexerPtr = std::unique_ptr<ILexer5, LexerDeleter>;

struct State {
    IDocument *document = nullptr;
    std::string name;
    std::map<std::string, std::string> properties;
    std::map<int, std::string> words;
    uint64_t generation = 0;
    bool running = false;
    bool asynchronous = false;
};
struct Result {
    std::string text;
    std::vector<unsigned char> styles;
    std::vector<int> levels;
    std::vector<int> lineStates;
    uint64_t generation = 0;
    int codePage = 0;
    LineEndType lineEnds = LineEndType::Default;
    int tabWidth = 4;
    bool valid = false;
};

void Schedule(std::shared_ptr<State> state);

void ApplyResult(std::shared_ptr<State> state, std::shared_ptr<Result> result, Sci_Position nextLine = 0) {
    if (!state->document || !state->asynchronous) { state->running = false; return; }
    auto *live = static_cast<Document *>(state->document);
    // Check again between slices: an edit may arrive without another Lex call.
    const bool current = result->generation == state->generation &&
        live->Length() == static_cast<Sci_Position>(result->text.size()) &&
        live->CodePage() == result->codePage && live->GetLineEndTypesActive() == result->lineEnds &&
        live->tabInChars == result->tabWidth &&
        std::memcmp(live->BufferPointer(), result->text.data(), result->text.size()) == 0;
    if (!current || !result->valid) {
        state->running = false;
        if (!current) Schedule(state);
        return;
    }
    if (nextLine == 0) {
        live->StartStyling(0);
        live->SetStyles(result->styles.size(), reinterpret_cast<const char *>(result->styles.data()));
    }
    // A million ordinary lines can produce a million fold notifications. Yield
    // between bounded slices, retaining revision checks and eventual exact folds.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(2);
    const Sci_Position count = static_cast<Sci_Position>(result->levels.size());
    const Sci_Position sliceEnd = std::min(nextLine + 16384, count);
    while (nextLine < sliceEnd) {
        live->SetLevel(nextLine, result->levels[nextLine]);
        live->SetLineState(nextLine, result->lineStates[nextLine]);
        ++nextLine;
        if (nextLine % 256 == 0 && std::chrono::steady_clock::now() >= deadline) break;
    }
    if (nextLine < count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            ApplyResult(state, result, nextLine);
        });
    } else {
        state->running = false;
        [NSNotificationCenter.defaultCenter postNotificationName:DPAsyncLexerDidStyleNotification
            object:[NSValue valueWithPointer:live->AsDocumentEditable()]];
    }
}

void Schedule(std::shared_ptr<State> state) {
    if (state->running || !state->document || !state->asynchronous) return;
    state->running = true;
    // Coalesce a native command's insertion/deletion notifications before copying.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!state->document || !state->asynchronous) { state->running = false; return; }
        auto *document = static_cast<Document *>(state->document);
        const uint64_t generation = state->generation;
        const auto properties = state->properties;
        const auto words = state->words;
        const auto name = state->name;
        const int codePage = document->CodePage();
        const auto lineEnds = document->GetLineEndTypesActive();
        const int tabWidth = document->tabInChars;
        auto result = std::make_shared<Result>();
        result->generation = generation;
        result->codePage = codePage;
        result->lineEnds = lineEnds;
        result->tabWidth = tabWidth;
        try {
            result->text.resize(document->Length());
            document->GetCharRange(result->text.data(), 0, result->text.size());
        } catch (...) { state->running = false; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                try {
                    Document snapshot(DocumentOption::Default);
                    snapshot.SetUndoCollection(false);
                    snapshot.SetDBCSCodePage(codePage);
                    snapshot.tabInChars = tabWidth;
                    snapshot.SetLineEndTypesAllowed(lineEnds);
                    if (snapshot.AddData(result->text.data(), result->text.size()) != 0) throw std::bad_alloc();
                    LexerPtr lexer(CreateLexer(name.c_str()));
                    if (lexer) {
                        for (const auto &[key, value] : properties) lexer->PropertySet(key.c_str(), value.c_str());
                        for (const auto &[index, value] : words) lexer->WordListSet(index, value.c_str());
                        lexer->Lex(0, snapshot.Length(), 0, &snapshot);
                        lexer->Fold(0, snapshot.Length(), 0, &snapshot);
                        result->styles.resize(snapshot.Length());
                        snapshot.GetStyleRange(result->styles.data(), 0, snapshot.Length());
                        const Sci_Position lines = snapshot.LineFromPosition(snapshot.Length()) + 1;
                        for (Sci_Position line = 0; line < lines; ++line) {
                            result->levels.push_back(snapshot.GetLevel(line));
                            result->lineStates.push_back(snapshot.GetLineState(line));
                        }
                        result->valid = true;
                    }
                } catch (...) { /* Keep the last good colours if snapshot allocation fails. */ }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                ApplyResult(state, result);
            });
        });
    });
}

class AsyncLexer final : public ILexer5 {
    LexerPtr lexer;
    std::shared_ptr<State> state = std::make_shared<State>();
    bool supported = true;
    bool needsFullRestyle = false;
    void Invalidate() { ++state->generation; }
    void Disable() { needsFullRestyle |= state->asynchronous; supported = false; state->asynchronous = false; Invalidate(); }
public:
    explicit AsyncLexer(ILexer5 *value) : lexer(value) { state->name = value->GetName(); }
    ~AsyncLexer() { state->document = nullptr; }
    void SCI_METHOD Release() override { delete this; }
    Sci_Position SCI_METHOD PropertySet(const char *key, const char *value) override {
        state->properties[key] = value; Invalidate(); return lexer->PropertySet(key, value);
    }
    Sci_Position SCI_METHOD WordListSet(int index, const char *value) override {
        state->words[index] = value; Invalidate(); return lexer->WordListSet(index, value);
    }
    void SCI_METHOD Lex(Sci_PositionU start, Sci_Position length, int style, IDocument *document) override {
        Invalidate();
        const bool wasAsync = state->asynchronous || needsFullRestyle;
        needsFullRestyle = false;
        state->document = document;
        const Sci_Position line = document->LineFromPosition(start);
        const Sci_Position lastLine = document->LineFromPosition(start + length);
        state->asynchronous = supported && document->Length() >= threshold &&
            static_cast<Document *>(document)->GetLineEndTypesActive() == LineEndType::Default &&
            (wasAsync || length >= threshold ||
                document->LineEnd(line) - document->LineStart(line) >= threshold ||
                document->LineEnd(lastLine) - document->LineStart(lastLine) >= threshold);
        if (state->asynchronous) {
            // Keep shifted existing styles until a revision-consistent result arrives.
            // This advances endStyled without painting the document as plain text.
            document->StartStyling(document->Length());
            Schedule(state);
        } else {
            lexer->Lex(wasAsync ? 0 : start, wasAsync ? document->Length() : length,
                wasAsync ? 0 : style, document);
            if (wasAsync) {
                lexer->Fold(0, document->Length(), 0, document);
                const auto completedState = state;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!completedState->document || completedState->asynchronous) return;
                    auto *live = static_cast<Document *>(completedState->document);
                    // Later synchronous Lex calls also finish before this turn.
                    // Do not discard their completion because the generation advanced.
                    live->EnsureStyledTo(live->Length());
                    if (completedState->asynchronous) return;
                    [NSNotificationCenter.defaultCenter postNotificationName:DPAsyncLexerDidStyleNotification
                        object:[NSValue valueWithPointer:live->AsDocumentEditable()]];
                });
            }
        }
    }
    void SCI_METHOD Fold(Sci_PositionU start, Sci_Position length, int style, IDocument *document) override {
        if (!state->asynchronous) lexer->Fold(start, length, style, document);
    }
    void *SCI_METHOD PrivateCall(int operation, void *pointer) override {
        if (operation == DPAsyncLexerPendingOperation) return state->asynchronous && state->running ? this : nullptr;
        Disable(); return lexer->PrivateCall(operation, pointer);
    }
    int SCI_METHOD AllocateSubStyles(int base, int count) override {
        Disable(); return lexer->AllocateSubStyles(base, count);
    }
    void SCI_METHOD FreeSubStyles() override { Disable(); lexer->FreeSubStyles(); }
    void SCI_METHOD SetIdentifiers(int style, const char *identifiers) override {
        Disable(); lexer->SetIdentifiers(style, identifiers);
    }
    int SCI_METHOD Version() const override { return lexer->Version(); }
    const char * SCI_METHOD PropertyNames() override { return lexer->PropertyNames(); }
    int SCI_METHOD PropertyType(const char *name) override { return lexer->PropertyType(name); }
    const char * SCI_METHOD DescribeProperty(const char *name) override { return lexer->DescribeProperty(name); }
    const char * SCI_METHOD DescribeWordListSets() override { return lexer->DescribeWordListSets(); }
    int SCI_METHOD LineEndTypesSupported() override { return lexer->LineEndTypesSupported(); }
    int SCI_METHOD SubStylesStart(int style) override { return lexer->SubStylesStart(style); }
    int SCI_METHOD SubStylesLength(int style) override { return lexer->SubStylesLength(style); }
    int SCI_METHOD StyleFromSubStyle(int style) override { return lexer->StyleFromSubStyle(style); }
    int SCI_METHOD PrimaryStyleFromStyle(int style) override { return lexer->PrimaryStyleFromStyle(style); }
    int SCI_METHOD DistanceToSecondaryStyles() override { return lexer->DistanceToSecondaryStyles(); }
    const char * SCI_METHOD GetSubStyleBases() override { return lexer->GetSubStyleBases(); }
    int SCI_METHOD NamedStyles() override { return lexer->NamedStyles(); }
    const char * SCI_METHOD NameOfStyle(int style) override { return lexer->NameOfStyle(style); }
    const char * SCI_METHOD TagsOfStyle(int style) override { return lexer->TagsOfStyle(style); }
    const char * SCI_METHOD DescriptionOfStyle(int style) override { return lexer->DescriptionOfStyle(style); }
    const char * SCI_METHOD GetName() override { return lexer->GetName(); }
    int SCI_METHOD GetIdentifier() override { return lexer->GetIdentifier(); }
    const char * SCI_METHOD PropertyGet(const char *key) override { return lexer->PropertyGet(key); }
};
}

ILexer5 *DPWrapAsyncLexer(ILexer5 *lexer) {
    // These lexers only emit styles, line state and folds, all copied above.
    // Other lexer-specific side effects require a separate compatibility audit.
    const std::string name = lexer->GetName();
    return name == "cpp" || name == "css" || name == "xml" ? new AsyncLexer(lexer) : lexer;
}
