#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product DuckpadPerformanceBenchmark >/dev/null
BIN="$(swift build -c release --show-bin-path)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/duckpad-native-performance.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
OBJECTS=()
for TARGET in DuckpadScintillaBridge DuckpadLexilla; do
    if [[ -f "$BIN/$TARGET.o" ]]; then
        OBJECTS+=("$BIN/$TARGET.o")
    else
        OBJECTS+=("$BIN/$TARGET.build/"*.o)
    fi
done
for TEST in PerformanceCorrectness PerformanceLayout PerformanceWidths; do
    clang++ -std=c++17 -O2 -fobjc-arc "tests/native/$TEST.mm" \
        -IVendor/Scintilla/5.6.6/include -IVendor/Scintilla/5.6.6/src \
        -IVendor/Scintilla/5.6.6/cocoa -IVendor/Scintilla/5.6.6/bridge/include \
        -IVendor/Scintilla/5.6.6/bridge -IVendor/Lexilla/5.5.3/include \
        "${OBJECTS[@]}" -framework AppKit -framework QuartzCore -o "$TEMP/$TEST"
    "$TEMP/$TEST"
done
