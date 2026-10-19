#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash scripts/build_ghostty.sh --architecture native
PLATFORM_DIR="$(python3 - "$ROOT/Vendor/Ghostty/GhosttyKit.xcframework" "$(uname -m)" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
for library in plistlib.loads((root/'Info.plist').read_bytes())['AvailableLibraries']:
    if library['SupportedPlatform']=='macos' and sys.argv[2] in library['SupportedArchitectures']:
        print(root/library['LibraryIdentifier']); break
else: raise SystemExit('No compatible Ghostty framework')
PY
)"
OUTPUT="$ROOT/.build/i18n-inspector-snapshots"
mkdir -p "$OUTPUT"
BINDING_HEADERS="$(python3 - "$ROOT/.build/ghostty-source/.zig-cache" <<'PY'
from pathlib import Path
import sys
matches=sorted(Path(sys.argv[1]).rglob('dcimgui.h'))
if not matches: raise SystemExit('Ghostty generated ImGui headers missing')
print(matches[0].parent)
PY
)"
xcrun clang++ -std=c++17 -fobjc-arc tests/native/InspectorLocalization.mm \
  -I"$PLATFORM_DIR/Headers" -I"$BINDING_HEADERS" "$PLATFORM_DIR/libghostty-fat.a" \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreText \
  -framework Carbon -framework IOSurface -framework Security -lresolv -lz \
  -o .build/i18n-inspector-smoke
GHOSTTY_RESOURCES_DIR="$ROOT/.build/ghostty-source/zig-out/share/ghostty" \
  .build/i18n-inspector-smoke "$ROOT/Sources/DuckpadLocalization/Resources" "$OUTPUT"
