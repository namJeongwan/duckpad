// Duckpad-owned, bounded incremental log styling. No document snapshots or regex.
#import <Foundation/Foundation.h>
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cctype>
#include <map>
#include <memory>
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
#include "DPAsyncLexer.h"
#include "DPLogLexer.h"

namespace {
using Scintilla::IDocument;
constexpr Sci_Position sliceBytes = 16 * 1024;
constexpr size_t maximumCheckpoints = 16384;
constexpr Lexilla::LexicalClass classes[] = {{0, "default", "default", "Default"}};
struct Ansi {
    int foreground = -1, background = -1; // -1 default; 0..255 indexed; 256+RGB true colour
    unsigned attributes = 0; // bold, italic, underline, dim, inverse
};
struct Span { size_t first, end; int role; };
bool word(unsigned char c) { return std::isalnum(c) || c == '_' || c >= 128; }
int severity(std::string_view token) {
    std::string upper(token);
    for (char &c : upper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    if (upper == "TRACE" || upper == "VERBOSE") return 1;
    if (upper == "DEBUG" || upper == "DBG") return 2;
    if (upper == "INFO" || upper == "INFORMATION" || upper == "NOTICE") return 3;
    if (upper == "WARN" || upper == "WARNING" || upper == "WRN") return 4;
    if (upper == "ERROR" || upper == "ERR" || upper == "FAIL" || upper == "FAILURE" || upper == "SEVERE") return 5;
    if (upper == "FATAL" || upper == "CRITICAL" || upper == "CRIT" || upper == "PANIC" || upper == "FTL") return 6;
    return 0;
}
// Only complete, bounded SGR controls are interpreted. OSC, cursor movement,
// malformed/unfinished escapes remain original visible text; nothing executes.
size_t sgr(std::string_view text, size_t i, Ansi *state) {
    if (i + 2 >= text.size() || text[i] != '\x1b' || text[i + 1] != '[') return 0;
    std::array<int, 32> values{}; size_t count = 0, j = i + 2; int value = 0;
    for (; j < text.size() && j - i < 128; ++j) {
        const unsigned char c = text[j];
        if (c >= '0' && c <= '9') { value = value * 10 + c - '0'; if (value > 999) return 0; }
        else if (c == ';' || c == 'm') {
            if (count == values.size()) return 0;
            values[count++] = value; value = 0;
            if (c == 'm') break;
        } else return 0;
    }
    if (j == text.size() || j - i >= 128 || text[j] != 'm') return 0;
    if (state) for (size_t n = 0; n < count; ++n) {
        const int v = values[n];
        if (v == 0) *state = {};
        else if (v == 1) state->attributes |= 1;
        else if (v == 2) state->attributes |= 8;
        else if (v == 3) state->attributes |= 2;
        else if (v == 4) state->attributes |= 4;
        else if (v == 7) state->attributes |= 16;
        else if (v == 22) state->attributes &= ~9U;
        else if (v == 23) state->attributes &= ~2U;
        else if (v == 24) state->attributes &= ~4U;
        else if (v == 27) state->attributes &= ~16U;
        else if (v == 39) state->foreground = -1;
        else if (v == 49) state->background = -1;
        else if (v >= 30 && v <= 37) state->foreground = v - 30;
        else if (v >= 90 && v <= 97) state->foreground = v - 90 + 8;
        else if (v >= 40 && v <= 47) state->background = v - 40;
        else if (v >= 100 && v <= 107) state->background = v - 100 + 8;
        else if (v == 38 || v == 48) {
            int color = -1;
            if (n + 2 < count && values[n + 1] == 5 && values[n + 2] <= 255) {
                color = values[n + 2]; n += 2;
            } else if (n + 4 < count && values[n + 1] == 2 && values[n + 2] <= 255
                       && values[n + 3] <= 255 && values[n + 4] <= 255) {
                color = 256 + (values[n + 2] << 16 | values[n + 3] << 8 | values[n + 4]); n += 4;
            } else { break; } // Do not reinterpret malformed RGB operands as SGR commands.
            if (v == 38) state->foreground = color; else state->background = color;
        }
    }
    return j - i + 1;
}
std::vector<Span> headerSpans(std::string_view raw) {
    std::string visible; std::vector<size_t> positions;
    for (size_t i = 0; i < raw.size();) {
        if (const size_t length = sgr(raw, i, nullptr)) { i += length; continue; }
        positions.push_back(i); visible += raw[i++];
    }
    std::vector<Span> spans;
    auto add = [&](size_t first, size_t end, int role) {
        if (end > first && end <= positions.size()) spans.push_back({positions[first], positions[end - 1] + 1, role});
    };
    size_t first = visible.find_first_not_of(" \t[");
    if (first == std::string::npos) return spans;
    const std::string_view text(visible);
    const auto trimmed = text.substr(first);
    if (trimmed.rfind("at ", 0) == 0 || trimmed.rfind("Caused by:", 0) == 0
        || trimmed.rfind("Traceback (most recent call last)", 0) == 0 || trimmed.rfind("File \"", 0) == 0) {
        add(first, visible.size(), 8); return spans;
    }
    // ISO dates/time plus common day/month timestamps; colour the timestamp,
    // rather than guessing a logging-library identity from the surrounding text.
    if (std::isdigit(static_cast<unsigned char>(visible[first]))) {
        size_t end = first; int separators = 0;
        while (end < visible.size() && end - first < 40) {
            const char c = visible[end];
            if (std::isdigit(static_cast<unsigned char>(c)) || std::string_view("-/:.,TZ+").find(c) != std::string_view::npos) {
                if (c == '-' || c == ':' || c == '/') ++separators;
                ++end;
            } else if (c == ' ' && end + 3 < visible.size() && visible[end + 3] == ':') ++end;
            else break;
        }
        if (separators >= 2) add(first, end, 7);
    }
    for (size_t i = 0; i < visible.size();) {
        if (!std::isalpha(static_cast<unsigned char>(visible[i]))) { ++i; continue; }
        size_t end = i + 1;
        while (end < visible.size() && word(static_cast<unsigned char>(visible[end]))) ++end;
        const auto token = text.substr(i, end - i);
        if (token == "level" || token == "severity" || token == "levelname") add(i, end, 9);
        else if (const int role = severity(token); role && (i == 0 || !word(static_cast<unsigned char>(visible[i - 1])))) add(i, end, role);
        i = end;
    }
    std::sort(spans.begin(), spans.end(), [](const Span &a, const Span &b) { return a.first < b.first; });
    return spans;
}
int bgr(int rgb) { return (rgb & 255) << 16 | (rgb & 0xFF00) | (rgb >> 16 & 255); }
struct State {
    IDocument *document = nullptr;
    Sci_Position next = 0, knownLength = 0;
    uint64_t generation = 0;
    bool scheduled = false, started = false, mutationReported = false;
    Ansi ansi;
    std::map<Sci_Position, Ansi> checkpoints{{0, {}}};
    DPLogStatistics statistics;
    int foreground = 0xD4D4D4, background = 0x1E1E1E;
    bool dark = true;
};
int rgb(int color, const State &state, bool foreground) {
    if (color >= 256) return color - 256;
    constexpr int normal[] = {0x202020, 0xCD3131, 0x16813D, 0x9A6700, 0x245EDB, 0xA626A4, 0x087F8C, 0xD4D4D4,
                             0x767676, 0xF14C4C, 0x23A54A, 0xCCA700, 0x3B78FF, 0xD670D6, 0x139AA4, 0xF2F2F2};
    if (color < 16) {
        int result = normal[color];
        if (foreground && state.dark && color == 2) result = 0x23D18B;
        if (foreground && state.dark && color == 3) result = 0xE5E510;
        if (foreground && state.dark && color == 6) result = 0x29B8DB;
        if (foreground && !state.dark && (color == 7 || color == 15)) result = color == 7 ? 0x5A5A5A : 0x303030;
        if (foreground && state.dark && color == 0) result = 0x767676;
        return result;
    }
    if (color >= 232) { int c = 8 + (color - 232) * 10; return c << 16 | c << 8 | c; }
    constexpr int cube[] = {0, 95, 135, 175, 215, 255};
    color -= 16; return cube[color / 36] << 16 | cube[color / 6 % 6] << 8 | cube[color % 6];
}
void colors(const Ansi &ansi, const State &state, int &fore, int &back) {
    int f = ansi.foreground >= 0 ? rgb(ansi.foreground, state, true) : state.foreground;
    int b = ansi.background >= 0 ? rgb(ansi.background, state, false) : state.background;
    if (ansi.attributes & 16) std::swap(f, b);
    if (ansi.attributes & 8) {
        int dim = 0;
        for (int shift : {0, 8, 16}) dim |= (((f >> shift & 255) * 2 + (b >> shift & 255)) / 3) << shift;
        f = dim;
    }
    fore = ansi.foreground >= 0 || (ansi.attributes & 24) ? SC_INDICVALUEBIT | bgr(f) : 0;
    back = ansi.background >= 0 || (ansi.attributes & 16) ? SC_INDICVALUEBIT | bgr(b) : 0;
}
void schedule(std::shared_ptr<State> state);
void invalidate(const std::shared_ptr<State> &state, Sci_Position position) {
    ++state->generation; state->scheduled = false;
    // Revisit the last bounded block for a split SGR/header token. No long-line
    // scan from column zero on each Tail append.
    position = std::max<Sci_Position>(0, std::min(position, state->next) - 128);
    auto checkpoint = state->checkpoints.upper_bound(position);
    if (checkpoint != state->checkpoints.begin()) --checkpoint;
    state->next = checkpoint->first; state->ansi = checkpoint->second;
    state->checkpoints.erase(std::next(checkpoint), state->checkpoints.end());
}
void slice(const std::shared_ptr<State> &state) {
    auto *doc = state->document;
    if (!doc) return;
    const auto began = std::chrono::steady_clock::now();
    const Sci_Position length = doc->Length();
    state->knownLength = length; state->mutationReported = false;
    if (state->next >= length) { doc->StartStyling(length); return; }
    const Sci_Position start = state->next;
    Sci_Position end = std::min(length, start + sliceBytes);
    std::string bytes(static_cast<size_t>(std::min(length - start, sliceBytes + 128)), '\0');
    doc->GetCharRange(bytes.data(), start, bytes.size());
    std::vector<char> styles(bytes.size(), 0);
    // Clear only the range being recalculated, preserving search/word indicators.
    for (int indicator : {DPLogForegroundIndicator, DPLogBackgroundIndicator}) {
        doc->DecorationSetCurrentIndicator(indicator); doc->DecorationFillRange(start, 0, bytes.size());
    }
    Sci_Position line = -1, lineStart = 0, lineEnd = start;
    std::vector<Span> spans;
    int runFore = 0, runBack = 0; size_t run = 0;
    auto flush = [&](size_t until) {
        if (until <= run) return;
        for (const auto &[indicator, value] : {std::pair{DPLogForegroundIndicator, runFore}, std::pair{DPLogBackgroundIndicator, runBack}}) {
            if (value) { doc->DecorationSetCurrentIndicator(indicator); doc->DecorationFillRange(start + run, value, until - run); }
        }
        run = until;
    };
    size_t i = 0;
    for (; start + static_cast<Sci_Position>(i) < end;) {
        const Sci_Position position = start + i;
        if (position >= lineEnd) {
            line = doc->LineFromPosition(position); lineStart = doc->LineStart(line);
            lineEnd = std::min(length, doc->LineStart(line + 1));
            std::string prefix(static_cast<size_t>(std::min<Sci_Position>(512, lineEnd - lineStart)), '\0');
            doc->GetCharRange(prefix.data(), lineStart, prefix.size());
            spans = headerSpans(prefix);
        }
        if (const size_t control = sgr(bytes, i, &state->ansi)) {
            flush(i);
            std::fill(styles.begin() + i, styles.begin() + i + control, DPLogEscapeStyle);
            i += control; run = i;
            end = std::max(end, start + static_cast<Sci_Position>(i));
            if (std::chrono::steady_clock::now() - began >= std::chrono::milliseconds(2)) break;
            continue;
        }
        int fore, back; colors(state->ansi, *state, fore, back);
        if (fore != runFore || back != runBack) { flush(i); runFore = fore; runBack = back; }
        int role = 0;
        const size_t offset = position - lineStart;
        if (offset < 512) for (const Span &span : spans) { if (offset >= span.first && offset < span.end) { role = span.role; break; } }
        // Keep unformatted text in the existing default style. Changing every
        // byte to an identical alternate style invalidates long-line layout
        // on every asynchronous slice, even for offscreen ANSI colour work.
        const int attributes = state->ansi.attributes & 7;
        styles[i] = role || attributes ? static_cast<char>(DPLogStyleBase + role * 8 + attributes) : 0;
        ++i;
        if (i % 256 == 0 && std::chrono::steady_clock::now() - began >= std::chrono::milliseconds(2)) break;
    }
    flush(i);
    doc->StartStyling(start); doc->SetStyles(i, styles.data());
    state->next = start + i;
    if (state->next - state->checkpoints.rbegin()->first >= sliceBytes) {
        state->checkpoints[state->next] = state->ansi;
        if (state->checkpoints.size() > maximumCheckpoints) state->checkpoints.erase(std::next(state->checkpoints.begin()));
    }
    state->statistics.styledBytes += i;
    const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - began).count();
    state->statistics.maximumSliceMicroseconds = std::max(state->statistics.maximumSliceMicroseconds, static_cast<uint64_t>(elapsed));
    // Prevent Scintilla from synchronously restyling the backlog during paint.
    // The original text stays live; bounded main-queue slices fill its styles.
    doc->StartStyling(length);
}
void schedule(std::shared_ptr<State> state) {
    if (!state->document || !state->started || state->scheduled || state->next >= state->document->Length()) return;
    state->scheduled = true;
    const auto generation = state->generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!state->document || generation != state->generation) return;
        state->scheduled = false;
        slice(state); schedule(state);
    });
}
class LogLexer final : public Lexilla::LexerBase {
    std::shared_ptr<State> state = std::make_shared<State>();
public:
    LogLexer() : LexerBase(classes, std::size(classes)) {}
    ~LogLexer() override { ++state->generation; state->document = nullptr; }
    const char *SCI_METHOD GetName() override { return "duckpadlog"; }
    int SCI_METHOD GetIdentifier() override { return SCLEX_CONTAINER; }
    void SCI_METHOD Fold(Sci_PositionU, Sci_Position, int, IDocument *) override {}
    void SCI_METHOD Lex(Sci_PositionU start, Sci_Position, int, IDocument *doc) override {
        if (state->document && state->document != doc) { invalidate(state, 0); state->started = false; }
        state->document = doc; state->started = true;
        // The bridge normally reports mutations before they move byte offsets.
        // This also handles initial loads/clients that replace the document.
        if (state->knownLength != doc->Length() && !state->mutationReported) invalidate(state, std::min<Sci_Position>(start, state->next));
        slice(state); schedule(state);
    }
    void *SCI_METHOD PrivateCall(int operation, void *pointer) override {
        if (operation == DPAsyncLexerPendingOperation) return state->document && state->next < state->document->Length() ? this : nullptr;
        if (operation == DPLogStatisticsOperation) { if (pointer) *static_cast<DPLogStatistics *>(pointer) = state->statistics; return nullptr; }
        if (operation == DPLogInvalidateOperation) { state->mutationReported = true; invalidate(state, static_cast<Sci_Position>(reinterpret_cast<uintptr_t>(pointer))); schedule(state); }
        return nullptr;
    }
    Sci_Position SCI_METHOD PropertySet(const char *key, const char *value) override {
        int *destination = nullptr;
        if (std::string_view(key) == "duckpad.log.foreground") destination = &state->foreground;
        if (std::string_view(key) == "duckpad.log.background") destination = &state->background;
        if (std::string_view(key) == "duckpad.log.dark") {
            const bool next = std::string_view(value) == "1";
            if (next == state->dark) return -1;
            state->dark = next; invalidate(state, 0); schedule(state); return 0;
        }
        if (!destination) return -1;
        const int next = std::atoi(value);
        if (*destination == next) return -1;
        *destination = next; invalidate(state, 0); schedule(state); return 0;
    }
};
}
Scintilla::ILexer5 *DPCreateLogLexer() { return new LogLexer(); }
