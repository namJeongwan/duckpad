#import <Foundation/Foundation.h>
#include <random>
#include <iostream>
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
#include "UniConversion.h"
#include "Geometry.h"
#include "Platform.h"
namespace Scintilla::Internal { class ViewStyle; class Selection; }
#include "PositionCache.h"

using namespace Scintilla;
using namespace Scintilla::Internal;
static size_t checks = 0;
static void check(bool value, const char *message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
static std::string content(Document &doc) {
    std::string text(doc.Length(), '\0'); doc.GetCharRange(text.data(), 0, text.size()); return text;
}
static void wait(ILexer5 *lexer) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (lexer->PrivateCall(DPAsyncLexerPendingOperation, nullptr)) {
        check(std::chrono::steady_clock::now() < deadline, "async styling timed out");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}
static void representations() {
    SpecialRepresentations reps;
    reps.SetDefaultRepresentations(65001);
    check(reps.GetRepresentation("한") == nullptr, "default ordinary Unicode representation");
    check(reps.GetRepresentation("́") == nullptr, "default combining representation");
    check(reps.GetRepresentation("\xe2\x80\xa8") != nullptr, "default line separator representation");
    for (const auto &text : std::vector<std::string>{"한", "́", "̈", "🦆", "\xe2\x80\xa8", "\r\n", std::string("ab\0",3), std::string("\0",1)}) {
        reps.SetRepresentation(text, "custom");
        check(reps.GetRepresentation(text) && reps.GetRepresentation(text)->stringRep == "custom", "custom Unicode representation missing");
        reps.SetRepresentation(text, "changed");
        check(reps.GetRepresentation(text)->stringRep == "changed", "representation replacement");
        reps.ClearRepresentation(text);
        check(reps.GetRepresentation(text) == nullptr, "representation clear");
        reps.SetRepresentation(text, "again");
        check(reps.GetRepresentation(text) != nullptr, "representation reinsert");
    }
    reps.SetRepresentation(std::string("\0ab", 3), "aliased");
    check(reps.GetRepresentation("ab") && reps.GetRepresentation("ab")->stringRep == "aliased", "leading NUL key alias lookup");
    reps.ClearRepresentation("ab");
    check(reps.GetRepresentation(std::string("\0ab", 3)) == nullptr, "leading NUL key alias clear");
    reps.ClearRepresentation("́");
    check(reps.GetRepresentation("̈") != nullptr, "same-lead representation remains");
    reps.Clear(); check(reps.GetRepresentation("한") == nullptr, "clear all representations");
    reps.SetDefaultRepresentations(65001);
    check(reps.GetRepresentation("한") == nullptr && reps.GetRepresentation("\r\n") == nullptr, "reset representations");
    check(reps.GetRepresentation("\xe2\x80\xa8") != nullptr, "reset default multibyte representation");
}
static void decoding() {
    std::mt19937 random(99173);
    for (int i = 0; i < 1000000; ++i) {
        char bytes[4]; for (char &byte : bytes) byte = random();
        const size_t length = 1 + random() % 4;
        const int status = UTF8Classify(bytes, length);
        check(UTF8DrawBytes(bytes, length) == ((status & UTF8MaskInvalid) ? 1 : (status & UTF8MaskWidth)), "UTF8 width classification");
    }
}
static void coordinates() {
    Document doc(DocumentOption::Default); doc.SetDBCSCodePage(65001);
    std::string text;
    for (int i = 0; i < 6500; ++i) text += "a한🦆éz\t ";
    doc.InsertString(0, text);
    std::mt19937 random(83471);
    for (int edit = 0; edit < 500; ++edit) {
        if (edit) {
            const size_t pos = random() % (doc.Length() + 1);
            if (edit % 11 == 0 && doc.CanUndo()) { doc.Undo(); if (edit % 22 == 0) doc.Redo(); }
            else if (edit % 3 == 0 && pos < static_cast<size_t>(doc.Length()))
                doc.DeleteChars(pos, std::min<Sci_Position>(random() % 9 + 1, doc.Length() - pos));
            else {
                const std::string tokens[] = {"a", "한", "🦆", "\x80", "\xf0\x9f", "\r\n", "\xcc\x81", "\t"};
                doc.InsertString(pos, tokens[random() % std::size(tokens)]);
            }
        }
        // Whole-document query builds the index; subsequent edits repair it.
        for (int query = 0; query < 8; ++query) {
            Sci::Position start = query ? random() % (doc.Length() + 1) : 0;
            Sci::Position end = query ? random() % (doc.Length() + 1) : doc.Length();
            if (start > end) std::swap(start, end);
            auto p = doc.MovePositionOutsideChar(start, 1, false);
            const auto finish = doc.MovePositionOutsideChar(end, -1, false);
            Sci::Position utf16 = 0, characters = 0;
            while (p < finish) {
                const auto next = doc.NextPosition(p, 1);
                ++characters; utf16 += next - p == 4 ? 2 : 1; p = next;
            }
            check(doc.CountUTF16(start, end) == utf16, "UTF16 count differs from scalar walk");
            check(doc.CountCharacters(start, end) == characters, "character count differs from scalar walk");
            start = doc.MovePositionOutsideChar(start, 1, false);
            if (start <= finish) {
                check(doc.GetRelativePositionUTF16(start, utf16) == finish, "forward UTF16 position");
                check(doc.GetRelativePositionUTF16(finish, -utf16) == start, "backward UTF16 position");
            }
        }
        // Check tab stop alignment and line-relative columns after arbitrary edits.
        if (edit % 37 == 0) doc.tabInChars = (random() % 16) + 1;
        for (int query = 0; query < 8; ++query) {
            auto end = doc.MovePositionOutsideChar(random() % (doc.Length() + 1), -1, false);
            auto start = doc.LineStart(doc.LineFromPosition(end));
            Sci::Position column = 0;
            for (auto i = start; i < end;) {
                if (doc.CharAt(i) == '\r' || doc.CharAt(i) == '\n') break;
                column = doc.CharAt(i) == '\t' ? (column / doc.tabInChars + 1) * doc.tabInChars : column + 1;
                i = doc.NextPosition(i, 1);
            }
            check(doc.GetColumn(end) == column, "tab column differs from scalar walk");
        }
        // Moving the gap without an edit must not leave dangling segment pointers.
        (void)doc.BufferPointer();
    }
    doc.DeleteChars(0, doc.Length()); doc.InsertString(0, "한🦆");
    check(doc.CountUTF16(0, doc.Length()) == 3, "reload to short UTF8");
    check(doc.GetRelativePositionUTF16(0, 2) == Sci::invalidPosition, "split surrogate");
}
static void compare(Document &doc, ILexer5 *async, const char *name, const char *words = "", bool requestStyling = true) {
    if (requestStyling) { async->Lex(0, doc.Length(), 0, &doc); async->Fold(0, doc.Length(), 0, &doc); }
    wait(async);
    Document fresh(DocumentOption::Default); fresh.SetDBCSCodePage(65001); fresh.SetUndoCollection(false);
    fresh.AddData(content(doc).data(), doc.Length());
    auto *lexer = CreateLexer(name); lexer->PropertySet("fold", "1"); lexer->WordListSet(0, words);
    lexer->Lex(0, fresh.Length(), 0, &fresh); lexer->Fold(0, fresh.Length(), 0, &fresh); lexer->Release();
    std::vector<unsigned char> actual(doc.Length()), expected(doc.Length());
    doc.GetStyleRange(actual.data(), 0, doc.Length()); fresh.GetStyleRange(expected.data(), 0, fresh.Length());
    check(actual == expected, "async styles differ from upstream lexer");
    for (Sci::Position line = 0; line <= doc.LineFromPosition(doc.Length()); ++line) {
        check(doc.GetLevel(line) == fresh.GetLevel(line), "async fold differs from upstream lexer");
        check(doc.GetLineState(line) == fresh.GetLineState(line), "async line state differs from upstream lexer");
    }
}
static void slicedApplication() {
    std::string text;
    for (int i = 0; i < 60000; ++i) text += "function f(){\nreturn 1;\n}\n";
    for (bool close : {false, true}) {
        Document doc(DocumentOption::Default); doc.SetDBCSCodePage(65001); doc.InsertString(0, text);
        auto *lexer = DPWrapAsyncLexer(CreateLexer("cpp")); lexer->PropertySet("fold", "1");
        lexer->Lex(0, doc.Length(), 0, &doc);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
        while (doc.StyleAt(0) == 0 && std::chrono::steady_clock::now() < deadline)
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
        check(doc.StyleAt(0) != 0 && lexer->PrivateCall(DPAsyncLexerPendingOperation, nullptr), "did not observe partial result application");
        if (!close) {
            // No Lex notification: byte checks between slices must restart the job.
            doc.DeleteChars(0, 5); doc.InsertString(0, "/* changed */\n");
            compare(doc, lexer, "cpp", "", false);
        }
        lexer->Release();
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}
static void asynchronous() {
    for (const auto &[name, item] : std::vector<std::pair<const char *, const char *>>{
        {"cpp", "function f(x){return /[a-z]+/.test(x)?`str${x}`:x+1;}/*comment*/"},
        {"css", ".item:hover{color:red;content:\"한🦆\";padding:calc(1px + 2%);}"},
        {"xml", "<item id=\"123\"><name>한🦆</name><!-- hi --><![CDATA[a<b]]></item>"}}) {
        Document doc(DocumentOption::Default); doc.SetDBCSCodePage(65001);
        std::string text; while (text.size() < 1200000) text += item; doc.InsertString(0, text);
        auto *lexer = DPWrapAsyncLexer(CreateLexer(name)); lexer->PropertySet("fold", "1");
        compare(doc, lexer, name);
        for (const std::string token : {"a", "\"", "/*", "\n", "한🦆"}) {
            const auto position = doc.Length() / 2;
            doc.InsertString(position, token); compare(doc, lexer, name);
            doc.Undo(); compare(doc, lexer, name);
            doc.Redo(); compare(doc, lexer, name);
        }
        // Edit while a worker runs, and change configuration before it returns.
        lexer->Lex(0, doc.Length(), 0, &doc);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.015]];
        doc.InsertString(0, "/*"); lexer->WordListSet(0, "function return");
        compare(doc, lexer, name, "function return");
        // A mutation without another Lex call must still reject the stale snapshot.
        lexer->Lex(0, doc.Length(), 0, &doc);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.015]];
        doc.InsertString(0, "x"); compare(doc, lexer, name, "function return", false);
        doc.DeleteChars(0, doc.Length()); doc.InsertString(0, item); compare(doc, lexer, name, "function return");
        // Queue then destroy the live document before the delayed callback runs.
        doc.InsertString(0, text); lexer->Lex(0, doc.Length(), 0, &doc); lexer->Release();
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}
int main() { @autoreleasepool {
    try { representations(); decoding(); coordinates(); asynchronous(); slicedApplication(); std::cout << "PASS native performance correctness checks=" << checks << "\n"; }
    catch (const std::exception &error) { std::cerr << "FAIL " << error.what() << " after " << checks << " checks\n"; return 1; }
}}
