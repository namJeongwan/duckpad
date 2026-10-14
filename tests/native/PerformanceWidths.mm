#import <AppKit/AppKit.h>
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
#include "ScintillaStructures.h"
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

#include "UniqueString.h"
#include <set>
#include "Selection.h"
#include "ContractionState.h"
#include "Indicator.h"
#include "LineMarker.h"
#include "Style.h"
#include "ViewStyle.h"
#include "EditModel.h"
#include "MarginView.h"
#include "EditView.h"

using namespace Scintilla;
using namespace Scintilla::Internal;
static size_t checks = 0;
static void check(bool value, const char *message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
class Model final : public EditModel {
public:
    Sci::Line TopLineOfMain() const noexcept override { return 0; }
    Scintilla::Internal::Point GetVisibleOriginInMain() const override { return Scintilla::Internal::Point(); }
    Sci::Line LinesOnScreen() const override { return 40; }
};
static void tabLimits() {
    EditView view;
    view.tabWidthMinimumPixels = 2;
    check(view.NextTabstopPos(0, 99999, 0x1p-16) == 100001 + 0x1p-16,
        "large tab index overflow");
    view.AddTabstop(0, 2147483647);
    check(view.NextTabstopPos(0, 2147483644.0, 32) == 2147483647.0,
        "last representable custom tab");
    check(view.NextTabstopPos(0, 2147483647.0, 32) == 2147483680.0,
        "pixel position beyond custom tab range");
    view.ClearAllTabstops();
    for (double width : {0.125, 7.82666015625, 31.306640625, 128.0})
        for (int pixel = 0; pixel < 10000; ++pixel) {
            const double x = pixel + 0.25;
            const double original = (static_cast<int>((x + 2) / width) + 1) * width;
            check(view.NextTabstopPos(0, x, width) == original, "ordinary tab calculation changed");
        }
}
static void widths() {
    auto surface = Surface::Allocate(Technology::Default);
    for (bool tabs : {false, true}) {
        Model model;
        model.pdoc->SetDBCSCodePage(CpUtf8);
        model.reprs->SetDefaultRepresentations(CpUtf8);
        std::string text;
        while (text.size() < 50000) text += tabs ? "payload\t1234\tvalue\t" : "payload 1234 value ";
        model.pdoc->InsertString(0, text);
        std::vector<char> styles(text.size());
        for (size_t i = 0; i < styles.size(); ++i) styles[i] = (i / 23) % 4;
        model.pdoc->StartStyling(0); model.pdoc->SetStyles(styles.size(), styles.data());
        for (double advance : {7.82666015625, 0.125, 1.0/3, 5.01, 0x1p-16})
        for (int tabColumns : {1, 3, 4, 256})
        for (bool customTabs : {false, true})
        for (bool differentWidth : {false, true}) {
            ViewStyle optimized, reference;
            for (ViewStyle *style : {&optimized, &reference}) {
                style->viewEOL = false; style->someStylesForceCase = false;
                style->wrap.state = Wrap::Word; style->wrap.indentMode = WrapIndentMode::Fixed;
                style->wrap.visualStartIndent = 0; style->wrap.visualFlags = WrapVisualFlag::None;
                style->tabWidth = advance * tabColumns; style->aveCharWidth = advance;
                for (size_t i = 0; i < style->styles.size(); ++i) {
                    auto &s = style->styles[i];
                    s.visible = true; s.italic = false; s.monospaceASCII = true;
                    s.monospaceCharacterWidth = differentWidth && i == 2 ? advance * 1.125 : advance;
                }
            }
            // Unused styles cannot affect text geometry. These different widths
            // force the existing scalar layout as an independent reference.
            for (size_t i = 240; i < 256; ++i) reference.styles[i].monospaceCharacterWidth = advance * 2;
            EditView a, b;
            if (customTabs) for (int stop : {3, 17, 101, 99999}) {
                a.AddTabstop(0, stop); b.AddTabstop(0, stop);
            }
            LineLayout actual(0, text.size()), expected(0, text.size());
            a.LayoutLine(model, surface.get(), optimized, &actual, 700);
            b.LayoutLine(model, surface.get(), reference, &expected, 700);
            check(std::memcmp(actual.positions.get(), expected.positions.get(),
                (text.size() + 1) * sizeof(XYPOSITION)) == 0, "monospace positions differ from scalar layout");
            check(actual.lines == expected.lines, "monospace wrap count differs");
            for (int line = 0; line < actual.lines; ++line)
                check(actual.LineStart(line) == expected.LineStart(line), "monospace wrap boundary differs");
        }
    }
}
static void segments() {
    Model model;
    model.pdoc->SetDBCSCodePage(CpUtf8);
    ViewStyle styles; styles.indicatorsSetFore = false;
    for (bool custom : {false, true}) for (bool mixed : {false, true}) {
        model.reprs->SetDefaultRepresentations(CpUtf8);
        if (custom) {
            model.reprs->SetRepresentation("한", "K");
            model.reprs->SetRepresentation("́", "COMB");
            model.reprs->SetRepresentation("\r\n", "CRLF");
        }
        for (const std::string unit : {std::string("éäñ 각 "), std::string("한🦆\tA\r\n"),
            std::string("x\x80\xf0\x9f y \xe2\x80\xa8 \xc2\xa0 ")}) {
            std::string text; while (text.size() < 50000) text += unit;
            model.pdoc->DeleteChars(0, model.pdoc->Length()); model.pdoc->InsertString(0, text);
            LineLayout line(0, text.size());
            std::memcpy(line.chars.get(), text.data(), text.size());
            line.chars[text.size()] = 0;
            std::fill(line.styles.get(), line.styles.get() + text.size() + 1, 0);
            if (mixed) for (size_t i = 17; i < text.size(); i += 37) line.styles[i] = 1;
            for (int edge : {-1, 101, 4097}) {
                line.edgeColumn = edge;
                BreakFinder fast(&line, nullptr, Range(0, text.size()), 0, 0,
                    BreakFinder::BreakFor::Text, model.pdoc, model.reprs.get(), &styles);
                BreakFinder reference(&line, nullptr, Range(0, text.size()), 0, 0,
                    BreakFinder::BreakFor::Foreground, model.pdoc, model.reprs.get(), &styles);
                while (reference.More()) {
                    check(fast.More(), "missing layout segment");
                    const auto a = fast.Next(), b = reference.Next();
                    check(a.start == b.start && a.length == b.length && a.representation == b.representation,
                        "uniform-style segmentation differs");
                }
                check(!fast.More(), "extra layout segment");
            }
        }
    }
}
int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    try { tabLimits(); widths(); segments(); std::cout << "PASS exact monospace positions and segmentation checks=" << checks << '\n'; }
    catch (const std::exception &error) { std::cerr << "FAIL " << error.what() << " after " << checks << " checks\n"; return 1; }
}}
