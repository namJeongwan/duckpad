// Duckpad-owned structural D2/Mermaid lexing; rendering performs validation.
#include <algorithm>
#include <cassert>
#include <cctype>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>
#include "ILexer.h"
#include "Scintilla.h"
#include "SciLexer.h"
#include "PropSetSimple.h"
#include "WordList.h"
#include "LexAccessor.h"
#include "LexerBase.h"
#include "DPDiagramLexer.h"

namespace {
constexpr Lexilla::LexicalClass classes[] = {
    {0, "default", "default", "Default"}, {1, "comment", "comment", "Comment"},
    {2, "number", "literal numeric", "Number or color"}, {3, "keyword", "keyword", "Diagram keyword"},
    {4, "string", "literal string", "String or block label"}, {5, "operator", "operator", "Arrow or punctuation"},
    {6, "error", "error", "Error"}, {7, "property", "property", "Diagram property"},
};
constexpr std::string_view mermaidKeywords =
    " graph flowchart sequencediagram participant actor note over of as loop alt else opt par and end critical break rect "
    " autonumber activate deactivate links link click style classdef class subgraph direction lr rl tb bt td "
    " statediagram-v2 statediagram classdiagram erdiagram gantt pie mindmap journey gitgraph timeline quadrantchart "
    " requirementdiagram sankey-beta xychart-beta block-beta architecture-beta packet-beta kanban radar treemap "
    " title section dateformat axisformat todaymarker excludes includes tickinterval accdescr acctitle true false ";
constexpr std::string_view d2Keywords = " true false null near top left right down up bottom center ";
constexpr std::string_view properties =
    " shape style fill stroke stroke-width stroke-dash opacity border-radius font font-size font-color font-family "
    " bold italic underline shadow 3d multiple double-border animated direction width height label icon link tooltip "
    " grid-rows grid-columns grid-gap vertical-gap horizontal-gap classes class vars d2-config layout-engine theme-id "
    " dark-theme-id sketch pad layers scenarios steps sql_table sequence_diagram circle diamond rectangle cloud image ";
bool word(unsigned char c) { return std::isalnum(c) || c == '_' || c >= 128; }
bool member(std::string_view values, const std::string &token) { return values.find(" " + token + " ") != std::string_view::npos; }

class DPDiagramLexer final : public Lexilla::LexerBase {
    const bool mermaid;
public:
    explicit DPDiagramLexer(bool isMermaid) : LexerBase(classes, std::size(classes)), mermaid(isMermaid) {}
    const char *SCI_METHOD GetName() override { return mermaid ? "mermaid" : "d2"; }
    int SCI_METHOD GetIdentifier() override { return SCLEX_CONTAINER; }
    void SCI_METHOD Fold(Sci_PositionU, Sci_Position, int, Scintilla::IDocument *) override {}
    void SCI_METHOD Lex(Sci_PositionU start, Sci_Position length, int, Scintilla::IDocument *doc) override {
        const Sci_Position end = std::min(doc->Length(), static_cast<Sci_Position>(start) + length);
        Sci_Position line = doc->LineFromPosition(start);
        int state = line > 0 ? doc->GetLineState(line - 1) : 0;
        while (doc->LineStart(line) < end) {
            const Sci_Position position = doc->LineStart(line), next = std::min(doc->Length(), doc->LineStart(line + 1));
            if (next <= position) break;
            std::string text(next - position, '\0'); doc->GetCharRange(text.data(), position, text.size());
            std::vector<char> styles(text.size(), 0);
            size_t i = 0;
            if (state == 2) {
                std::fill(styles.begin(), styles.end(), 4);
                const size_t first = text.find_first_not_of(" \t\r\n");
                if (first != std::string::npos && text[first] == '|' && text.find_first_not_of(" \t\r\n", first + 1) == std::string::npos) state = 0;
                i = text.size();
            }
            while (i < text.size()) {
                const size_t first = i;
                char style = 0;
                if (state == 1 || (!mermaid && text.compare(i, 3, "\"\"\"") == 0)) {
                    if (state == 0) i += 3;
                    const size_t close = text.find("\"\"\"", i);
                    style = 1; state = close == std::string::npos ? 1 : 0;
                    i = close == std::string::npos ? text.size() : close + 3;
                } else if (mermaid && text.compare(i, 2, "%%") == 0) {
                    style = 1; i = text.size();
                } else if (!mermaid && text[i] == '#') {
                    style = 1; i = text.size();
                } else if (text[i] == '#') {
                    ++i;
                    while (i < text.size() && std::isxdigit(static_cast<unsigned char>(text[i]))) ++i;
                    const size_t digits = i - first - 1;
                    const bool color = (digits == 3 || digits == 4 || digits == 6 || digits == 8) && (i == text.size() || !word(text[i]));
                    if (color) style = 2;
                    else if (!mermaid) { style = 1; i = text.size(); }
                } else if (text[i] == '"' || text[i] == '\'') {
                    const char quote = text[i++]; style = 4;
                    while (i < text.size() && text[i] != '\r' && text[i] != '\n') {
                        if (text[i] == '\\' && i + 1 < text.size()) { i += 2; continue; }
                        if (text[i++] == quote) break;
                    }
                } else if (!mermaid && text[i] == '|') {
                    style = 4; ++i;
                    const size_t close = text.find('|', i);
                    state = close == std::string::npos ? 2 : 0;
                    i = close == std::string::npos ? text.size() : close + 1;
                } else if (std::isdigit(static_cast<unsigned char>(text[i]))) {
                    style = 2; ++i;
                    while (i < text.size() && (std::isdigit(static_cast<unsigned char>(text[i])) || text[i] == '.')) ++i;
                } else if (word(static_cast<unsigned char>(text[i]))) {
                    ++i;
                    while (i < text.size() && (word(static_cast<unsigned char>(text[i])) || text[i] == '-' && i + 1 < text.size() && word(static_cast<unsigned char>(text[i + 1])))) ++i;
                    std::string token = text.substr(first, i - first);
                    std::transform(token.begin(), token.end(), token.begin(), [](unsigned char c) { return std::tolower(c); });
                    if (member(mermaid ? mermaidKeywords : d2Keywords, token)) style = 3;
                    else if (member(properties, token)) style = 7;
                } else {
                    if (std::string_view("-=<>:{}[](),|+*.;\\").find(text[i]) != std::string_view::npos) style = 5;
                    ++i;
                }
                std::fill(styles.begin() + first, styles.begin() + i, style);
            }
            doc->StartStyling(position); doc->SetStyles(styles.size(), styles.data());
            if (doc->GetLineState(line) != state && next < doc->Length()) doc->ChangeLexerState(next, doc->Length());
            doc->SetLineState(line, state); ++line;
        }
    }
};
}
Scintilla::ILexer5 *DPCreateDiagramLexer(const char *name) {
    if (!std::strcmp(name, "d2")) return new DPDiagramLexer(false);
    if (!std::strcmp(name, "mermaid")) return new DPDiagramLexer(true);
    return nullptr;
}
