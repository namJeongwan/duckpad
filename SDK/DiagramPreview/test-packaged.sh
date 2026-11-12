#!/bin/bash
set -euo pipefail
if [[ $# != 4 || "$1" != /* || "$2" != /* ]]; then
 echo 'Usage: test-packaged.sh /absolute/candidate.app /absolute/d2 /path/to/d2-plugin /path/to/mermaid-plugin' >&2
 exit 64
fi
HOST="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$1"
D2_EXECUTABLE="$2"
D2="$(cd "$3" && pwd)"
MERMAID="$(cd "$4" && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/duckpad-diagram-xpc.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
# Clone a disposable test app. The candidate and its signature remain untouched.
cp -cR "$APP" "$OUT/Probe.app"
cd "$HOST"
swiftc -swift-version 6 -parse-as-library -I SDK/DuckpadNative/include \
 SDK/DuckpadNative/Swift/DuckpadHost.swift SDK/DiagramPreview/Sources/*.swift \
 Sources/DuckpadPluginSupport/NativeInstallerXPCProtocol.swift Sources/DuckpadPluginSupport/D2Request.swift \
 "$D2/Sources/D2Connection.swift" "$D2/Sources/D2Continuation.swift" \
 "$MERMAID/Sources/MermaidRenderer.swift" "$MERMAID/build/$(uname -m)/mermaid.o" \
 SDK/DiagramPreview/Tests/PackagedRendererSmoke.swift -framework AppKit -framework WebKit -framework Security \
 -o "$OUT/Probe.app/Contents/MacOS/Duckpad"
codesign --force --sign - --options runtime --entitlements Packaging/Duckpad.entitlements "$OUT/Probe.app"
# A watchdog bounds helper launch failures without touching any other app process.
python3 - "$OUT/Probe.app/Contents/MacOS/Duckpad" "$D2_EXECUTABLE" <<'PY'
import subprocess,sys
try:
 result=subprocess.run(sys.argv[1:],timeout=60)
except subprocess.TimeoutExpired:
 raise SystemExit('Packaged diagram renderer timed out')
raise SystemExit(result.returncode)
PY
