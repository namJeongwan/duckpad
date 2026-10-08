// Duckpad-owned lexer. Upstream Lexilla sources remain unchanged.
#include <algorithm>
#include <cassert>
#include <cctype>
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
#include "DPPlantUMLLexer.h"

namespace {
constexpr Lexilla::LexicalClass classes[] = {
    {0, "default", "default", "Default"},
    {1, "comment", "comment", "Comment"},
    {2, "number", "literal numeric", "Number or hexadecimal color"},
    {3, "keyword", "keyword", "PlantUML command"},
    {4, "string", "literal string", "Quoted string"},
    {5, "operator", "operator", "Arrow or punctuation"},
    {6, "error", "error", "Error"},
    {7, "property", "property", "Skin parameter"},
};
constexpr std::string_view keywords =
    " actor participant boundary control entity database collections queue as "
    " title caption header footer legend endlegend note end over left right of "
    " rnote hnote endnote ref autonumber hide show footbox skinparam scale "
    " activate deactivate create destroy return newpage box endbox alt else "
    " opt loop par break critical group endgroup rect together class interface "
    " abstract enum annotation object package namespace component rectangle "
    " cloud node frame folder artifact storage file card usecase state choice "
    " fork join start stop if then endif repeat while endwhile switch case "
    " endswitch detach kill partition swimlane true false remove allowmixing "
    " sprite style endstyle circle diamond archimate minwidth mainframe "
    " address network json map salt allow_mixing mix_actor mix_usecase "
    " assert end title endheader endfooter split endsplit backward label goto "
    " arrow direction top bottom center rotate nopattern stereotype "
    " monochrome skin theme !include !include_once !include_many !define "
    " !undef !if !ifdef !ifndef !else !elseif !endif !function !endfunction "
    " !procedure !endprocedure !return !local !global !assert !log !theme ";
bool word(unsigned char c) { return std::isalnum(c) || c == '_' || c >= 128; }

class DPPlantUMLLexer final : public Lexilla::LexerBase {
public:
    DPPlantUMLLexer() : LexerBase(classes, std::size(classes)) {}
    const char *SCI_METHOD GetName() override { return "plantuml"; }
    int SCI_METHOD GetIdentifier() override { return SCLEX_CONTAINER; }
    void SCI_METHOD Fold(Sci_PositionU, Sci_Position, int, Scintilla::IDocument *) override {}
    void SCI_METHOD Lex(Sci_PositionU start, Sci_Position length, int, Scintilla::IDocument *doc) override {
        const Sci_Position end = std::min(doc->Length(), static_cast<Sci_Position>(start) + length);
        Sci_Position line = doc->LineFromPosition(start);
        int state = line > 0 ? doc->GetLineState(line - 1) : 0;
        while (doc->LineStart(line) < end) {
            const Sci_Position position = doc->LineStart(line);
            const Sci_Position next = std::min(doc->Length(), doc->LineStart(line + 1));
            if (next <= position) break;
            std::string text(next - position, '\0');
            doc->GetCharRange(text.data(), position, text.size());
            std::vector<char> styles(text.size(), 0);
            size_t i = 0;
            bool skinParameter = false;
            while (i < text.size()) {
                const size_t first = i;
                char style = 0;
                if (state == 1) {
                    style = 1;
                    while (i < text.size() && text.compare(i, 2, "'/") != 0) ++i;
                    if (i < text.size()) { i += 2; state = 0; }
                } else if (text.compare(i, 2, "/'") == 0) {
                    state = 1; style = 1; i += 2;
                } else if (text[i] == '\'') {
                    style = 1; i = text.size();
                } else if (text[i] == '"') {
                    style = 4; ++i;
                    while (i < text.size() && text[i] != '\r' && text[i] != '\n') {
                        if (text[i] == '\\' && i + 1 < text.size()) { i += 2; continue; }
                        if (text[i++] == '"') break;
                    }
                } else if (text[i] == '#' && i + 1 < text.size() && std::isxdigit(static_cast<unsigned char>(text[i + 1]))) {
                    ++i;
                    while (i < text.size() && std::isxdigit(static_cast<unsigned char>(text[i]))) ++i;
                    const size_t digits = i - first - 1;
                    if ((digits == 1 || digits == 3 || digits == 6 || digits == 8)
                        && (i == text.size() || !word(text[i]))) style = 2;
                } else if (std::isdigit(static_cast<unsigned char>(text[i]))) {
                    style = 2; ++i;
                    while (i < text.size() && (std::isdigit(static_cast<unsigned char>(text[i])) || text[i] == '.')) ++i;
                } else if (word(text[i]) || text[i] == '@' || text[i] == '!') {
                    ++i;
                    while (i < text.size() && word(text[i])) ++i;
                    std::string token = text.substr(first, i - first);
                    std::transform(token.begin(), token.end(), token.begin(), [](unsigned char c) { return std::tolower(c); });
                    if (skinParameter) { style = 7; skinParameter = false; }
                    else if (token.rfind("@start", 0) == 0 || token.rfind("@end", 0) == 0
                        || keywords.find(" " + token + " ") != std::string_view::npos) style = 3;
                    if (token == "skinparam") skinParameter = true;
                } else {
                    if (std::string_view("-=<>:{}[](),|+*\\").find(text[i]) != std::string_view::npos) style = 5;
                    ++i;
                }
                std::fill(styles.begin() + first, styles.begin() + i, style);
            }
            doc->StartStyling(position);
            doc->SetStyles(styles.size(), styles.data());
            if (doc->GetLineState(line) != state && next < doc->Length()) doc->ChangeLexerState(next, doc->Length());
            doc->SetLineState(line, state);
            ++line;
        }
    }
};
}
Scintilla::ILexer5 *DPCreatePlantUMLLexer() { return new DPPlantUMLLexer(); }
