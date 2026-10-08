#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d /tmp/duckpad-plantuml-process.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$ROOT/build/module-cache"
swiftc -swift-version 6 -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLFailure.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLProcess.swift" \
  "$ROOT/tests/PlantUMLRuntimeSmoke/ProcessSmoke.swift" -o "$STAGING/process-smoke"
"$STAGING/process-smoke"
