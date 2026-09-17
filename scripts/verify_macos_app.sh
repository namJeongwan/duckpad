#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ "$1" != /* ]] || [[ "${1##*.}" != "app" ]]; then
    echo "Usage: $0 /absolute/path/Duckpad.app" >&2
    exit 64
fi
APP="$1"
XPC="$APP/Contents/XPCServices/DuckpadPluginRuntime.xpc"
INSTALLER="$APP/Contents/XPCServices/DuckpadNativeInstaller.xpc"
test -x "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller"
[[ "$(plutil -extract CFBundleIdentifier raw "$INSTALLER/Contents/Info.plist")" == "com.namjeongwan.duckpad.native-installer" ]]

test -x "$APP/Contents/MacOS/Duckpad"
test -x "$XPC/Contents/MacOS/DuckpadPluginRuntime"
test ! -e "$APP/Contents/MacOS/DuckpadPluginHost"
test -f "$APP/Contents/Resources/Duckpad.icns"
for ENGINE in Scintilla Lexilla WAMR Sparkle; do
    test -s "$APP/Contents/Resources/ThirdPartyLicenses/$ENGINE.txt"
done
test -f "$APP/Contents/Resources/Duckpad_DuckpadInfrastructure.bundle/Languages.json"
test -d "$APP/Contents/Resources/Duckpad_DuckpadEditorAdapter.bundle/ScintillaCursors"
test -d "$APP/Contents/Resources/Duckpad_DuckpadInfrastructure.bundle/BundledExtensions"
test -f "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/MaterialIconTheme/LICENSE"
test -f "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/MaterialIconTheme/PROVENANCE.md"
test -f "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/MaterialIconTheme/dist/material-icons.json"
test -f "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/MaterialIconTheme/icons/file.svg"
for ASSET in preview.js highlight.css katex.css THIRD_PARTY_NOTICES.txt fonts/KaTeX_Main-Regular.woff2; do
    test -s "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/MarkdownPreview/$ASSET"
done
for ASSET in pin.svg unpin.svg eye.svg LICENSES; do
    test -s "$APP/Contents/Resources/Duckpad_DuckpadPresentation.bundle/ZedIcons/$ASSET"
done

for LOCALE in en ko ja zh-Hans pt-BR it fr de; do
    # SwiftPM normalizes resource directory names to lowercase.
    LOCALE_DIRECTORY="$(printf '%s' "$LOCALE" | tr '[:upper:]' '[:lower:]')"
    LOCALIZATION="$APP/Contents/Resources/Duckpad_DuckpadLocalization.bundle/$LOCALE_DIRECTORY.lproj"
    test -s "$LOCALIZATION/Localizable.strings"
    test -s "$LOCALIZATION/Localizable.stringsdict"
    plutil -lint "$LOCALIZATION/Localizable.strings" "$LOCALIZATION/Localizable.stringsdict" >/dev/null
done

APP_ARCHES="$(lipo -archs "$APP/Contents/MacOS/Duckpad")"
XPC_ARCHES="$(lipo -archs "$XPC/Contents/MacOS/DuckpadPluginRuntime")"
[[ "$APP_ARCHES" == "$XPC_ARCHES" ]]
[[ "$APP_ARCHES" == "arm64" || "$APP_ARCHES" == "x86_64" || "$APP_ARCHES" == "x86_64 arm64" || "$APP_ARCHES" == "arm64 x86_64" ]]

