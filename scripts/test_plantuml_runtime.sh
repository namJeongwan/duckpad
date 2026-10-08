#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="${1:?Pass a test folder containing input.puml}"
JAVA="${2:?Pass Java home or bin/java}"
JAR="${3:?Pass official PlantUML 1.2026.8 LGPL/GPL JAR}"
mkdir -p "$ROOT/build/plantuml-runtime/module-cache"
swiftc -swift-version 6 -parse-as-library -module-cache-path "$ROOT/build/plantuml-runtime/module-cache" \
  "$ROOT/Sources/DuckpadPluginSupport/PlantUMLRequest.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLFailure.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLProcess.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLWorker.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLProcessGroup.swift" \
  "$ROOT/Sources/DuckpadInfrastructure/PlantUMLRuntime.swift" \
  "$ROOT/tests/PlantUMLRuntimeSmoke/WorkerChecks.swift" \
  "$ROOT/tests/PlantUMLRuntimeSmoke/WorkerGroupChecks.swift" \
  "$ROOT/tests/PlantUMLRuntimeSmoke/RuntimeSmoke.swift" -o "$ROOT/build/plantuml-runtime/runtime-smoke"
"$ROOT/build/plantuml-runtime/runtime-smoke" "$INPUT" "$JAVA" "$JAR" "${4:-}"
