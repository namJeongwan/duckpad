#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--output)
            [[ $# -ge 2 ]] || { echo "Missing value: $1" >&2; exit 64; }
            if [[ "$1" == --app ]]; then APP="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
        *) echo "Usage: $0 --app /path/Duckpad.app --output /path/Duckpad.dmg" >&2; exit 64 ;;
    esac
done
[[ -d "$APP" && "$APP" == *.app && -f "$APP/Contents/Info.plist" ]] || {
    echo "Provide an existing Duckpad .app bundle with --app" >&2; exit 64;
}
[[ -n "$OUTPUT" && "$OUTPUT" == *.dmg ]] || { echo "Provide a .dmg output path" >&2; exit 64; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 73; }
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
codesign --verify --deep --strict "$APP"

# Stage beside the output so publishing can use a no-overwrite hard link.
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/.duckpad-dmg.XXXXXX")"
MOUNT="$STAGING/mount"
MOUNTED=false
cleanup() {
    if [[ "$MOUNTED" == true ]]; then
        if ! hdiutil detach "$MOUNT" -quiet; then
            echo "Could not detach $MOUNT; preserved staging at $STAGING" >&2
            return
        fi
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$STAGING/contents/.background" "$MOUNT"
ditto "$APP" "$STAGING/contents/Duckpad.app"
ln -s /Applications "$STAGING/contents/Applications"
swift "$SCRIPT_DIR/render_dmg_background.swift" "$REPOSITORY_ROOT/Packaging/DMG" \
    "$STAGING/contents/.background/install.tiff"
hdiutil create -quiet -volname Duckpad -fs HFS+ -format UDRW \
    -srcfolder "$STAGING/contents" "$STAGING/writable.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$STAGING/writable.dmg"
MOUNTED=true
# Only this mounted image's Finder view is changed; requires a GUI login session.
osascript "$REPOSITORY_ROOT/Packaging/DMG/layout.applescript" "$MOUNT"
[[ -s "$MOUNT/.DS_Store" && "$(readlink "$MOUNT/Applications")" == /Applications ]]
codesign --verify --deep --strict "$MOUNT/Duckpad.app"
sync
hdiutil detach "$MOUNT" -quiet
MOUNTED=false
hdiutil convert -quiet "$STAGING/writable.dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$STAGING/final.dmg"
hdiutil verify "$STAGING/final.dmg"
python3 -c 'import os, sys; os.link(sys.argv[1], sys.argv[2])' "$STAGING/final.dmg" "$OUTPUT"
echo "$OUTPUT"
