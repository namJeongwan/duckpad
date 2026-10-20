#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ "$1" != /* ]] || [[ "${1##*.}" != "app" ]]; then
    echo "Usage: $0 /absolute/path/Duckpad.app" >&2
    exit 64
fi
APP="$1"
XPC="$APP/Contents/XPCServices/DuckpadPluginRuntime.xpc"
INSTALLER="$APP/Contents/XPCServices/DuckpadNativeInstaller.xpc"
TERMINAL="$APP/Contents/XPCServices/DuckpadTerminalHost.xpc"
test -x "$TERMINAL/Contents/MacOS/DuckpadTerminalHost"
[[ "$(plutil -extract CFBundleIdentifier raw "$TERMINAL/Contents/Info.plist")" == "com.namjeongwan.duckpad.terminal-host" ]]
for KEY in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(plutil -extract "$KEY" raw "$APP/Contents/Info.plist")" == "$(plutil -extract "$KEY" raw "$TERMINAL/Contents/Info.plist")" ]]
done
test -x "$INSTALLER/Contents/MacOS/DuckpadNativeInstaller"
[[ "$(plutil -extract CFBundleIdentifier raw "$INSTALLER/Contents/Info.plist")" == "com.namjeongwan.duckpad.native-installer" ]]

test -x "$APP/Contents/MacOS/Duckpad"
test -x "$XPC/Contents/MacOS/DuckpadPluginRuntime"
test ! -e "$APP/Contents/MacOS/DuckpadPluginHost"
test -f "$APP/Contents/Resources/Duckpad.icns"
for ENGINE in Scintilla Lexilla WAMR Sparkle Ghostty; do
    test -s "$APP/Contents/Resources/ThirdPartyLicenses/$ENGINE.txt"
done
# The statically linked gettext libintl notice must accompany the engine.
LIBINTL_NOTICES=("$APP"/Contents/Resources/ThirdPartyLicenses/GhosttyDependencies/*/gettext-runtime/intl/COPYING.LIB)
test -s "${LIBINTL_NOTICES[0]}"
# SwiftPM may emit flat bundles or macOS bundles with Contents/Resources.
resource_root() {
    local BUNDLE="$APP/Contents/Resources/Duckpad_$1.bundle"
    if [[ -d "$BUNDLE/Contents/Resources" ]]; then
        printf '%s\n' "$BUNDLE/Contents/Resources"
    else
        printf '%s\n' "$BUNDLE"
    fi
}
INFRASTRUCTURE_RESOURCES="$(resource_root DuckpadInfrastructure)"
EDITOR_RESOURCES="$(resource_root DuckpadEditorAdapter)"
PRESENTATION_RESOURCES="$(resource_root DuckpadPresentation)"
LOCALIZATION_RESOURCES="$(resource_root DuckpadLocalization)"
test -f "$INFRASTRUCTURE_RESOURCES/Languages.json"
test -d "$EDITOR_RESOURCES/ScintillaCursors"
test -d "$INFRASTRUCTURE_RESOURCES/BundledExtensions"
test -f "$PRESENTATION_RESOURCES/MaterialIconTheme/LICENSE"
test -f "$PRESENTATION_RESOURCES/MaterialIconTheme/PROVENANCE.md"
test -f "$PRESENTATION_RESOURCES/MaterialIconTheme/dist/material-icons.json"
test -f "$PRESENTATION_RESOURCES/MaterialIconTheme/icons/file.svg"
for ASSET in preview.js highlight.css katex.css THIRD_PARTY_NOTICES.txt fonts/KaTeX_Main-Regular.woff2; do
    test -s "$PRESENTATION_RESOURCES/MarkdownPreview/$ASSET"
done
for ASSET in pin.svg unpin.svg eye.svg LICENSES; do
    test -s "$PRESENTATION_RESOURCES/ZedIcons/$ASSET"
done

for LOCALE in en ko ja zh-Hans pt-BR it fr de; do
    # SwiftPM normalizes resource directory names to lowercase.
    LOCALE_DIRECTORY="$(printf '%s' "$LOCALE" | tr '[:upper:]' '[:lower:]')"
    LOCALIZATION="$LOCALIZATION_RESOURCES/$LOCALE_DIRECTORY.lproj"
    test -s "$LOCALIZATION/Localizable.strings"
    test -s "$LOCALIZATION/Localizable.stringsdict"
    plutil -lint "$LOCALIZATION/Localizable.strings" "$LOCALIZATION/Localizable.stringsdict" >/dev/null
done

test -d "$APP/Contents/Resources/ghostty"
test -d "$APP/Contents/Resources/terminfo"
test -f "$(resource_root DuckpadTerminalAdapter)/terminal.conf"

APP_ARCHES="$(lipo -archs "$APP/Contents/MacOS/Duckpad")"
XPC_ARCHES="$(lipo -archs "$XPC/Contents/MacOS/DuckpadPluginRuntime")"
[[ "$APP_ARCHES" == "$XPC_ARCHES" ]]
[[ "$APP_ARCHES" == "$(lipo -archs "$TERMINAL/Contents/MacOS/DuckpadTerminalHost")" ]]
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

SEARCH_HELPER="$APP/Contents/Helpers/rg"
test -x "$SEARCH_HELPER"
[[ "$(lipo -archs "$SEARCH_HELPER")" == "$APP_ARCHES" ]]
codesign --verify --strict "$SEARCH_HELPER"
codesign -dv --verbose=4 "$SEARCH_HELPER" 2> "$TEMP_ROOT/search-signature.txt"
grep -Eq 'flags=.*runtime' "$TEMP_ROOT/search-signature.txt"
[[ "$APP_TEAM" == "$(sed -n 's/^TeamIdentifier=//p' "$TEMP_ROOT/search-signature.txt")" ]]
codesign -d --entitlements :- "$SEARCH_HELPER" > "$TEMP_ROOT/search-entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$TEMP_ROOT/search-entitlements.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.inherit' "$TEMP_ROOT/search-entitlements.plist")" == "true" ]]
python3 - "$APP" <<'PYRG'
import hashlib,json,sys
from pathlib import Path
app=Path(sys.argv[1])
manifest=json.loads((app/'Contents/Resources/ripgrep-version.json').read_text())
root=app/'Contents/Resources/ThirdPartyLicenses/Ripgrep'
index=json.loads((root/'index.json').read_text())
assert manifest['version']==index['ripgrep_version']=='15.1.0'
assert any(p['name']=='PCRE2' for p in index['packages'])
for package in index['packages']:
    assert package['notices']
    for notice in package['notices']:
        digest=notice['sha256']
        assert hashlib.sha256((root/'texts'/(digest+'.txt')).read_bytes()).hexdigest()==digest
PYRG

codesign -d --entitlements :- "$TERMINAL" > "$TEMP_ROOT/terminal-entitlements.txt" 2>/dev/null
if grep -q "com.apple.security.app-sandbox" "$TEMP_ROOT/terminal-entitlements.txt"; then
    echo "Terminal host must run outside App Sandbox" >&2; exit 1
fi
codesign -dv --verbose=4 "$TERMINAL" 2> "$TEMP_ROOT/terminal-signature.txt"
grep -Eq "flags=.*runtime" "$TEMP_ROOT/terminal-signature.txt"
[[ "$APP_TEAM" == "$(sed -n 's/^TeamIdentifier=//p' "$TEMP_ROOT/terminal-signature.txt")" ]]
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
