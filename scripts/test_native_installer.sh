#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="${1:?Pass the signed Clipboard .duckpad-plugin directory}"
swift build --package-path "$ROOT" --product DuckpadApp
swift build --package-path "$ROOT" --product DuckpadNativeInstaller
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
STAGING="$(mktemp -d /tmp/duckpad-native-installer-smoke.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Duckpad.app"
HELPER="$APP/Contents/XPCServices/DuckpadNativeInstaller.xpc"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS"
cp "$BIN/DuckpadApp" "$APP/Contents/MacOS/Duckpad"
cp "$BIN/DuckpadNativeInstaller" "$HELPER/Contents/MacOS/DuckpadNativeInstaller"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/DuckpadApp/Resources/Duckpad.icns" "$APP/Contents/Resources/Duckpad.icns"
cp "$ROOT/Packaging/NativeInstaller-Info.plist" "$HELPER/Contents/Info.plist"
for NAME in DuckpadApp DuckpadInfrastructure DuckpadPresentation DuckpadEditorAdapter DuckpadLocalization; do
    ditto "$BIN/Duckpad_$NAME.bundle" "$APP/Contents/Resources/Duckpad_$NAME.bundle"
done
ditto "$PACKAGE" "$APP/Contents/Resources/Clipboard.duckpad-plugin"
codesign --force --sign - --options runtime "$HELPER"
codesign --force --sign - --options runtime --entitlements "$ROOT/Packaging/Duckpad.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
DUCKPAD_NATIVE_INSTALL_SMOKE=install "$APP/Contents/MacOS/Duckpad"
DUCKPAD_NATIVE_INSTALL_SMOKE=verify "$APP/Contents/MacOS/Duckpad"
