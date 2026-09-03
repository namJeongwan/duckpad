#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$REPOSITORY_ROOT/build/Duckpad.app"
IDENTITY="-"
SHORT_VERSION="0.1.0"
BUILD_VERSION="1"
NOTARY_PROFILE=""
ARCHITECTURE="universal"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --short-version) SHORT_VERSION="$2"; shift 2 ;;
        --build-version) BUILD_VERSION="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --architecture) ARCHITECTURE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
done

if [[ "$OUTPUT" != /* ]]; then OUTPUT="$REPOSITORY_ROOT/$OUTPUT"; fi
if [[ "${OUTPUT##*.}" != "app" ]]; then
    echo "Output must be a .app path" >&2
    exit 64
fi
OUTPUT_PARENT_INPUT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT_INPUT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_INPUT" && pwd -P)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo "Output already exists: $OUTPUT" >&2
    exit 73
fi
if [[ ! "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || [[ ! "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid version" >&2
    exit 64
fi
if [[ "$ARCHITECTURE" != "universal" && "$ARCHITECTURE" != "native" ]]; then
    echo "Architecture must be universal or native" >&2
    exit 64
fi
if [[ -n "$NOTARY_PROFILE" && "$IDENTITY" == "-" ]]; then
    echo "Notarization requires a non-ad-hoc signing identity" >&2
    exit 64
fi

STAGING_ROOT="$(mktemp -d "$OUTPUT_PARENT/.duckpad-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/Duckpad.app"
XPC="$APP/Contents/XPCServices/DuckpadPluginRuntime.xpc"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS"
if [[ "$ARCHITECTURE" == "universal" ]]; then
    for BUILD_ARCH in arm64 x86_64; do
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadApp
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadPluginRuntime
    done
    ARM_BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --arch arm64 --show-bin-path)"
    INTEL_BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --arch x86_64 --show-bin-path)"
    lipo -create "$ARM_BIN_PATH/DuckpadApp" "$INTEL_BIN_PATH/DuckpadApp" -output "$APP/Contents/MacOS/Duckpad"
    lipo -create "$ARM_BIN_PATH/DuckpadPluginRuntime" "$INTEL_BIN_PATH/DuckpadPluginRuntime" -output "$XPC/Contents/MacOS/DuckpadPluginRuntime"
    chmod 0755 "$APP/Contents/MacOS/Duckpad" "$XPC/Contents/MacOS/DuckpadPluginRuntime"
    BIN_PATH="$ARM_BIN_PATH"
else
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadApp
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadPluginRuntime
    BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --show-bin-path)"
    install -m 0755 "$BIN_PATH/DuckpadApp" "$APP/Contents/MacOS/Duckpad"
    install -m 0755 "$BIN_PATH/DuckpadPluginRuntime" "$XPC/Contents/MacOS/DuckpadPluginRuntime"
fi
install -m 0644 "$REPOSITORY_ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Packaging/PluginRuntime-Info.plist" "$XPC/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Sources/DuckpadApp/Resources/Duckpad.icns" "$APP/Contents/Resources/Duckpad.icns"

for RESOURCE_BUNDLE in Duckpad_DuckpadApp.bundle Duckpad_DuckpadEditorAdapter.bundle Duckpad_DuckpadInfrastructure.bundle; do
    if [[ ! -d "$BIN_PATH/$RESOURCE_BUNDLE" ]]; then
        echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
        exit 66
    fi
    ditto "$BIN_PATH/$RESOURCE_BUNDLE" "$APP/Contents/Resources/$RESOURCE_BUNDLE"
done

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$XPC/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$XPC/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" "$XPC/Contents/Info.plist" >/dev/null

SIGNING_FLAGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then SIGNING_FLAGS+=(--timestamp); fi
codesign "${SIGNING_FLAGS[@]}" --entitlements "$REPOSITORY_ROOT/Packaging/PluginRuntime.entitlements" "$XPC"
codesign "${SIGNING_FLAGS[@]}" --entitlements "$REPOSITORY_ROOT/Packaging/Duckpad.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

python3 "$REPOSITORY_ROOT/scripts/macos_bundle_publish.py" "$APP" "$OUTPUT"
codesign --verify --deep --strict --verbose=2 "$OUTPUT"

if [[ -n "$NOTARY_PROFILE" ]]; then
    ARCHIVE="$STAGING_ROOT/Duckpad.zip"
    ditto -c -k --keepParent "$OUTPUT" "$ARCHIVE"
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT"
    xcrun stapler validate "$OUTPUT"
    spctl --assess --type execute --verbose=2 "$OUTPUT"
fi

echo "$OUTPUT"
