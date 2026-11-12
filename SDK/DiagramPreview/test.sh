#!/bin/bash
set -euo pipefail
HOST="$(cd "$(dirname "$0")/../.." && pwd)"
D2="$(cd "${1:-$HOST/../duckpad-plugin-d2}" && pwd)"
MERMAID="$(cd "${2:-$HOST/../duckpad-plugin-mermaid}" && pwd)"
cd "$HOST"
OUT="$HOST/.build/diagram-smoke"
mkdir -p "$OUT/resources/D2" "$OUT/resources/Mermaid"
bash "$D2/scripts/build.sh" native "$HOST"
bash "$MERMAID/scripts/build.sh" native "$HOST"
cp "$D2"/Resources/*.strings "$OUT/resources/D2/"
cp "$MERMAID"/Resources/*.strings "$OUT/resources/Mermaid/"
BASE=(-swift-version 6 -parse-as-library -I SDK/DuckpadNative/include SDK/DuckpadNative/Swift/DuckpadHost.swift)
SHARED=(SDK/DiagramPreview/Sources/*.swift)
swiftc "${BASE[@]}" SDK/DiagramPreview/Tests/HostSmoke.swift -o "$OUT/host"
"$OUT/host"
swiftc "${BASE[@]}" SDK/DiagramPreview/Tests/NativeModuleSmoke.swift -framework AppKit -o "$OUT/native"
"$OUT/native" "$D2/dist/com.duckpad.d2.duckpad-plugin" "$MERMAID/dist/com.duckpad.mermaid.duckpad-plugin"
swiftc "${BASE[@]}" "${SHARED[@]}" SDK/DiagramPreview/Tests/ControlledRenderer.swift SDK/DiagramPreview/Tests/ControllerSmoke.swift -framework AppKit -framework WebKit -o "$OUT/controller"
"$OUT/controller" "$OUT/resources"
swiftc "${BASE[@]}" "${SHARED[@]}" "$MERMAID/Sources/MermaidRenderer.swift" "$MERMAID/build/$(uname -m)/mermaid.o" SDK/DiagramPreview/Tests/RendererSmoke.swift -framework AppKit -framework WebKit -o "$OUT/renderer"
"$OUT/renderer"
