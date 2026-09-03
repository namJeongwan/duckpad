#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ "$1" != /* ]] || [[ "${1##*.}" != "app" ]]; then
    echo "Usage: $0 /absolute/path/Duckpad.app" >&2
    exit 64
fi
APP="$1"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/duckpad-app-smoke.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
DOCUMENT="$(mktemp "$TEMP_ROOT/Finder-Open-With.XXXXXX.txt")"
SCOPE_DOCUMENT="$(mktemp "$TEMP_ROOT/Security-Scope.XXXXXX.txt")"
SCOPE_NAMESPACE="smoke-$(uuidgen | tr '[:upper:]' '[:lower:]')"
FINDER_STDOUT="$TEMP_ROOT/finder-stdout.log"
FINDER_STDERR="$TEMP_ROOT/finder-stderr.log"

open -n -W -g -a "$APP" \
    --env "DUCKPAD_FINDER_SMOKE_EXPECT=$DOCUMENT" \
    --stdout "$FINDER_STDOUT" \
    --stderr "$FINDER_STDERR" \
    "$DOCUMENT"
grep -q 'Duckpad Finder smoke ready' "$FINDER_STDOUT"

open -n -W -g -a "$APP" \
    --env "DUCKPAD_SECURITY_SCOPE_SMOKE_NAMESPACE=$SCOPE_NAMESPACE" \
    --env "DUCKPAD_SECURITY_SCOPE_SMOKE_WRITE=$SCOPE_DOCUMENT" \
    --stdout "$TEMP_ROOT/scope-write-stdout.log" \
    --stderr "$TEMP_ROOT/scope-write-stderr.log" \
    "$SCOPE_DOCUMENT"
grep -q 'Duckpad security-scope smoke wrote bookmarked recovery' "$TEMP_ROOT/scope-write-stdout.log"

DUCKPAD_SECURITY_SCOPE_SMOKE_NAMESPACE="$SCOPE_NAMESPACE" \
DUCKPAD_SECURITY_SCOPE_SMOKE_VERIFY="$SCOPE_DOCUMENT" \
    "$APP/Contents/MacOS/Duckpad" \
    > "$TEMP_ROOT/scope-verify-stdout.log" 2> "$TEMP_ROOT/scope-verify-stderr.log"
grep -q 'Duckpad security-scope smoke restored bookmark and saved after relaunch' \
    "$TEMP_ROOT/scope-verify-stdout.log"
grep -qx 'bookmark-relaunch' "$SCOPE_DOCUMENT"

DUCKPAD_EXTENSION_SMOKE=1 "$APP/Contents/MacOS/Duckpad" \
    > "$TEMP_ROOT/xpc-stdout.log" 2> "$TEMP_ROOT/xpc-stderr.log"
grep -q 'Duckpad extension smoke ready' "$TEMP_ROOT/xpc-stdout.log"

DUCKPAD_EXTENSION_ISOLATION_SMOKE=1 "$APP/Contents/MacOS/Duckpad" \
    > "$TEMP_ROOT/xpc-isolation-stdout.log" 2> "$TEMP_ROOT/xpc-isolation-stderr.log"
grep -q 'Duckpad XPC isolation smoke ready' "$TEMP_ROOT/xpc-isolation-stdout.log"

echo "PASS: Finder/Open With and sandboxed XPC extension/isolation smokes"
