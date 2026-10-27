#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$REPOSITORY_ROOT/build/Duckpad.app"
IDENTITY="-"
SHORT_VERSION="0.16.0"
BUILD_VERSION="68"
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

"$SCRIPT_DIR/build_ghostty.sh" --architecture "$ARCHITECTURE"
python3 "$SCRIPT_DIR/build_ripgrep.py" --architecture "$ARCHITECTURE"

STAGING_ROOT="$(mktemp -d "$OUTPUT_PARENT/.duckpad-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/Duckpad.app"
XPC="$APP/Contents/XPCServices/DuckpadPluginRuntime.xpc"
INSTALLER="$APP/Contents/XPCServices/DuckpadNativeInstaller.xpc"
TERMINAL="$APP/Contents/XPCServices/DuckpadTerminalHost.xpc"
mkdir -p "$TERMINAL/Contents/MacOS"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS" "$INSTALLER/Contents/MacOS"
if [[ "$ARCHITECTURE" == "universal" ]]; then
    for BUILD_ARCH in arm64 x86_64; do
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadApp
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadPluginRuntime
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadTerminalHost
        swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --product DuckpadNativeInstaller
        # SwiftPM's Xcode build system shares one products path between arches.
        # Preserve each completed build before the next architecture replaces it.
        ARCH_BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --arch "$BUILD_ARCH" --show-bin-path)"
        ARCH_SNAPSHOT="$STAGING_ROOT/$BUILD_ARCH"
        mkdir -p "$ARCH_SNAPSHOT"
        for PRODUCT in DuckpadApp DuckpadPluginRuntime DuckpadNativeInstaller DuckpadTerminalHost; do
            [[ "$(lipo -archs "$ARCH_BIN_PATH/$PRODUCT")" == "$BUILD_ARCH" ]]
            install -m 0755 "$ARCH_BIN_PATH/$PRODUCT" "$ARCH_SNAPSHOT/$PRODUCT"
        done
        for RESOURCE_BUNDLE in "$ARCH_BIN_PATH"/*.bundle; do
            [[ -d "$RESOURCE_BUNDLE" ]] || continue
            ditto "$RESOURCE_BUNDLE" "$ARCH_SNAPSHOT/$(basename "$RESOURCE_BUNDLE")"
        done
    done
    ARM_BIN_PATH="$STAGING_ROOT/arm64"
    INTEL_BIN_PATH="$STAGING_ROOT/x86_64"
    lipo -create "$ARM_BIN_PATH/DuckpadApp" "$INTEL_BIN_PATH/DuckpadApp" -output "$APP/Contents/MacOS/Duckpad"
    lipo -create "$ARM_BIN_PATH/DuckpadPluginRuntime" "$INTEL_BIN_PATH/DuckpadPluginRuntime" -output "$XPC/Contents/MacOS/DuckpadPluginRuntime"
    lipo -create "$ARM_BIN_PATH/DuckpadNativeInstaller" "$INTEL_BIN_PATH/DuckpadNativeInstaller" -output "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller"
    lipo -create "$ARM_BIN_PATH/DuckpadTerminalHost" "$INTEL_BIN_PATH/DuckpadTerminalHost" -output "$TERMINAL/Contents/MacOS/DuckpadTerminalHost"
    chmod 0755 "$TERMINAL/Contents/MacOS/DuckpadTerminalHost"
    chmod 0755 "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller"
    chmod 0755 "$APP/Contents/MacOS/Duckpad" "$XPC/Contents/MacOS/DuckpadPluginRuntime"
    BIN_PATH="$ARM_BIN_PATH"
else
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadApp
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadPluginRuntime
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadTerminalHost
    swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadNativeInstaller
    BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --show-bin-path)"
    install -m 0755 "$BIN_PATH/DuckpadApp" "$APP/Contents/MacOS/Duckpad"
    install -m 0755 "$BIN_PATH/DuckpadTerminalHost" "$TERMINAL/Contents/MacOS/DuckpadTerminalHost"
    install -m 0755 "$BIN_PATH/DuckpadNativeInstaller" "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller"
    install -m 0755 "$BIN_PATH/DuckpadPluginRuntime" "$XPC/Contents/MacOS/DuckpadPluginRuntime"
fi
install -m 0644 "$REPOSITORY_ROOT/Packaging/TerminalHost-Info.plist" "$TERMINAL/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Packaging/PluginRuntime-Info.plist" "$XPC/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Packaging/NativeInstaller-Info.plist" "$INSTALLER/Contents/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/Sources/DuckpadApp/Resources/Duckpad.icns" "$APP/Contents/Resources/Duckpad.icns"

ditto "$REPOSITORY_ROOT/.build/ghostty-source/zig-out/share/ghostty" "$APP/Contents/Resources/ghostty"
ditto "$REPOSITORY_ROOT/.build/ghostty-source/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"

mkdir -p "$APP/Contents/Helpers"
install -m 0755 "$REPOSITORY_ROOT/.build/ripgrep/15.1.0/$ARCHITECTURE/rg" "$APP/Contents/Helpers/rg"
install -m 0644 "$REPOSITORY_ROOT/Vendor/Ripgrep/manifest.json" "$APP/Contents/Resources/ripgrep-version.json"

# Binary distributions retain the notices required by the bundled engines.
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
install -m 0644 "$REPOSITORY_ROOT/Vendor/Ghostty/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/Ghostty.txt"
install -m 0644 "$REPOSITORY_ROOT/Vendor/Scintilla/5.6.6/License.txt" "$APP/Contents/Resources/ThirdPartyLicenses/Scintilla.txt"
install -m 0644 "$REPOSITORY_ROOT/Vendor/Lexilla/5.5.3/License.txt" "$APP/Contents/Resources/ThirdPartyLicenses/Lexilla.txt"
install -m 0644 "$REPOSITORY_ROOT/Vendor/WAMR/2.4.5/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/WAMR.txt"
install -m 0644 "$REPOSITORY_ROOT/.build/checkouts/Sparkle/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"

ditto "$REPOSITORY_ROOT/Vendor/Ripgrep/NOTICES" "$APP/Contents/Resources/ThirdPartyLicenses/Ripgrep"

python3 "$REPOSITORY_ROOT/scripts/collect_ghostty_licenses.py" "$REPOSITORY_ROOT/.build/ghostty-source" "$APP/Contents/Resources/ThirdPartyLicenses/GhosttyDependencies"

# SwiftPM links the binary framework; the standalone bundle must embed it,
# including its symlinks and out-of-sandbox installer service.
SPARKLE_SOURCE="$REPOSITORY_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SOURCE" "$SPARKLE"
# Duckpad already has outgoing network access, so Sparkle's downloader XPC is unused.
rm -rf "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"

for RESOURCE_BUNDLE in Duckpad_DuckpadTerminalAdapter.bundle Duckpad_DuckpadApp.bundle Duckpad_DuckpadEditorAdapter.bundle Duckpad_DuckpadInfrastructure.bundle Duckpad_DuckpadPresentation.bundle Duckpad_DuckpadLocalization.bundle; do
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
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$INSTALLER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$INSTALLER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$TERMINAL/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$TERMINAL/Contents/Info.plist"
plutil -lint "$TERMINAL/Contents/Info.plist" "$APP/Contents/Info.plist" "$XPC/Contents/Info.plist" "$INSTALLER/Contents/Info.plist" >/dev/null

SIGNING_FLAGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then SIGNING_FLAGS+=(--timestamp); fi
codesign "${SIGNING_FLAGS[@]}" --identifier com.namjeongwan.duckpad.search --entitlements "$REPOSITORY_ROOT/Packaging/SearchHelper.entitlements" "$APP/Contents/Helpers/rg"
codesign "${SIGNING_FLAGS[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGNING_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGNING_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGNING_FLAGS[@]}" "$SPARKLE"
codesign "${SIGNING_FLAGS[@]}" --entitlements "$REPOSITORY_ROOT/Packaging/PluginRuntime.entitlements" "$XPC"
codesign "${SIGNING_FLAGS[@]}" "$INSTALLER"
codesign "${SIGNING_FLAGS[@]}" "$TERMINAL"
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