[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "com.namjeongwan.duckpad" ]]
[[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" == "Duckpad" ]]
[[ "$(plutil -extract CFBundlePackageType raw "$XPC/Contents/Info.plist")" == "XPC!" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$XPC/Contents/Info.plist")" == "com.namjeongwan.duckpad.plugin-runtime" ]]

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/duckpad-entitlements.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
codesign -d --entitlements :- "$APP" > "$TEMP_ROOT/app.plist" 2>/dev/null
codesign -d --entitlements :- "$XPC" > "$TEMP_ROOT/xpc.plist" 2>/dev/null
plutil -lint "$TEMP_ROOT/app.plist" "$TEMP_ROOT/xpc.plist" >/dev/null

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$TEMP_ROOT/app.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$TEMP_ROOT/app.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$TEMP_ROOT/app.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$TEMP_ROOT/app.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$TEMP_ROOT/xpc.plist")" == "true" ]]
for KEY in com.apple.security.print com.apple.security.cs.disable-library-validation; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$TEMP_ROOT/app.plist")" == "true" ]]
done
[[ "$(plutil -p "$TEMP_ROOT/app.plist" | grep -c 'com.apple.security' | tr -d ' ')" == "7" ]]
[[ "$(plutil -p "$TEMP_ROOT/xpc.plist" | grep -c 'com.apple.security' | tr -d ' ')" == "1" ]]

codesign -dv --verbose=4 "$APP" 2> "$TEMP_ROOT/app-signature.txt"
codesign -dv --verbose=4 "$XPC" 2> "$TEMP_ROOT/xpc-signature.txt"
grep -Eq 'flags=.*runtime' "$TEMP_ROOT/app-signature.txt"
grep -Eq 'flags=.*runtime' "$TEMP_ROOT/xpc-signature.txt"
APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' "$TEMP_ROOT/app-signature.txt")"
XPC_TEAM="$(sed -n 's/^TeamIdentifier=//p' "$TEMP_ROOT/xpc-signature.txt")"
[[ "$APP_TEAM" == "$XPC_TEAM" ]]

codesign -d --entitlements :- "$INSTALLER" > "$TEMP_ROOT/installer-entitlements.txt" 2>/dev/null
if grep -q "com.apple.security.app-sandbox" "$TEMP_ROOT/installer-entitlements.txt"; then
    echo "Native installer must run outside App Sandbox" >&2; exit 1
fi
codesign -dv --verbose=4 "$INSTALLER" 2> "$TEMP_ROOT/installer-signature.txt"
grep -Eq "flags=.*runtime" "$TEMP_ROOT/installer-signature.txt"
INSTALLER_TEAM="$(sed -n 's/^TeamIdentifier=//p' "$TEMP_ROOT/installer-signature.txt")"
[[ "$APP_TEAM" == "$INSTALLER_TEAM" ]]
[[ "$(lipo -archs "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller")" == "$APP_ARCHES" ]]
python3 - "$APP" "$TEMP_ROOT/app.plist" <<'PY'
import base64, plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
entitlements = plistlib.loads(Path(sys.argv[2]).read_bytes())
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert info['SUFeedURL'] == 'https://namjeongwan.github.io/duckpad/appcast.xml'
assert info['SUEnableInstallerLauncherService'] and info['SUVerifyUpdateBeforeExtraction']
assert info['SUEnableAutomaticChecks'] and info['SUScheduledCheckInterval'] == 21600
assert not info['SUAllowsAutomaticUpdates'] and not info['SUAutomaticallyUpdate']
assert entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] == [
    info['CFBundleIdentifier'] + '-spks', info['CFBundleIdentifier'] + '-spki']
framework = app / 'Contents/Frameworks/Sparkle.framework'
assert (framework / 'Sparkle').is_file()
assert (framework / 'Versions/B/XPCServices/Installer.xpc').is_dir()
assert not (framework / 'Versions/B/XPCServices/Downloader.xpc').exists()
assert set(subprocess.check_output(['lipo', '-archs', str(framework / 'Sparkle')], text=True).split()) == {'arm64', 'x86_64'}
linked = subprocess.check_output(['otool', '-L', str(app / 'Contents/MacOS/Duckpad')], text=True)
assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in linked
PY
codesign --verify --deep --strict --verbose=2 "$APP"
echo "PASS: verified Duckpad app bundle, resources, XPC isolation, and signatures"
